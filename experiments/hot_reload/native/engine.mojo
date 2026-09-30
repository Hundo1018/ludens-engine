"""Hot-reload experiment, native target: the engine as a reloadable Mojo .so.

Built with `mojo build --emit shared-lib`; the host (host.mojo) loads it with
`OwnedDLHandle` and swaps in a rebuilt copy while the simulation runs.

run_native.py produces each variant by applying a text edit to this file
(the `@@...@@` markers are where the layout edits go), so a variant is exactly
"the developer edited engine.mojo and rebuilt".

State is an `EngineState` in a block the HOST owns (`engine_state_size()`
bytes): the entities in dev's `ecs.SparseSet[Float32]` (entity -> x offset),
whose Lists are heap-allocated by whichever .so ran `engine_init`, then the
plain-data `Core`. `core` is the last field, so a field appended to `Core` is
appended to the whole state (variant v6).

The state holds no pointer into this .so's static data (H2): the label is an
index, and the text is looked up in the code (`label_text`), so it always
comes from the module that is running. `assert_no_static_refs` rejects at
compile time a field of `EngineState` or `Core` whose type is a pointer or
string view.

Snapshots (H3) use dev's reflection schemas (`ecs/schema.mojo`): `Core` as one
self-describing record, the entities as a batch of `Entity` records. Loading
matches fields by NAME, so an added field keeps its default and a deleted
one is skipped with no migration code. A load that both drops a stored field
and defaults a current one looks like a rename; it is retried with the
aliases from `migrate`, and refused if it still looks like one.

Every export is C ABI and takes the state block as an address (`Int`).
"""

from std.memory import alloc, Layout
from std.sys import size_of
from ecs.sparse_set import SparseSet
from ecs.schema import TypeSchema, read_value, read_values, schema_of, write_value, write_values
from nostatic import assert_no_static_refs

comptime SPEED: Float32 = 60.0
comptime COLOR: UInt32 = 0xFF0000FF
comptime LABEL: StaticString = "ludens: engine v1"
comptime LABEL_MAIN = 0

# engine_load results
comptime LOAD_OK = 1
comptime LOAD_CORRUPT = 0
comptime LOAD_RENAME = 2  # a field vanished and another appeared, no alias
comptime LOAD_RETYPE = 3  # a field kept its name and changed type


struct Core(Copyable, Movable):
    # @@FIELDS_FRONT@@
    var capacity: Int
    var frame: Int
    var box_x: Float32
    var label_id: Int
    # @@FIELDS_BACK@@

    def __init__(out self, capacity: Int):
        # @@INIT_FRONT@@
        self.capacity = capacity
        self.frame = 0
        self.box_x = 0.0
        self.label_id = LABEL_MAIN
        # @@INIT_BACK@@

    def speed(self) -> Float32:
        # @@SPEED@@
        return SPEED


@fieldwise_init
struct Entity(Copyable, Movable):
    var key: Int
    var x: Float32


struct EngineState(Movable):
    var entities: SparseSet[Float32]
    var core: Core

    def __init__(out self, capacity: Int):
        self.entities = SparseSet[Float32]()
        self.core = Core(capacity)
        for e in range(capacity):
            self.entities.add(e, Float32(e) * 24.0)


def alias_field(mut sch: TypeSchema, current: String, stored: String):
    """Migration rule: read the stored field `stored` into `current`."""
    var j = sch.find(current)
    if j >= 0:
        sch.fields[j].name = stored


def migrate(mut sch: TypeSchema):
    """Aliases for renamed fields, applied only when a load looks like a rename."""
    # @@MIGRATE@@
    pass


def label_text(id: Int) -> StaticString:
    """The label table lives in the code, not in the state."""
    if id == LABEL_MAIN:
        return LABEL
    return "?"


comptime StatePtr = type_of(alloc[EngineState](Layout[EngineState](count=1)).unsafe_leak())
comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


def _state(addr: Int) -> StatePtr:
    return StatePtr(unsafe_from_address=addr)


# ---- lifecycle ---------------------------------------------------------------


@export
def engine_state_size() abi("C") -> Int:
    assert_no_static_refs[EngineState]()
    assert_no_static_refs[Core]()
    return size_of[EngineState]()


