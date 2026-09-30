"""W1: engine_hot.c in Mojo, for the wasm hot reload matrix.

Built for wasm32 through experiments/wasm_mojo (mojo --emit llvm ->
retarget_ir.py -> llc -> wasm-ld); run.py --core mojo builds each variant by
a text edit of this file (the `@@...@@` markers), as the native phase does.

Same exported ABI and snapshot format as engine_hot.c, so hot_reload.mjs,
the matrix and the bench run unchanged. One structural difference: Mojo has
no global variables, so the state cannot be a static `g`. It is a heap
`EngineState`; its address sits in the one 8-byte slot engine_hot_rt.c
provides (`ludens_state_slot`), together with the snapshot buffer and the
wrappers for the `host.log` / `host.draw_rect` imports.
"""

from std.ffi import external_call
from std.memory import alloc, bitcast, Layout
from std.sys import size_of
from ecs.sparse_set import SparseSet

comptime SPEED: Float32 = 60.0
comptime COLOR: UInt32 = 0xFF0000FF
comptime MSG: StaticString = "ludens: engine_init v1"
comptime SNAP_MAGIC: UInt32 = 0x4C444E53  # "SNDL"
comptime SNAP_MAX_WORDS = 4096


struct EngineState(Movable):
    # @@FIELDS_FRONT@@
    var capacity: Int
    var frame: Int
    var box_x: Float32
    var entities: SparseSet[Int32]
    # @@FIELDS_BACK@@

    def __init__(out self, capacity: Int):
        # @@INIT_FRONT@@
        self.capacity = capacity
        self.frame = 0
        self.box_x = 0.0
        self.entities = SparseSet[Int32]()
        # @@INIT_BACK@@

    def speed(self) -> Float32:
        # @@SPEED@@
        return SPEED


comptime StatePtr = type_of(alloc[EngineState](Layout[EngineState](count=1)).unsafe_leak())
comptime WordPtr = type_of(alloc[Int](Layout[Int](count=1)).unsafe_leak())
comptime U32Ptr = type_of(alloc[UInt32](Layout[UInt32](count=1)).unsafe_leak())


def _slot() -> WordPtr:
    return WordPtr(unsafe_from_address=external_call["ludens_state_slot", Int]())


def _g() -> StatePtr:
    return StatePtr(unsafe_from_address=_slot()[])


def _set_state(var s: EngineState):
    var p = alloc[EngineState](Layout[EngineState](count=1)).unsafe_leak()
    p.unsafe_write(s^)
    _slot()[] = Int(p)


def _log(msg: StaticString):
    external_call["ludens_host_log", NoneType](Int(msg.unsafe_ptr()), Int32(msg.byte_length()))


@export
def engine_layout_id() abi("C") -> UInt32:
    """FNV-1a over (size, byte offset of every named field) of a live instance."""
    var s = EngineState(0)
    var base = Int(Pointer(to=s))
    var h: UInt32 = 2166136261
    var vals: List[Int] = [
        size_of[EngineState](),
        Int(Pointer(to=s.capacity)) - base,
        Int(Pointer(to=s.frame)) - base,
        Int(Pointer(to=s.box_x)) - base,
        Int(Pointer(to=s.entities)) - base,
    ]
    for v in vals:
        h = (h ^ UInt32(v)) * 16777619
    return h


@export
def engine_init(capacity: UInt32) abi("C"):
    var s = EngineState(Int(capacity))
    for i in range(Int(capacity)):
        s.entities.add(i, Int32(i))
    _set_state(s^)
    _log(MSG)


@export
def engine_despawn(e: Int32) abi("C"):
    _g()[].entities.remove(Int(e))


@export
def engine_update(dt: Float32) abi("C"):
    ref g = _g()[]
    g.box_x += g.speed() * dt
    g.frame += 1
    # @@UPDATE@@
    for i in range(len(g.entities)):
        var e = g.entities.key_at(i)
        external_call["ludens_host_draw_rect", NoneType](
            g.box_x + Float32(e) * 24.0, Float32(0), Float32(20), Float32(20), COLOR
        )


@export
def engine_entity_count() abi("C") -> UInt32:
    return UInt32(len(_g()[].entities))


@export
def engine_frame() abi("C") -> UInt32:
    return UInt32(_g()[].frame)


@export
def engine_log_msg() abi("C"):
    _log(MSG)


# ---- snapshot: [magic, schema 1, capacity, frame, box_x bits, n, keys...] (as engine_hot.c)


def _snap() -> U32Ptr:
    return U32Ptr(unsafe_from_address=external_call["ludens_snap_ptr", Int]())


@export
def engine_save() abi("C") -> UInt32:
    ref g = _g()[]
    var n = len(g.entities)
    if 6 + n > SNAP_MAX_WORDS:
        return 0
    var w = _snap()
    w[unsafe_offset=0] = SNAP_MAGIC
    w[unsafe_offset=1] = 1
    w[unsafe_offset=2] = UInt32(g.capacity)
    w[unsafe_offset=3] = UInt32(g.frame)
    w[unsafe_offset=4] = bitcast[DType.uint32, 1](g.box_x)
    w[unsafe_offset=5] = UInt32(n)
    for i in range(n):
        w[unsafe_offset=6 + i] = UInt32(g.entities.key_at(i))
    return UInt32((6 + n) * 4)


@export
def engine_load() abi("C") -> Int32:
    var w = _snap()
    if w[unsafe_offset=0] != SNAP_MAGIC or w[unsafe_offset=1] != 1:
        return 0
    var s = EngineState(Int(w[unsafe_offset=2]))
    s.frame = Int(w[unsafe_offset=3])
    s.box_x = bitcast[DType.float32, 1](w[unsafe_offset=4])
    for i in range(Int(w[unsafe_offset=5])):
        var e = Int(w[unsafe_offset=6 + i])
        s.entities.add(e, Int32(e))
    _set_state(s^)
    return 1
