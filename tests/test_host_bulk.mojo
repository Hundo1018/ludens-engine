# tier: integration
"""Host integration: batch pose writes and host-defined components
(ROADMAP 17.78).

  1. Ordinary: `teleport_many` over 20 bodies of a sleeping stack field
     leaves the same state as 20 `teleport` calls (poses, sleep flags, warm
     start cache), and the two scenes stay bit-identical for 60 more steps; a
     host component "Health" (8 bytes, f64) driven by the same script as a
     compile-time `Health` component on a `World` (spawn, set, remove,
     despawn, id reuse, update) ends with the same entity set and values.
  2. Integration: `matching_all` over two host components equals the
     intersection; `to_bytes` / `from_bytes` round-trip the store.
  3. Extreme: a stale handle to a recycled id reads as absent; a bad id in
     `teleport_many` raises and moves nothing; a wrong byte count, a
     duplicate name and an offset past the component raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.host_components import HostComponents

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


@fieldwise_init
struct Health(ComponentType):
    comptime ID: Int = 0
    var hp: Float64


@fieldwise_init
struct Tag(ComponentType):
    comptime ID: Int = 1
    var v: Int


def _field(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k % 8) - 4, 0.25 + Real(k // 8 % 2) * 0.51, Real(k // 16) * 1.5, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)


def _same(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    if len(a.cache) != len(b.cache):
        return False
    for i in range(len(a.bset.bodies)):
        if a.bset.bodies[i].pos != b.bset.bodies[i].pos or a.bset.bodies[i].vel != b.bset.bodies[i].vel or a.bset.sleeping[i] != b.bset.sleeping[i]:
            return False
        if a.bset.bodies[i].q.x != b.bset.bodies[i].q.x or a.bset.bodies[i].q.w != b.bset.bodies[i].q.w:
            return False
    for c in range(len(a.cache)):
        if a.cache[c].a != b.cache[c].a or a.cache[c].b != b.cache[c].b:
            return False
    return True


def main() raises:
    var s = Suite("host_bulk")

    # ---- teleport_many == sequential teleport --------------------------------
    var sa = ContactScene6[QuatBody6]()
    var sb = ContactScene6[QuatBody6]()
    _field(sa)
    _field(sb)
    for _ in range(150):
        sa.step_soft(DT, G)
        sb.step_soft(DT, G)
    var slept = 0
    for i in range(len(sa.bset.bodies)):
        if sa.bset.sleeping[i]:
            slept += 1
    var ids = List[BodyId]()
    var poses = List[Pose6]()
    for k in range(20):
        var i = 1 + k * 2
        ids.append(sa.bset.id_of(i))
        poses.append(Pose6(Vec3(Real(k) - 10, 3 + Real(k % 3), 5, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), Real(k) * 0.1)))
    for k in range(20):
        sb.teleport(ids[k], poses[k].copy())
    sa.teleport_many(ids, poses)
    var same0 = _same(sa, sb)
    var same = same0
    for _ in range(60):
        sa.step_soft(DT, G)
        sb.step_soft(DT, G)
        if not _same(sa, sb):
            same = False
    print("  20 bodies teleported (", slept, "were asleep): batch == sequential right after", same0, " and for 60 steps", same)
    s.check(slept > 0 and same0 and same, "teleport_many == 20 teleport calls, and stays bit-identical")
    var bad = ids.copy()
    bad.append(BodyId(999, 0))
    var before = sa.bset.bodies[1].pos
    var raised = False
    try:
        sa.teleport_many(bad, poses)
    except:
        raised = True
    s.check(raised and sa.bset.bodies[1].pos == before, "a bad id (or count mismatch) raises and moves nothing")

    # ---- host component == compile-time component ---------------------------------
    var w = World[SparseSetBackend[Health, Tag]]()
    var hc = HostComponents()
    var hid = hc.register("Health", 8)
    var ents = List[Entity]()
    for _ in range(200):
        ents.append(w.spawn())
    for i in range(200):
        if i % 2 == 1:
            w.set(ents[i], Health(Float64(i)))
            hc.set_f64(ents[i], hid, 0, Float64(i))
    for i in range(0, 200, 7):
        if w.has[Health](ents[i]):
            w.remove[Health](ents[i])
        hc.remove(ents[i], hid)
    for i in range(0, 200, 11):
        w.despawn(ents[i])
        hc.despawn(ents[i])
    var fresh = List[Entity]()
    for i in range(10):  # recycles despawned ids
        var e = w.spawn()
        fresh.append(e)
        w.set(e, Health(-Float64(i)))
        hc.set_f64(e, hid, 0, -Float64(i))
    for e in w.query1[Health]():
        var v = w.get[Health](e).hp * 2
        w.set(e, Health(v))
        hc.set_f64(e, hid, 0, hc.get_f64(e, hid, 0) * 2)
    var a = w.query1[Health]()
    var b = hc.matching(hid)
    var ok = len(a) == len(b)
    for e in a:
        if not hc.has(e, hid) or hc.get_f64(e, hid, 0) != w.get[Health](e).hp:
            ok = False
    print("  Health on", len(a), "entities: compile-time vs host component agree", ok)
    s.check(ok and len(a) > 50, "host component == compile-time component under the same script")
    var stale = Entity(ents[11].id, ents[11].gen)  # despawned, id recycled
    s.check(not hc.has(stale, hid), "a stale handle to a recycled id reads as absent")

    # ---- multi-component query and round trip ----------------------------------------
    var mid = hc.register("Mana", 16)
    for i in range(0, 200, 3):
        if w.is_alive(ents[i]):
            hc.set_f64(ents[i], mid, 8, Float64(i))
    var both = hc.matching_all([hid, mid])
    var want = 0
    for e in hc.matching(hid):
        if hc.has(e, mid):
            want += 1
    s.check(len(both) == want and want > 0, "matching_all is the intersection")
    var hc2 = HostComponents.from_bytes(hc.to_bytes())
    var rt = hc2.to_bytes() == hc.to_bytes() and hc2.id_of("Mana") == mid
    for e in both:
        if hc2.get_f64(e, mid, 8) != hc.get_f64(e, mid, 8):
            rt = False
    s.check(rt, "to_bytes / from_bytes round-trips the store")

    # ---- extremes -----------------------------------------------------------------------
    var errs = 0
    try:
        hc.set(ents[1], hid, List[UInt8](length=4, fill=0))
    except:
        errs += 1
    try:
        _ = hc.register("Health", 8)
    except:
        errs += 1
    try:
        hc.set_f64(ents[1], hid, 4, 1.0)
    except:
        errs += 1
    s.check(errs == 3, "wrong size, duplicate name, offset past the end raise")
    s.finish()
