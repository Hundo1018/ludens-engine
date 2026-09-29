# tier: integration
"""Reflection-generated schemas and schema-driven serialisation (ROADMAP 17.11).

  ordinary     `schema_of[Transform]` lists every leaf with the offsets the
               compiler uses (checked by writing through them), and a
               Transform round-trips bit for bit.
  seam parity  reflection-driven vs hand-written serialisation of the same
               values: both restore every field bit for bit.
  integration  an ECS world's Transforms snapshotted from a sparse-set world
               into an archetype world (backend swap) are identical; a
               `SolverConfig` round-trip steps a physics scene bit-identically
               to the original config.
  extreme      empty struct, nested struct, a V1 record read into a V2 type
               (added field defaulted, removed field dropped, retyped field
               skipped), truncated blob, wrong type name, unknown type/field
               and non-scalar access through the registry all behave.
"""

from std.sys import size_of
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from ecs.transform import Transform
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.schema import (
    schema_of, write_value, read_value, TypeRegistry, address_of, TypeSchema,
)
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig


@fieldwise_init
struct Empty(Copyable, Movable):
    pass


@fieldwise_init
struct Inner(Copyable, Movable):
    var a: Float32
    var b: Int


@fieldwise_init
struct Outer(Copyable, Movable):
    var tag: Int
    var inner: Inner
    var flag: Bool


# Two versions of one save type under the same name (base_name "Save").
@fieldwise_init
struct Save(Copyable, Movable):
    var hp: Float32
    var gold: Int
    var legacy: Int  # removed in V2
    var level: Float32  # retyped to Int in V2


def _v2_schema() -> TypeSchema:
    """What V2 of `Save` would reflect as: `legacy` removed, `level` now an
    Int, `mana` added. Built by hand from `SaveV2`'s real reflection so the
    name matches the V1 record."""
    var s = schema_of[SaveV2](2)
    s.name = "Save"
    return s^


@fieldwise_init
struct SaveV2(Copyable, Movable):
    var hp: Float32
    var mana: Float32  # new
    var gold: Int
    var level: Int  # retyped


def _same_bits[T: AnyType](a: T, b: T, s: TypeSchema) -> Bool:
    var pa = Pointer(to=a).unsafe_bitcast[UInt8]()
    var pb = Pointer(to=b).unsafe_bitcast[UInt8]()
    for i in range(len(s.fields)):
        for k in range(s.fields[i].size):
            if pa.unsafe_offset(s.fields[i].offset + k)[] != pb.unsafe_offset(s.fields[i].offset + k)[]:
                return False
    return True


def _hand_write(t: Transform, mut out: List[Float32]):
    """The hand-written partner of the seam: every field in a fixed order."""
    for k in range(3):
        out.append(t.translation[k])
    out.append(t.rotation.x)
    out.append(t.rotation.y)
    out.append(t.rotation.z)
    out.append(t.rotation.w)
    for k in range(3):
        out.append(t.scale[k])
    out.append(Float32(1) if t.local_dirty else Float32(0))
    out.append(Float32(1) if t.world_dirty else Float32(0))


def _hand_read(src: List[Float32], mut pos: Int) -> Transform:
    var t = Transform.at(Vec3(src[pos], src[pos + 1], src[pos + 2], 0))
    t.rotation = Quat(src[pos + 3], src[pos + 4], src[pos + 5], src[pos + 6])
    t.scale = Vec3(src[pos + 7], src[pos + 8], src[pos + 9], 0)
    t.local_dirty = src[pos + 10] != 0
    t.world_dirty = src[pos + 11] != 0
    pos += 12
    return t


def _scene(cfg: SolverConfig) -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)),
        Vec3(5, 0.5, 5, 0), True,
    )
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0.1, 1.2, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)),
        Vec3(0.3, 0.3, 0.3, 0), False,
    )
    for _ in range(60):
        sc.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), cfg)
    return sc.bset.bodies[1].position()[1]


