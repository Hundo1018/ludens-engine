"""Native hot-reload host: runs ONE (old .so -> new .so, strategy) cell.

    mojo build -I build experiments/hot_reload/native/host.mojo -o build/hot_native/host
    build/hot_native/host <old.so> <new.so> <strategy> [global]

Protocol (same as the wasm matrix): init(8), 30 frames, despawn 2 and 5,
10 frames, SWAP, 30 frames. Prints `key=value` lines; run_native.py compares
them with its float32 oracle. Label and teardown are printed last because
they are the steps expected to crash under some strategies: the lines already
printed survive a SIGSEGV, and the missing ones tell run_native.py where it died.

Strategies:
  restart   destroy old state, unload old, new state from engine_init
  keep      state block untouched, old .so stays loaded
  close     state block untouched, old .so unloaded
  rebind    `close` + new .so re-points fields that reference static data
  snapshot  old saves -> old destroys -> unload old -> new loads into a fresh block
  auto      rebind if (state size, layout id) match, else snapshot
  samepath  new .so moved onto the OLD path, then loaded by that path
"""

from std.ffi import OwnedDLHandle, RTLD, external_call
from std.memory import alloc, Layout
from std.sys import argv
from std.time import perf_counter_ns

comptime CAPACITY = 8
comptime DT: Float32 = 1.0 / 60.0
comptime PRE = 30
comptime MID = 10
comptime POST = 30
comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


