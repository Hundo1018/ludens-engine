"""Shared by host.mojo (matrix cells) and live_host.mojo (hot compile loop):
the C-ABI wrapper around one loaded engine .so, raw state blocks and the
/proc/self/maps lookups.
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

    def save(self, s: Int) raises -> Int:
        """Snapshot buffer: [u64 byte length][bytes], allocated by the engine
        with Mojo's allocator; free it with free_buffer."""
        return self.h.get_function[Int]("engine_save")(s)

    def load(self, s: Int, buf: Int) raises -> Int:
        """1 = ok; 0 corrupt, 2 unresolved rename, 3 changed type (engine.mojo)."""
        return self.h.get_function[Int]("engine_load")(s, buf)

    # R1 observations
    def trail_len(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_trail_len")(s)

    def trail_sum(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_trail_sum")(s)

    def grid_sum(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_grid_sum")(s)

    def body_count(self, s: Int) raises -> Int:
        return self.h.get_function[Int]("engine_body_count")(s)

    def body_x(self, s: Int, i: Int) raises -> Int:
        return self.h.get_function[Int]("engine_body_x")(s, i)


def block(nbytes: Int) -> Int:
    """A state block from libc `malloc`, freed with `free_state`. Not Mojo's
    `alloc`: that allocator carves blocks out of its own arena, so valgrind
    cannot see where a block ends (H4, probes/probe_alloc_bounds.mojo)."""
    return external_call["malloc", Int](nbytes)


def free_state(addr: Int):
    """Free a block from `block`."""
    external_call["free", NoneType](addr)


def maps_count(needle: String) raises -> Int:
    return open("/proc/self/maps", "r").read().count(needle)


def rss_kib() raises -> Int:
    """VmRSS of this process, KiB."""
    for line in open("/proc/self/status", "r").read().split("\n"):
        if line.startswith("VmRSS:"):
            return atol(String(line.split()[1]))
    return -1


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


def snapshot_bytes(buf: Int) -> Int:
    return Int(BytePtr(unsafe_from_address=buf).unsafe_bitcast[UInt64]()[]) + 8


def free_buffer(addr: Int):
    """Free a buffer the engine allocated (Mojo's allocator, shared by every
    module: README finding 3)."""
    BytePtr(unsafe_from_address=addr).unsafe_free()
