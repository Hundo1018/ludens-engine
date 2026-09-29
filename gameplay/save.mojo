"""Save games (ROADMAP 17.40), as opposed to deterministic snapshots.

`physics.serialize` writes the whole world, bit for bit, for replay and
rollback: any code change can invalidate it, and that is fine for what it
is for. A save game is the opposite trade: only what the game chooses to
keep (player progress, where things are, a few flags), readable by later
builds. It is built on the 17.11 reflection schemas:

  `SaveWriter.add[T](section, values, version)`  one named section per type,
                    its field descriptors written once (`ecs.schema
                    .write_values`)
  `SaveWriter.bytes()` / `SaveReader(bytes)`  a flat byte blob with a
                    header (magic, format version, section table)
  `SaveReader.read[T](section, template, out)`  records back into the
                    CURRENT type, matched by field name: fields a newer
                    build added keep the template's value, removed ones are
                    skipped, retyped ones are not reinterpreted
                    (`ReadReport` says which); a missing section reads as
                    empty rather than failing the whole load

`BodyRecord` + `save_bodies` / `load_bodies` are the physics part: pose and
velocity of each dynamic body, restored onto a scene the level script has
rebuilt -- nothing about contacts, caches or islands, which a later build is
free to change.
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Pose6
from physics.solver6 import ContactScene6
from physics.contact6 import ContactConstraint
from ecs.schema import schema_of, write_values, read_values, ReadReport, TypeSchema

comptime _SAVE_MAGIC = 0x4C534156  # "LSAV"
comptime SAVE_FORMAT = 1


def _put(mut out: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(data: List[UInt8], mut pos: Int) raises -> Int:
    if pos + 8 > len(data):
        raise Error("save: truncated")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return Int(u)


def _put_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _put(out, len(b))
    for k in range(len(b)):
        out.append(b[k])


def _get_str(data: List[UInt8], mut pos: Int) raises -> String:
    var n = _get(data, pos)
    if n < 0 or pos + n > len(data):
        raise Error("save: truncated string")
    var s = String(unsafe_from_utf8=Span(data)[pos : pos + n])
    pos += n
    return s^


struct SaveWriter(Movable):
    var names: List[String]
    var blobs: List[List[UInt8]]

    def __init__(out self):
        self.names = List[String]()
        self.blobs = List[List[UInt8]]()

    def add[T: Copyable](
        mut self, section: String, values: List[T], version: Int = 1, type_name: String = ""
    ):
        """`type_name` overrides the reflected struct name recorded in the
        section (a type renamed between builds keeps loading)."""
        var b = List[UInt8]()
        var sc = schema_of[T](version)
        if type_name != "":
            sc.name = type_name
        write_values(values, sc, b)
        self.names.append(section)
        self.blobs.append(b^)

    def bytes(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put(out, _SAVE_MAGIC)
        _put(out, SAVE_FORMAT)
        _put(out, len(self.names))
        for i in range(len(self.names)):
            _put_str(out, self.names[i])
            _put(out, len(self.blobs[i]))
            for k in range(len(self.blobs[i])):
                out.append(self.blobs[i][k])
        return out^


struct SaveReader(Movable):
    var data: List[UInt8]
    var names: List[String]
    var offsets: List[Int]
    var format: Int

    def __init__(out self, var data: List[UInt8]) raises:
        self.data = data^
        self.names = List[String]()
        self.offsets = List[Int]()
        var pos = 0
        if _get(self.data, pos) != _SAVE_MAGIC:
            raise Error("save: not a save file")
        self.format = _get(self.data, pos)
        if self.format > SAVE_FORMAT:
            raise Error("save: written by a newer save format")
        var n = _get(self.data, pos)
        if n < 0:
            raise Error("save: corrupt section count")
        for _ in range(n):
            self.names.append(_get_str(self.data, pos))
            var size = _get(self.data, pos)
            if size < 0 or pos + size > len(self.data):
                raise Error("save: truncated section")
            self.offsets.append(pos)
            pos += size

    def has(self, section: String) -> Bool:
        for i in range(len(self.names)):
            if self.names[i] == section:
                return True
        return False

    def read[T: Copyable](
        self, section: String, template: T, mut out: List[T], version: Int = 1,
        type_name: String = "",
    ) raises -> ReadReport:
        """Append the section's records to `out` as the current `T`. A
        missing section appends nothing and reports every field defaulted."""
        var sc = schema_of[T](version)
        if type_name != "":
            sc.name = type_name
        for i in range(len(self.names)):
            if self.names[i] == section:
                var pos = self.offsets[i]
                return read_values(out, template, sc, self.data, pos)
        return ReadReport(-1, 0, 0, 0, len(sc.fields))


@fieldwise_init
struct BodyRecord(Copyable, Movable):
    var slot: Int
    var pos: Vec3
    var rot: Quat
    var vel: Vec3
    var omega: Vec3


def save_bodies(sc: ContactScene6[QuatBody6]) -> List[BodyRecord]:
    var out = List[BodyRecord]()
    for i in range(len(sc.bset.bodies)):
        if not sc.bset.is_dynamic(i):
            continue
        ref b = sc.bset.bodies[i]
        out.append(BodyRecord(i, b.pos, b.q, b.vel, b.omega))
    return out^


def load_bodies(mut sc: ContactScene6[QuatBody6], recs: List[BodyRecord]) raises -> Int:
    """Put saved poses and velocities back onto a rebuilt scene; records for
    slots the scene no longer has are skipped. Returns how many applied.
    Same effect as `teleport` + `set_velocity` per body (pose, wake, drop
    the body's warm-start entries), but the cache is pruned once for all of
    them -- per-body `teleport` rescans it each time, O(bodies x cache)."""
    var applied = 0
    var touched = List[Bool](length=len(sc.bset.bodies), fill=False)
    for k in range(len(recs)):
        var i = recs[k].slot
        if i < 0 or i >= len(sc.bset.bodies) or not sc.bset.is_dynamic(i):
            continue
        var id = sc.bset.id_of(i)
        sc.bset.bodies[i].set_pose(Pose6(recs[k].pos, recs[k].rot))
        sc.set_velocity(id, recs[k].vel, recs[k].omega)
        sc.wake(id)
        touched[i] = True
        applied += 1
    if applied > 0:
        var kept = List[ContactConstraint]()
        for c in range(len(sc.cache)):
            if not touched[sc.cache[c].a] and not touched[sc.cache[c].b]:
                kept.append(sc.cache[c])
        sc.cache = kept^
    return applied