@export
def engine_layout_id() abi("C") -> Int:
    """FNV-1a over the reflected schema of `EngineState`: every field's dotted
    name, type name, byte offset and size, plus the total size."""
    var sch = schema_of[EngineState]()
    var h = 2166136261
    for f in sch.fields:
        for b in (f.name + "|" + f.type_name).as_bytes():
            h = ((h ^ Int(b)) * 16777619) & 0xFFFFFFFF
        for v in [f.offset, f.size]:
            h = ((h ^ v) * 16777619) & 0xFFFFFFFF
    return ((h ^ sch.size) * 16777619) & 0xFFFFFFFF


@export
def engine_init(addr: Int, capacity: Int) abi("C"):
    _state(addr).unsafe_write(EngineState(capacity))


@export
def engine_destroy(addr: Int) abi("C"):
    _state(addr).unsafe_deinit_pointee()


# ---- simulation ---------------------------------------------------------------


@export
def engine_update(addr: Int, dt: Float32) abi("C"):
    ref s = _state(addr)[].core
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
    return _state(addr)[].core.frame


@export
def engine_key_at(addr: Int, i: Int) abi("C") -> Int:
    return _state(addr)[].entities.key_at(i)


@export
def engine_draw_x(addr: Int, i: Int) abi("C") -> Float32:
    ref s = _state(addr)[]
    return s.core.box_x + s.entities.value_at(i)


@export
def engine_color() abi("C") -> UInt32:
    return COLOR


@export
def engine_module_addr() abi("C") -> Int:
    """Address of this module's own label literal: identifies which .so's code runs."""
    return Int(LABEL.unsafe_ptr())


@export
def engine_label_addr(addr: Int) abi("C") -> Int:
    """Where the label text the state resolves to lives: always this .so."""
    return Int(label_text(_state(addr)[].core.label_id).unsafe_ptr())


@export
def engine_label_len(addr: Int) abi("C") -> Int:
    return label_text(_state(addr)[].core.label_id).byte_length()


@export
def engine_label_byte(addr: Int, i: Int) abi("C") -> Int:
    return Int(label_text(_state(addr)[].core.label_id).unsafe_ptr()[unsafe_offset=i])


# ---- snapshot (H3): [u64 byte length][schema record: Core][schema batch: Entity]
# The buffer is allocated here and freed by the host; every module shares
# one allocator (README finding 3).


@export
def engine_save(addr: Int) abi("C") -> Int:
    """Serialise the state; returns the address of the buffer."""
    ref s = _state(addr)[]
    var out = List[UInt8]()
    write_value(s.core, schema_of[Core](), out)
    var ents = List[Entity](capacity=len(s.entities))
    for i in range(len(s.entities)):
        ents.append(Entity(s.entities.key_at(i), s.entities.value_at(i)))
    write_values(ents, schema_of[Entity](), out)
    var n = len(out)
    var buf = alloc[UInt8](Layout[UInt8](count=8 + n)).unsafe_leak()
    buf.unsafe_bitcast[UInt64]()[] = UInt64(n)
    for i in range(n):
        buf[unsafe_offset=8 + i] = out[i]
    return Int(buf)


def _blob(buf: Int) -> List[UInt8]:
    var p = BytePtr(unsafe_from_address=buf)
    var n = Int(p.unsafe_bitcast[UInt64]()[])
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(p[unsafe_offset=8 + i])
    return data^


def _load(addr: Int, buf: Int) raises -> Int:
    var data = _blob(buf)
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
            return LOAD_RENAME
    if rep.mismatched > 0:
        return LOAD_RETYPE
    var ents = List[Entity]()
    _ = read_values(ents, Entity(0, 0.0), schema_of[Entity](), data, pos)
    var s = EngineState(0)
    s.core = core^
    for e in ents:
        s.entities.add(e.key, e.x)
    _state(addr).unsafe_write(s^)
    return LOAD_OK


@export
def engine_load(addr: Int, buf: Int) abi("C") -> Int:
    """Build a fresh state in `addr` from a snapshot. LOAD_OK (1) on success;
    otherwise nothing is written to `addr`."""
    try:
        return _load(addr, buf)
    except:
        return LOAD_CORRUPT
