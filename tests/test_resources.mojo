# tier: integration
"""Resource accounting and limits (ROADMAP 17.79).

  1. Ordinary: `bytes_per_body` predicts exactly how many body-set and
     collider-header bytes 5000 more boxes add; a triangle mesh adds its
     vertex / index / normal / BVH bytes to `shapes`; contact bytes follow
     the cache.
  2. Integration: `check_room` passes below `max_bodies`, raises above it,
     and counts live bodies (removed slots do not count); a contact cap of
     3 keeps 3 manifolds, counts the dropped ones in `CONTACT_DROPPED`, and
     the scene keeps stepping with finite state.
  3. Extreme: an empty scene reports 0 and `bytes_per_body` 0; a negative
     count raises; no cap (0) drops nothing.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.resources import resource_report, bytes_per_body, check_room, Limits
from diag.counters import CONTACT_DROPPED

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _boxes(mut sc: ContactScene6[QuatBody6], n: Int, y: Real):
    for k in range(n):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k % 100) * 0.6, y, Real(k // 100) * 0.6, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)


def main() raises:
    var s = Suite("resources")
    var sc = ContactScene6[QuatBody6]()
    var r0 = resource_report(sc)
    s.check(r0.total() == 0 and bytes_per_body(sc) == 0, "empty scene: 0 bytes")
    _boxes(sc, 1000, 0.25)
    var bpb = bytes_per_body(sc)
    var r1 = resource_report(sc)
    _boxes(sc, 5000, 3.0)
    var r2 = resource_report(sc)
    var grew = (r2.bodies + r2.colliders) - (r1.bodies + r1.colliders)
    print("  bytes per body", bpb, " predicted for 5000 more", bpb * 5000, " measured", grew)
    print("  report:", r2)
    s.check(grew == bpb * 5000, "5000 more boxes add exactly bytes_per_body x 5000")

    var v: List[Real] = [-50, 0, -50, 50, 0, -50, -50, 0, 50, 50, 0, 50]
    var ix: List[Int] = [0, 2, 1, 1, 2, 3]
    var before = resource_report(sc).shapes
    _ = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), v, ix)
    var after = resource_report(sc).shapes
    print("  one 2-triangle mesh: shapes", before, "->", after, "bytes")
    s.check(after > before, "a triangle mesh adds to shapes")
    for _ in range(3):
        sc.step_soft(DT, G)
    var rc = resource_report(sc)
    s.check(rc.contacts > 0 and rc.contacts >= len(sc.cache) * 100, "contact bytes follow the cache (>= 100 B per manifold)")

    # ---- limits ---------------------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _boxes(sl, 10, 0.25)
    var lim = Limits(12, 0)
    var ok_room = True
    try:
        check_room(sl, lim, 2)
    except:
        ok_room = False
    var over = False
    try:
        check_room(sl, lim, 3)
    except e:
        over = True
        print("  over the cap:", String(e))
    sl.remove_body(sl.bset.id_of(3))
    var after_remove = True
    try:
        check_room(sl, lim, 3)
    except:
        after_remove = False
    s.check(ok_room and over and after_remove, "check_room: 10 + 2 fits 12, 10 + 3 raises, 9 live + 3 fits")
    var neg = False
    try:
        check_room(sl, lim, -1)
    except:
        neg = True
    s.check(neg, "negative count raises")

    # ---- contact cap -------------------------------------------------------------------
    var sp = ContactScene6[QuatBody6]()
    _ = sp.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    _boxes(sp, 10, 0.25)
    var cfg = SolverConfig()
    cfg.max_contacts = 3
    var finite = True
    for _ in range(60):
        sp.step(DT, G, cfg)
        for i in range(len(sp.bset.bodies)):
            if not isfinite(sp.bset.bodies[i].pos[1]):
                finite = False
    var dropped = sp.counters.get(CONTACT_DROPPED)
    print("  10 boxes on a floor, cap 3: cache", len(sp.cache), " dropped over 60 steps", dropped)
    s.check(len(sp.cache) == 3 and dropped > 0 and finite, "contact cap: 3 kept, the rest counted, state finite")
    var sn = ContactScene6[QuatBody6]()
    _ = sn.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    _boxes(sn, 10, 0.25)
    for _ in range(10):
        sn.step(DT, G, SolverConfig())
    s.check(sn.counters.get(CONTACT_DROPPED) == 0 and len(sn.cache) == 10, "no cap: nothing dropped")
    s.finish()
