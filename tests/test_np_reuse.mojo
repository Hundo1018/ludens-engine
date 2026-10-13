# tier: integration
"""Narrowphase reuse for unmoved pairs (ROADMAP 17.85).

`SolverConfig.reuse_still_pairs` copies last collection's narrowphase
output for a candidate whose two bodies have the same pose and velocity
bit for bit (and the same `colliders.epoch`, `spec_dt`, margin). Every run
here compares it with the plain path bit for bit and reports how many
candidates were copied.

  1. Ordinary: two-box stacks under a DistanceTiers plan (most islands are
     not stepped on most steps), 120 steps.
  2. Integration: a stack that falls asleep; a filter change mid-run
     (`set_filter` bumps the epoch); a heightfield deformed mid-run through
     `colliders.deform_heightfield`; with `parallel_collision` on.
  3. Extreme: no bodies; every body moving (nothing to copy); a body
     removed mid-run.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.tiers import TierPolicy, DistanceTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _same(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    if len(a.bset.bodies) != len(b.bset.bodies) or len(a.cache) != len(b.cache):
        return False
    for i in range(len(a.bset.bodies)):
        if (
            a.bset.bodies[i].pos != b.bset.bodies[i].pos
            or a.bset.bodies[i].vel != b.bset.bodies[i].vel
            or a.bset.bodies[i].omega != b.bset.bodies[i].omega
            or a.bset.bodies[i].q.x != b.bset.bodies[i].q.x
            or a.bset.bodies[i].q.y != b.bset.bodies[i].q.y
            or a.bset.bodies[i].q.z != b.bset.bodies[i].q.z
            or a.bset.bodies[i].q.w != b.bset.bodies[i].q.w
            or a.bset.sleeping[i] != b.bset.sleeping[i]
        ):
            return False
    for c in range(len(a.cache)):
        if a.cache[c].a != b.cache[c].a or a.cache[c].b != b.cache[c].b or a.cache[c].m.count != b.cache[c].m.count:
            return False
        for k in range(a.cache[c].m.count):
            if a.cache[c].acc[k] != b.cache[c].acc[k] or a.cache[c].m.depths[k] != b.cache[c].m.depths[k]:
                return False
    return True


def _stacks(mut sc: ContactScene6[QuatBody6], side: Int, sleepy: Bool) raises:
    var L = Real(side) * 2
    _ = sc.add(QuatBody6.at_rest(Vec3(L / 2, -0.5, L / 2, 0), Inertia3.box(1, L, 0.5, L)), Vec3(L / 2 + 1, 0.5, L / 2 + 1, 0), True)
    for gx in range(side):
        for gz in range(side):
            for k in range(2):
                var id = sc.add(QuatBody6.at_rest(Vec3(Real(gx) * 2 + 1, 0.25 + Real(k) * 0.51, Real(gz) * 2 + 1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
                if not sleepy:
                    sc.set_can_sleep(id, False)


def _tier_table(mut sc: ContactScene6[QuatBody6]) raises:
    var it: List[Int] = [4, 4, 2]
    var su: List[Int] = [4, 4, 2]
    var pe: List[Int] = [1, 2, 4]
    sc.set_tier_table(it, su, pe)


def _cfg(reuse: Bool, par: Bool = False) -> SolverConfig:
    var c = SolverConfig()
    c.broadphase = True
    c.reuse_still_pairs = reuse
    c.parallel_collision = par
    return c


def main() raises:
    var s = Suite("np_reuse")

    # ---- tiered stacks ----------------------------------------------------------
    var a = ContactScene6[QuatBody6]()
    var b = ContactScene6[QuatBody6]()
    _stacks(a, 10, False)
    _stacks(b, 10, False)
    _tier_table(a)
    _tier_table(b)
    var r1: List[Real] = [4, 10]
    var r2: List[Real] = [4, 10]
    var pa = DistanceTiers(r1^, 1.5)
    var pb = DistanceTiers(r2^, 1.5)
    var obs: List[Vec3] = [Vec3(0, 1, 0, 0)]
    var same = True
    var reused = 0
    for _ in range(120):
        a.set_body_tiers(pa.assign(a, obs, a.step_index))
        b.set_body_tiers(pb.assign(b, obs, b.step_index))
        a.step(DT, G, _cfg(False))
        b.step(DT, G, _cfg(True))
        reused += b.np_reused
        if not _same(a, b):
            same = False
    print("  tiered stacks (200 boxes): candidates copied over 120 steps", reused)
    s.check(same, "tiered stacks: reuse == plain, bit for bit")
    s.check(reused > 0, "and the reuse path was taken")

    # ---- sleeping stack, filter change, parallel ---------------------------------
    var c = ContactScene6[QuatBody6]()
    var d = ContactScene6[QuatBody6]()
    _stacks(c, 4, True)
    _stacks(d, 4, True)
    var same2 = True
    var reused2 = 0
    for k in range(240):
        if k == 150:
            c.set_filter(3, 2, 0xFFFFFFFD)
            d.set_filter(3, 2, 0xFFFFFFFD)
        c.step(DT, G, _cfg(False))
        d.step(DT, G, _cfg(True, True))
        if k > 150:
            reused2 += d.np_reused
        if not _same(c, d):
            same2 = False
    print("  sleeping stacks + filter change at step 150: copied after the change", reused2)
    s.check(same2, "sleeping stacks with a mid-run filter change and parallel_collision: reuse == plain")
    s.check(reused2 > 0, "sleeping pairs are copied again after the change")

    # ---- heightfield deformed mid-run ---------------------------------------------
    var e = ContactScene6[QuatBody6]()
    var f = ContactScene6[QuatBody6]()
    var hs = List[Real](length=17 * 17, fill=0)
    _ = e.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs, 17, 17, 1.0, -8, -8)
    _ = f.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs, 17, 17, 1.0, -8, -8)
    for k in range(6):
        var ie = e.add(QuatBody6.at_rest(Vec3(Real(k) - 3, 0.3, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        var jf = f.add(QuatBody6.at_rest(Vec3(Real(k) - 3, 0.3, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        e.set_can_sleep(ie, False)  # awake, so the raised ground reaches them
        f.set_can_sleep(jf, False)
    var same3 = True
    for k in range(200):
        if k == 120:
            _ = e.colliders.deform_heightfield(0, 0, 0, 3, 0.1)
            _ = f.colliders.deform_heightfield(0, 0, 0, 3, 0.1)
        e.step(DT, G, _cfg(False))
        f.step(DT, G, _cfg(True))
        if not _same(e, f):
            same3 = False
    print("  heightfield raised under resting boxes at step 120: box at x 0, y", f.bset.bodies[4].pos[1])
    s.check(same3 and f.bset.bodies[4].pos[1] > 0.25, "heightfield raised 0.1 m mid-run (epoch bump) lifts the box; reuse == plain")

    # ---- extremes ---------------------------------------------------------------------
    var z1 = ContactScene6[QuatBody6]()
    var z2 = ContactScene6[QuatBody6]()
    for _ in range(3):
        z1.step(DT, G, _cfg(False))
        z2.step(DT, G, _cfg(True))
    s.check(_same(z1, z2) and z2.np_reused == 0, "no bodies")
    var m1 = ContactScene6[QuatBody6]()
    var m2 = ContactScene6[QuatBody6]()
    for k in range(20):
        var p = Vec3(Real(k) * 0.3, 2, 0, 0)
        _ = m1.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        _ = m2.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    var moving = 0
    var same4 = True
    for _ in range(20):
        m1.step(DT, G, _cfg(False))
        m2.step(DT, G, _cfg(True))
        moving += m2.np_reused
        if not _same(m1, m2):
            same4 = False
    s.check(same4 and moving == 0, "everything falling: nothing copied, same result")
    var g1 = ContactScene6[QuatBody6]()
    var g2 = ContactScene6[QuatBody6]()
    _stacks(g1, 3, True)
    _stacks(g2, 3, True)
    var same5 = True
    for k in range(200):
        if k == 100:
            g1.remove_body(g1.bset.id_of(5))
            g2.remove_body(g2.bset.id_of(5))
        g1.step(DT, G, _cfg(False))
        g2.step(DT, G, _cfg(True))
        if not _same(g1, g2):
            same5 = False
    s.check(same5, "a body removed mid-run: reuse == plain")
    s.finish()