struct Engine(Movable):
    var h: OwnedDLHandle

    def __init__(out self, path: String, flags: Int) raises:
        self.h = OwnedDLHandle(path, flags)

    def size(self) raises -> Int:
        return self.h.get_function[Int]("engine_state_size")()

    def layout_id(self) raises -> Int:
        return self.h.get_function[Int]("engine_layout_id")()

    def init(self, s: Int) raises:
        self.h.get_function[NoneType]("engine_init")(s, CAPACITY)

    def destroy(self, s: Int) raises:
        self.h.get_function[NoneType]("engine_destroy")(s)

    def rebind(self, s: Int) raises:
        self.h.get_function[NoneType]("engine_rebind")(s)

    def update(self, s: Int) raises:
        self.h.get_function[NoneType]("engine_update")(s, DT)

    def despawn(self, s: Int, e: Int) raises:
        self.h.get_function[NoneType]("engine_despawn")(s, e)

    def count(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_count")(s)

    def frame(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_frame")(s)

    def key_at(self, s: Int, i: Int) raises -> Int:
        return self.h.get_function[Int]("engine_key_at")(s, i)

    def draw_x(self, s: Int, i: Int) raises -> Float32:
        return self.h.get_function[Float32]("engine_draw_x")(s, i)

    def color(self) raises -> UInt32:
        return self.h.get_function[UInt32]("engine_color")()

    def module_addr(self) raises -> Int:
        return self.h.get_function[Int]("engine_module_addr")()

    def label_addr(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_label_addr")(s)

    def label_len(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_label_len")(s)

    def label_byte(self, s: Int, i: Int) raises -> Int:
        return self.h.get_function[Int]("engine_label_byte")(s, i)

    def snapshot_words(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_snapshot_words")(s)

    def save(self, s: Int, buf: Int) raises:
        self.h.get_function[NoneType]("engine_save")(s, buf)

    def load(self, s: Int, buf: Int) raises -> Int:
        return self.h.get_function[Int]("engine_load")(s, buf)


def block(nbytes: Int) -> Int:
    return Int(alloc[UInt8](Layout[UInt8](count=nbytes)).unsafe_leak())


def maps_count(needle: String) raises -> Int:
    return open("/proc/self/maps", "r").read().count(needle)


def owner(addr: Int, old_path: String, new_path: String, same_path: Bool) raises -> String:
    """Which loaded file holds `addr`: old | new | none (unmapped: dangling).
    A mapped file that was renamed over shows up as "<path> (deleted)": the
    old inode under `samepath`."""
    for line in open("/proc/self/maps", "r").read().split("\n"):
        var cols = line.split()
        if len(cols) < 6:
            continue
        var rng = cols[0].split("-")
        if rng[1].byte_length() > 15:  # [vsyscall] at 0xffffffffff600000 does not fit an Int
            continue
        var lo = atol(String(rng[0]), 16)
        var hi = atol(String(rng[1]), 16)
        if addr < lo or addr >= hi:
            continue
        var path = String(cols[5])
        var deleted = len(cols) > 6 and String(cols[6]) == "(deleted)"
        if path == new_path:
            return "new"
        if path == old_path:
            return "new" if same_path and not deleted else "old"
        return "other:" + path
    return "none"


def rename(src: String, dst: String) raises:
    var a = src.copy()
    var b = dst.copy()
    var rc = external_call["rename", Int32](a.as_c_string_span().ptr(), b.as_c_string_span().ptr())
    if rc != 0:
        raise Error("rename failed: " + src + " -> " + dst)


def main() raises:
    var args = argv()
    var old_path = String(args[1])
    var new_path = String(args[2])
    var strategy = String(args[3])
    var flags = RTLD.NOW | (RTLD.GLOBAL if len(args) > 4 and String(args[4]) == "global" else RTLD.LOCAL)

    var old = Engine(old_path, flags)
    var s = block(old.size())
    old.init(s)
    for _ in range(PRE):
        old.update(s)
    old.despawn(s, 2)
    old.despawn(s, 5)
    for _ in range(MID):
        old.update(s)
    print("frame_before=", old.frame(s), sep="")

    var used = strategy
    var retained = List[Engine]()  # old modules kept loaded until exit
    var t0 = perf_counter_ns()
    var cur: Engine
    if strategy == "restart":
        old.destroy(s)
        _ = old^
        cur = Engine(new_path, flags)
        s = block(cur.size())
        cur.init(s)
    elif strategy == "keep":
        cur = Engine(new_path, flags)
        retained.append(old^)
    elif strategy == "close":
        cur = Engine(new_path, flags)
        _ = old^
    elif strategy == "samepath":
        rename(new_path, old_path)
        cur = Engine(old_path, flags)
        retained.append(old^)
    else:
        cur = Engine(new_path, flags)
        if strategy == "auto":
            var same = old.size() == cur.size() and old.layout_id() == cur.layout_id()
            used = "rebind" if same else "snapshot"
        if used == "rebind":
            _ = old^
            cur.rebind(s)
        elif used == "snapshot":
            var buf = block(8 * old.snapshot_words(s))
            old.save(s, buf)
            old.destroy(s)
            _ = old^
            s = block(cur.size())
            if cur.load(s, buf) != 1:
                raise Error("engine_load rejected the snapshot")
        else:
            raise Error("unknown strategy " + strategy)
    var t1 = perf_counter_ns()
    print("used=", used, sep="")
    print("swap_us=", Float64(t1 - t0) / 1000.0, sep="")
    var parts = old_path.split("/")
    print("old_mapped=", maps_count(String(parts[len(parts) - 1])), sep="")

    for _ in range(POST):
        cur.update(s)
    var n = cur.count(s)
    print("count=", n, sep="")
    print("frame=", cur.frame(s), sep="")
    print("color=", cur.color(), sep="")
    var keys = String()
    var xs = String()
    for i in range(n):
        keys += String(cur.key_at(s, i)) + ","
        xs += String(cur.draw_x(s, i).to_bits()) + ","
    print("keys=", keys, sep="")
    print("xbits=", xs, sep="")

    var same = strategy == "samepath"
    print("code_owner=", owner(cur.module_addr(), old_path, new_path, same), sep="")
    print("label_owner=", owner(cur.label_addr(s), old_path, new_path, same), sep="")
    var label = String()
    for i in range(cur.label_len(s)):
        label += chr(cur.label_byte(s, i))
    print("label=", label, sep="")
    cur.destroy(s)
    print("teardown=ok")
    print("retained=", len(retained), sep="")
