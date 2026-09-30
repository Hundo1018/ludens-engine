"""Hot-reload experiment, native target: the engine as a reloadable Mojo .so.

Built with `mojo build --emit shared-lib`; the host (host.mojo) loads it with
`OwnedDLHandle` and swaps in a rebuilt copy while the simulation runs.

run_native.py produces each variant by applying a text edit to this file
(the `@@...@@` markers are where the layout edits go), so a variant is exactly
"the developer edited engine.mojo and rebuilt".

State is an `EngineState` in a block the HOST owns (`engine_state_size()`
bytes): the entities in dev's `ecs.SparseSet[Float32]` (entity -> x offset),
whose Lists are heap-allocated by whichever .so ran `engine_init`, then the
plain-data `Core`. Between them: a `List` appended to every frame, a
`List[Body]` stepped through a generic over trait `Mover`, and an `Array`
sized by a comptime value. `core` is the last field, so a field appended to
`Core` is appended to the whole state (variant v6).

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

# State whose layout or behaviour comes from comptime values, a trait and
# heap containers. The variants in run_native.py edit these.
comptime TRAIL_T = Int
comptime GRID_N = 4
comptime BODIES = 4


trait Mover(Copyable, Movable):
    def advance(self, x: Int, v: Int) -> Int:
        ...

    def extra(self) -> Int:
        # @@EXTRA@@
        return 0


struct Linear(Mover):
    var gain: Int
    var bias: Int

    def __init__(out self):
        self.gain = 1
        self.bias = 0

    def advance(self, x: Int, v: Int) -> Int:
        # @@ADVANCE@@
        return x + v * self.gain + self.bias + self.extra()


struct Damped(Mover):
    var gain: Int
    var bias: Int
    var damping: Int

    def __init__(out self):
        self.gain = 1
        self.bias = 0
        self.damping = 1

    def advance(self, x: Int, v: Int) -> Int:
        return x + v * self.gain + self.bias - self.damping + self.extra()


comptime ActiveMover = Linear


struct Body(Copyable, Movable):
    # @@BODY_FRONT@@
    var x: Int
    var v: Int

    def __init__(out self, x: Int, v: Int):
        # @@BODY_INIT@@
        self.x = x
        self.v = v


struct Aux(Copyable, Movable):
    var grid: Array[Int, GRID_N]
    var mover: ActiveMover

    def __init__(out self):
        self.grid = Array[Int, GRID_N](fill=0)
        self.mover = ActiveMover()


@fieldwise_init
struct TrailRec(Copyable, Movable):
    var t: TRAIL_T


def step_bodies[M: Mover](m: M, mut bodies: List[Body]):
    for i in range(len(bodies)):
        bodies[i].x = m.advance(bodies[i].x, bodies[i].v)


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
    var trail: List[TRAIL_T]
    var bodies: List[Body]
    var aux: Aux
    var core: Core  # last: a field appended to Core is appended to the state (v6)

    def __init__(out self, capacity: Int):
        self.entities = SparseSet[Float32]()
        self.trail = List[TRAIL_T]()
        self.bodies = List[Body](capacity=BODIES)
        for i in range(BODIES):
            self.bodies.append(Body(100 * i, i + 1))
        self.aux = Aux()
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
    assert_no_static_refs[Aux]()
    assert_no_static_refs[Body]()
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
    ref st = _state(addr)[]
    ref s = st.core
    s.box_x += s.speed() * dt
    s.frame += 1
    st.trail.append(TRAIL_T(s.frame))
    st.aux.grid[s.frame % GRID_N] += 1
    step_bodies(st.aux.mover, st.bodies)
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
def engine_trail_len(addr: Int) abi("C") -> Int:
    return len(_state(addr)[].trail)


@export
def engine_trail_sum(addr: Int) abi("C") -> Int:
    var t = 0
    for v in _state(addr)[].trail:
        t += Int(v)
    return t


@export
def engine_grid_sum(addr: Int) abi("C") -> Int:
    var t = 0
    for i in range(GRID_N):
        t += _state(addr)[].aux.grid[i]
    return t


@export
def engine_body_count(addr: Int) abi("C") -> Int:
    return len(_state(addr)[].bodies)


@export
def engine_body_x(addr: Int, i: Int) abi("C") -> Int:
    return _state(addr)[].bodies[i].x


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
    write_value(s.aux, schema_of[Aux](), out)
    write_values(s.bodies, schema_of[Body](), out)
    var recs = List[TrailRec](capacity=len(s.trail))
    for t in s.trail:
        recs.append(TrailRec(t))
    write_values(recs, schema_of[TrailRec](), out)
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
    # a field that changed type or size is refused, as for Core
    var aux = Aux()
    var rep_a = read_value(aux, schema_of[Aux](), data, pos)
    if rep_a.mismatched > 0:
        return LOAD_RETYPE
    if rep_a.dropped > 0 and rep_a.defaulted > 0:
        return LOAD_RENAME
    var bodies = List[Body]()
    var rep_b = read_values(bodies, Body(0, 0), schema_of[Body](), data, pos)
    if rep_b.mismatched > 0:
        return LOAD_RETYPE
    var recs = List[TrailRec]()
    var rep_t = read_values(recs, TrailRec(0), schema_of[TrailRec](), data, pos)
    if rep_t.mismatched > 0:
        return LOAD_RETYPE
    var s = EngineState(0)
    s.core = core^
    for e in ents:
        s.entities.add(e.key, e.x)
    s.aux = aux^
    s.bodies = bodies^
    for r in recs:
        s.trail.append(r.t)
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
