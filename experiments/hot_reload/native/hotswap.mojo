"""Shared by host.mojo (matrix cells) and live_host.mojo (hot compile loop):
the C-ABI wrapper around one loaded engine .so, raw state blocks, the
/proc/self/maps lookups, and the `auto` swap.
"""

from std.ffi import OwnedDLHandle, RTLD, external_call
from std.memory import alloc, Layout

comptime CAPACITY = 8
comptime DT: Float32 = 1.0 / 60.0
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


def free_block(addr: Int):
    BytePtr(unsafe_from_address=addr).unsafe_free()


struct Swapped(Movable):
    var engine: Engine
    var state: Int
    var used: String

    def __init__(out self, var engine: Engine, state: Int, used: String):
        self.engine = engine^
        self.state = state
        self.used = used

    def into_engine(deinit self) -> Engine:
        return self.engine^


def swap_auto(var old: Engine, var new: Engine, state: Int) raises -> Swapped:
    """Keep the state block in place (`inplace`) when state size and layout id
    match, else `snapshot` into a fresh block. Unloads `old` either way.
    `inplace` needs no rebind step: the state holds no pointer into a .so (H2)."""
    if old.size() == new.size() and old.layout_id() == new.layout_id():
        _ = old^
        return Swapped(new^, state, "inplace")
    var buf = block(8 * old.snapshot_words(state))
    old.save(state, buf)
    old.destroy(state)
    _ = old^
    free_block(state)
    var fresh = block(new.size())
    var ok = new.load(fresh, buf)
    free_block(buf)
    if ok != 1:
        raise Error("engine_load rejected the snapshot")
    return Swapped(new^, fresh, "snapshot")
