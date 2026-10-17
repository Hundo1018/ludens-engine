# tier: integration
"""Aggregate tiers (ROADMAP 17.85, `gameplay.tiers.AggregateTiers`).

20 two-box stacks every 10 m along x (sleeping off), an observer at the
origin; tier 0 = the step's config, tier 1 = period 0 (frozen). Islands
farther than 35 m whose members move slower than 5 cm/s are frozen and
summarised as `ClusterProxy`s.

  1. After settling: the 16 stacks beyond 35 m are proxies of 2 members,
     mass 2, centroid at the stack (x within 1 mm); the near 4 are solved.
  2. Frozen stacks do not move: their bodies are bit-identical across 60
     further steps.
  3. Waking by contact: a 1 kg box sliding at 6 m/s into the frozen stack
     at x = 100 joins its island and is solved with it -- the stack's lower
     box moves, and ends within 2 cm of the same collision in an untiered
     run.
  4. An observer walking to x = 100 unfreezes the stacks within 35 m of
     it.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.body_set import BodyId
from gameplay.tiers import AggregateTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def scene(tiered: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(100, -0.5, 0, 0), Inertia3.box(1, 120, 0.5, 10)), Vec3(120, 0.5, 10, 0), True)
    for k in range(20):
        for j in range(2):
            var id = sc.add(QuatBody6.at_rest(Vec3(Real(k) * 10, 0.25 + 0.5 * Real(j), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
            sc.set_can_sleep(id, False)
    if tiered:
        var it: List[Int] = [4, 2]
        var su: List[Int] = [4, 2]
        var pe: List[Int] = [1, 0]
        sc.set_tier_table(it, su, pe)
    return sc^


def main() raises:
    var s = Suite("tiers_aggregate")
    var cfg = SolverConfig()
    cfg.broadphase = True
    var sc = scene(True)
    var pol = AggregateTiers(35, 0.05, 1)
    var obs: List[Vec3] = [Vec3(0, 1, 0, 0)]
    for _ in range(60):
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        sc.step(DT, G, cfg)
    var np = len(pol.proxies)
    var ok = np == 16
    for ref c in pol.proxies:
        var sx = Real(Int(c.centroid[0] / 10 + 0.5)) * 10
        ok = ok and c.members == 2 and c.mass == 2 and abs(c.centroid[0] - sx) < 0.001 and sx >= 40
    print("proxies", np, " first: members", pol.proxies[0].members, " mass", pol.proxies[0].mass, " centroid", pol.proxies[0].centroid[0], pol.proxies[0].centroid[1])
    s.check(ok, "16 far stacks become 2-member, 2 kg proxies at their stacks")

    var before = List[Vec3]()
    for i in range(len(sc.bset.bodies)):
        before.append(sc.bset.bodies[i].position())
    for _ in range(60):
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        sc.step(DT, G, cfg)
    var still = True
    for i in range(9, len(sc.bset.bodies)):  # bodies of the stacks at x >= 40
        for a in range(3):
            still = still and sc.bset.bodies[i].position()[a] == before[i][a]
    s.check(still, "frozen stacks are bit-identical over 60 steps")

    # waking by contact: the same shot in the tiered and an untiered scene
    var ref_sc = scene(False)
    for _ in range(120):
        ref_sc.step(DT, G, cfg)
    var lower = 1 + 2 * 10  # the lower box of the stack at x = 100
    var x0 = sc.bset.bodies[lower].position()[0]
    var b1 = QuatBody6.at_rest(Vec3(97, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    b1.set_velocity(Vec3(6, 0, 0, 0), Vec3(0, 0, 0, 0))
    _ = sc.add(b1^, Vec3(0.25, 0.25, 0.25, 0), False)
    var b2 = QuatBody6.at_rest(Vec3(97, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    b2.set_velocity(Vec3(6, 0, 0, 0), Vec3(0, 0, 0, 0))
    _ = ref_sc.add(b2^, Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(90):
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        sc.step(DT, G, cfg)
        ref_sc.step(DT, G, cfg)
    var moved = sc.bset.bodies[lower].position()[0] - x0
    var diff = abs(sc.bset.bodies[lower].position()[0] - ref_sc.bset.bodies[lower].position()[0])
    print("hit stack: lower box moved", moved, " vs untiered", ref_sc.bset.bodies[lower].position()[0] - x0, " diff", diff)
    s.check(moved > 0.05 and diff < 0.02, "a frozen stack hit by a sliding box wakes and moves like the untiered one (2 cm)")

    obs[0] = Vec3(100, 1, 0, 0)
    for _ in range(5):
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        sc.step(DT, G, cfg)
    var far_ok = True
    for ref c in pol.proxies:
        far_ok = far_ok and abs(c.centroid[0] - 100) > 35
    print("observer at x = 100: proxies", len(pol.proxies))
    s.check(far_ok and len(pol.proxies) < np, "stacks within 35 m of the moved observer are no longer proxies")
    s.finish()
