"""Hot-reload experiment, native target: the engine as a reloadable Mojo .so.

Built with `mojo build --emit shared-lib`; the host (host.mojo) loads it with
`OwnedDLHandle` and swaps in a rebuilt copy while the simulation runs.

run_native.py produces each variant by applying a text edit to this file
(the `@@...@@` markers are where the layout edits go), so a variant is exactly
"the developer edited engine.mojo and rebuilt".

State is an `EngineState` in a block the HOST owns (`engine_state_size()`
bytes). Entities live in dev's `ecs.SparseSet[Float32]` (entity -> x offset),
whose Lists are heap-allocated by whichever .so ran `engine_init`. `label`
points at a string literal inside the .so that created it.

Every export is C ABI and takes the state block as an address (`Int`).
"""

from std.memory import alloc, bitcast, Layout
from std.sys import size_of
from ecs.sparse_set import SparseSet

comptime SPEED: Float32 = 60.0
comptime COLOR: UInt32 = 0xFF0000FF
comptime LABEL: StaticString = "ludens: engine v1"
comptime SNAP_MAGIC = 0x4C444E53  # "SNDL"
comptime SNAP_SCHEMA = 1


struct EngineState(Movable):
    # @@FIELDS_FRONT@@
    var capacity: Int
    var frame: Int
    var box_x: Float32
    var label: StaticString
    var entities: SparseSet[Float32]
    # @@FIELDS_BACK@@

    def __init__(out self, capacity: Int):
        # @@INIT_FRONT@@
        self.capacity = capacity
        self.frame = 0
        self.box_x = 0.0
        self.label = LABEL
        self.entities = SparseSet[Float32]()
        # @@INIT_BACK@@
        for e in range(capacity):
            self.entities.add(e, Float32(e) * 24.0)

    def speed(self) -> Float32:
        # @@SPEED@@
        return SPEED


comptime StatePtr = type_of(alloc[EngineState](Layout[EngineState](count=1)).unsafe_leak())
comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


def _f32(bits: Int64) -> Float32:
    return bitcast[DType.float32, 1](UInt32(bits))


def _state(addr: Int) -> StatePtr:
    return StatePtr(unsafe_from_address=addr)


# ---- lifecycle ---------------------------------------------------------------


@export
def engine_state_size() abi("C") -> Int:
    return size_of[EngineState]()


@export
def engine_layout_id() abi("C") -> Int:
    """FNV-1a over (size, byte offset of every named field), measured on a
    live instance so it reflects the compiled layout."""
    var s = EngineState(0)
    var base = Int(Pointer(to=s))
    var h = 2166136261
    var vals: List[Int] = [
        size_of[EngineState](),
        Int(Pointer(to=s.capacity)) - base,
        Int(Pointer(to=s.frame)) - base,
        Int(Pointer(to=s.box_x)) - base,
        Int(Pointer(to=s.label)) - base,
        Int(Pointer(to=s.entities)) - base,
    ]
    for v in vals:
        h = ((h ^ v) * 16777619) & 0xFFFFFFFF
    return h


@export
def engine_init(addr: Int, capacity: Int) abi("C"):
    _state(addr).unsafe_write(EngineState(capacity))


@export
def engine_destroy(addr: Int) abi("C"):
    _state(addr).unsafe_deinit_pointee()


@export
def engine_rebind(addr: Int) abi("C"):
    """Re-point fields that reference this .so's static data (the label)."""
    _state(addr)[].label = LABEL


# ---- simulation ---------------------------------------------------------------


@export
def engine_update(addr: Int, dt: Float32) abi("C"):
    ref s = _state(addr)[]
    s.box_x += s.speed() * dt
    s.frame += 1
    # @@UPDATE@@


@export
def engine_despawn(addr: Int, e: Int) abi("C"):
    _state(addr)[].entities.remove(e)


# ---- observation (what a renderer would read) --------------------------------


@export
def engine_count(addr: Int) abi("C") -> Int:
    return len(_state(addr)[].entities)


@export
def engine_frame(addr: Int) abi("C") -> Int:
    return _state(addr)[].frame


@export
def engine_key_at(addr: Int, i: Int) abi("C") -> Int:
    return _state(addr)[].entities.key_at(i)


@export
def engine_draw_x(addr: Int, i: Int) abi("C") -> Float32:
    ref s = _state(addr)[]
    return s.box_x + s.entities.value_at(i)


@export
def engine_color() abi("C") -> UInt32:
    return COLOR


@export
def engine_module_addr() abi("C") -> Int:
    """Address of this module's own label literal: identifies which .so's code runs."""
    return Int(LABEL.unsafe_ptr())


@export
def engine_label_addr(addr: Int) abi("C") -> Int:
    """Where the state's label points (it may be another, even unloaded, .so)."""
    return Int(_state(addr)[].label.unsafe_ptr())


@export
def engine_label_len(addr: Int) abi("C") -> Int:
    return _state(addr)[].label.byte_length()


@export
def engine_label_byte(addr: Int, i: Int) abi("C") -> Int:
    return Int(_state(addr)[].label.unsafe_ptr()[unsafe_offset=i])


# ---- snapshot: [magic, schema, capacity, frame, box_x bits, n, (key, value bits)*n]


@export
def engine_snapshot_words(addr: Int) abi("C") -> Int:
    return 6 + 2 * len(_state(addr)[].entities)


@export
def engine_save(addr: Int, buf: Int) abi("C"):
    ref s = _state(addr)[]
    var w = BytePtr(unsafe_from_address=buf).unsafe_bitcast[Int64]()
    var n = len(s.entities)
    w[unsafe_offset=0] = SNAP_MAGIC
    w[unsafe_offset=1] = SNAP_SCHEMA
    w[unsafe_offset=2] = Int64(s.capacity)
    w[unsafe_offset=3] = Int64(s.frame)
    w[unsafe_offset=4] = Int64(s.box_x.to_bits())
    w[unsafe_offset=5] = Int64(n)
    for i in range(n):
        w[unsafe_offset=6 + 2 * i] = Int64(s.entities.key_at(i))
        w[unsafe_offset=7 + 2 * i] = Int64(s.entities.value_at(i).to_bits())


@export
def engine_load(addr: Int, buf: Int) abi("C") -> Int:
    """Build a fresh state in `addr` from a snapshot. Returns 1 on success."""
    var w = BytePtr(unsafe_from_address=buf).unsafe_bitcast[Int64]()
    if w[unsafe_offset=0] != SNAP_MAGIC or w[unsafe_offset=1] != SNAP_SCHEMA:
        return 0
    var s = EngineState(0)
    s.capacity = Int(w[unsafe_offset=2])
    s.frame = Int(w[unsafe_offset=3])
    s.box_x = _f32(w[unsafe_offset=4])
    for i in range(Int(w[unsafe_offset=5])):
        s.entities.add(Int(w[unsafe_offset=6 + 2 * i]), _f32(w[unsafe_offset=7 + 2 * i]))
    _state(addr).unsafe_write(s^)
    return 1