def main() raises:
    var s = Suite("schema")

    # ---- ordinary ------------------------------------------------------
    var ts = schema_of[Transform](3)
    s.check(ts.name == "Transform" and ts.version == 3, "schema: name and version")
    s.eqi(len(ts.fields), 9, "Transform: 9 leaves (Quat walked into x/y/z/w)")
    s.check(ts.find("rotation.w") >= 0 and ts.find("world_dirty") >= 0, "dotted nested names")
    var t = Transform.at(Vec3(1, 2, 3, 0))
    t.rotation = Quat(0.1, 0.2, 0.3, 0.9)
    var reg = TypeRegistry()
    _ = reg.register[Transform]()
    reg.set_f64(address_of(t), "Transform", "rotation.y", -4.25)
    s.check(t.rotation.y == -4.25, "offset from reflection is the compiler's (write lands in the field)")
    var blob = List[UInt8]()
    write_value(t, ts, blob)
    var u = Transform.at(Vec3(0, 0, 0, 0))
    var pos = 0
    var rep = read_value(u, ts, blob, pos)
    s.check(_same_bits(t, u, ts), "Transform round-trips bit for bit")
    s.eqi(rep.restored, 9, "all 9 fields restored")
    s.eqi(pos, len(blob), "reader consumed the whole record")

    # ---- seam parity: reflection vs hand-written -----------------------
    var hand = List[Float32]()
    _hand_write(t, hand)
    var hp = 0
    var h = _hand_read(hand, hp)
    s.check(
        h.translation == u.translation and h.rotation.x == u.rotation.x
        and h.rotation.y == u.rotation.y and h.rotation.z == u.rotation.z
        and h.rotation.w == u.rotation.w and h.scale == u.scale
        and h.local_dirty == u.local_dirty and h.world_dirty == u.world_dirty,
        "reflection-driven == hand-written on every hand-written field",
    )

    # ---- integration: ECS backend swap ---------------------------------
    var wa = World[SparseSetBackend[Transform]]()
    for i in range(50):
        var tr = Transform.at(Vec3(Real(i), Real(i) * 0.5, -Real(i), 0))
        tr.rotation = Quat(0, Real(i) * 0.01, 0, 1)
        _ = wa.spawn1(tr)
    var snap = List[UInt8]()
    var ents = wa.query1[Transform]()
    for i in range(len(ents)):
        write_value(wa.get[Transform](ents[i]), ts, snap)
    var wb = World[ArchetypeBackend[Transform]]()
    var sp = 0
    for _ in range(len(ents)):
        var tr = Transform.at(Vec3(0, 0, 0, 0))
        _ = read_value(tr, ts, snap, sp)
        _ = wb.spawn1(tr)
    var eb = wb.query1[Transform]()
    var all_same = len(eb) == len(ents)
    for i in range(min(len(eb), len(ents))):
        if not _same_bits(wa.get[Transform](ents[i]), wb.get[Transform](eb[i]), ts):
            all_same = False
    s.check(all_same, "50 Transforms: sparse-set world -> blob -> archetype world, bit-identical")

    var cfg = SolverConfig()
    cfg.substeps = 6
    cfg.hertz = 45
    cfg.default_friction = 0.3
    var cs = schema_of[SolverConfig]()
    var cb = List[UInt8]()
    write_value(cfg, cs, cb)
    var cfg2 = SolverConfig()
    var cp = 0
    _ = read_value(cfg2, cs, cb, cp)
    s.check(_scene(cfg) == _scene(cfg2), "SolverConfig round-trip steps a scene bit-identically")

    # ---- extremes ------------------------------------------------------
    var es = schema_of[Empty]()
    s.eqi(len(es.fields), 0, "empty struct: no fields")
    var eblob = List[UInt8]()
    write_value(Empty(), es, eblob)
    var ev = Empty()
    var ep = 0
    var erep = read_value(ev, es, eblob, ep)
    s.check(erep.restored == 0 and ep == len(eblob), "empty struct round-trips")

    var os = schema_of[Outer]()
    s.eqi(len(os.fields), 4, "nested: Outer has 4 leaves (tag, inner.a, inner.b, flag)")
    var o = Outer(7, Inner(2.5, -9), True)
    var ob = List[UInt8]()
    write_value(o, os, ob)
    var o2 = Outer(0, Inner(0, 0), False)
    var op = 0
    _ = read_value(o2, os, ob, op)
    s.check(o2.tag == 7 and o2.inner.a == 2.5 and o2.inner.b == -9 and o2.flag, "nested round-trip")

    var v1 = Save(80, 120, 5, 3.5)
    var s1 = schema_of[Save](1)
    var vb = List[UInt8]()
    write_value(v1, s1, vb)
    var v2 = SaveV2(100, 50, 0, 1)
    var s2 = _v2_schema()
    var vp = 0
    var vr = read_value(v2, s2, vb, vp)
    s.eqi(vr.stored_version, 1, "version mismatch: stored version reported")
    s.check(v2.hp == 80 and v2.gold == 120, "V1 -> V2: surviving fields restored by name")
    s.check(v2.mana == 50, "V1 -> V2: new field keeps its default")
    s.check(v2.level == 1, "V1 -> V2: retyped field is not reinterpreted")
    s.check(vr.dropped == 1 and vr.mismatched == 1 and vr.defaulted == 1, "report: 1 dropped, 1 mismatched, 1 defaulted")

    var raised = False
    var cut = List[UInt8]()
    for i in range(len(blob) - 3):
        cut.append(blob[i])
    try:
        var z = Transform.at(Vec3(0, 0, 0, 0))
        var zp = 0
        _ = read_value(z, ts, cut, zp)
    except:
        raised = True
    s.check(raised, "truncated blob raises")

    raised = False
    try:
        var z = Outer(0, Inner(0, 0), False)
        var zp = 0
        _ = read_value(z, os, blob, zp)
    except:
        raised = True
    s.check(raised, "record of another type raises")

    var bad = 0
    try:
        _ = reg.get_f64(address_of(t), "Nope", "x")
    except:
        bad += 1
    try:
        _ = reg.get_f64(address_of(t), "Transform", "nope")
    except:
        bad += 1
    try:
        _ = reg.get_f64(address_of(t), "Transform", "translation")
    except:
        bad += 1
    s.eqi(bad, 3, "registry: unknown type, unknown field, non-scalar field all raise")

    s.finish()
