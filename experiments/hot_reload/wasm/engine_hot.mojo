"""engine_hot.c in Mojo, for the wasm hot reload matrix (W1), with H2 and H3
applied (W2).

Built for wasm32 through experiments/wasm_mojo (mojo --emit llvm ->
retarget_ir.py -> llc -> wasm-ld); run.py --core mojo builds each variant by
a text edit of this file (the `@@...@@` markers), as the native phase does.

Same exported ABI as engine_hot.c, so hot_reload.mjs, the matrix and the
bench run unchanged. Mojo has no global variables, so the state is a heap
`EngineState`; its address sits in the one 8-byte slot engine_hot_rt.c
provides (`ludens_state_slot`), with the snapshot buffer and the wrappers
for the `host.log` / `host.draw_rect` imports.

W2, following the native H2 / H3:
  * `EngineState { entities; core: Core }`: `Core` is plain data, and
    `assert_no_static_refs` (experiments/hot_reload/native/nostatic.mojo)
    rejects a pointer or string-view field in either struct at compile time;
  * snapshots are ecs/schema.mojo records written into the snapshot buffer
    as [u64 length][records], loaded by field name: an added field keeps its
    default, a deleted one is skipped, and a load that drops one field and
    defaults another is retried with `migrate()`'s aliases, then refused (0)
    if it still looks like a rename;
  * `engine_layout_id` hashes `schema_of[EngineState]`.
"""

from std.ffi import external_call
from std.memory import alloc, Layout
from ecs.sparse_set import SparseSet
from ecs.schema import TypeSchema, read_value, read_values, schema_of, write_value, write_values
from nostatic import assert_no_static_refs

comptime SPEED: Float32 = 60.0
comptime COLOR: UInt32 = 0xFF0000FF
comptime MSG: StaticString = "ludens: engine_init v1"
comptime SNAP_MAX_BYTES = 65536  # engine_hot_rt.c's buffer


struct Core(Copyable, Movable):
    # @@FIELDS_FRONT@@
    var capacity: Int
    var frame: Int
    var box_x: Float32
    # @@FIELDS_BACK@@

    def __init__(out self, capacity: Int):
        # @@INIT_FRONT@@
        self.capacity = capacity
        self.frame = 0
        self.box_x = 0.0
        # @@INIT_BACK@@

    def speed(self) -> Float32:
        # @@SPEED@@
        return SPEED


@fieldwise_init
struct Entity(Copyable, Movable):
    var key: Int


struct EngineState(Movable):
    var entities: SparseSet[Int32]
    var core: Core

    def __init__(out self, capacity: Int):
        self.entities = SparseSet[Int32]()
        self.core = Core(capacity)


def alias_field(mut sch: TypeSchema, current: String, stored: String):
    """Migration rule: read the stored field `stored` into `current`."""
    var j = sch.find(current)
    if j >= 0:
        sch.fields[j].name = stored


def migrate(mut sch: TypeSchema):
    """Aliases for renamed fields, applied only when a load looks like a rename."""
    # @@MIGRATE@@
    pass


comptime StatePtr = type_of(alloc[EngineState](Layout[EngineState](count=1)).unsafe_leak())
comptime WordPtr = type_of(alloc[Int](Layout[Int](count=1)).unsafe_leak())
comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


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
    """FNV-1a over the reflected schema of `EngineState` (names, types,
    offsets, sizes). The offsets are Mojo's compile-time (host) values; for
    these structs they equal the wasm32 layout (experiments/wasm_mojo/README.md)."""
    assert_no_static_refs[EngineState]()
    assert_no_static_refs[Core]()
    var sch = schema_of[EngineState]()
    var h: UInt32 = 2166136261
    for f in sch.fields:
        for b in (f.name + "|" + f.type_name).as_bytes():
            h = (h ^ UInt32(b)) * 16777619
        h = (h ^ UInt32(f.offset)) * 16777619
        h = (h ^ UInt32(f.size)) * 16777619
    return (h ^ UInt32(sch.size)) * 16777619


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
    ref g = _g()[].core
    g.box_x += g.speed() * dt
    g.frame += 1
    # @@UPDATE@@
    ref ents = _g()[].entities
    for i in range(len(ents)):
        var e = ents.key_at(i)
        external_call["ludens_host_draw_rect", NoneType](
            g.box_x + Float32(e) * 24.0, Float32(0), Float32(20), Float32(20), COLOR
        )


@export
def engine_entity_count() abi("C") -> UInt32:
    return UInt32(len(_g()[].entities))


@export
def engine_frame() abi("C") -> UInt32:
    return UInt32(_g()[].core.frame)


@export
def engine_log_msg() abi("C"):
    _log(MSG)


# ---- snapshot (W2): [u64 n][schema record: Core][schema batch: Entity], n bytes of records


def _snap() -> BytePtr:
    return BytePtr(unsafe_from_address=external_call["ludens_snap_ptr", Int]())


@export
def engine_save() abi("C") -> UInt32:
    """Bytes written to the snapshot buffer (header included); 0 if they do
    not fit."""
    ref s = _g()[]
    var out = List[UInt8]()
    write_value(s.core, schema_of[Core](), out)
    var ents = List[Entity](capacity=len(s.entities))
    for i in range(len(s.entities)):
        ents.append(Entity(s.entities.key_at(i)))
    write_values(ents, schema_of[Entity](), out)
    if 8 + len(out) > SNAP_MAX_BYTES:
        return 0
    var w = _snap()
    w.unsafe_bitcast[UInt64]()[] = UInt64(len(out))
    for i in range(len(out)):
        w[unsafe_offset=8 + i] = out[i]
    return UInt32(8 + len(out))


def _load() raises -> Int32:
    var p = _snap()
    var n = Int(p.unsafe_bitcast[UInt64]()[])
    if n < 0 or 8 + n > SNAP_MAX_BYTES:
        return 0
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(p[unsafe_offset=8 + i])
    var sch = schema_of[Core]()
    var core = Core(0)
    var pos = 0
    var rep = read_value(core, sch, data, pos)
    if rep.dropped > 0 and rep.defaulted > 0:
        migrate(sch)
        core = Core(0)
        pos = 0
        rep = read_value(core, sch, data, pos)
        if rep.dropped > 0 and rep.defaulted > 0:
            return 0
    if rep.mismatched > 0:
        return 0
    var ents = List[Entity]()
    _ = read_values(ents, Entity(0), schema_of[Entity](), data, pos)
    var s = EngineState(0)
    s.core = core^
    for e in ents:
        s.entities.add(e.key, Int32(e.key))
    _set_state(s^)
    return 1


@export
def engine_load() abi("C") -> Int32:
    """Rebuild the state from the snapshot buffer. 1 on success, 0 if refused."""
    try:
        return _load()
    except:
        return 0
