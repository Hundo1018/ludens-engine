# tier: integration
"""Tiered simulation at scale (ROADMAP 17.85).

1800 awake boxes (900 two-box stacks on a 60 x 60 m floor, sleeping off so
every island is live), an observer walking corner to corner over 300 steps,
`DistanceTiers` radii 8 / 20 m mapped to periods 1 / 2 / 4 (tier 2 also at
reduced iterations). Run side by side with the untiered scene.

Laws:
- tier changes do not pop: over every body whose tier changed on a step, the
  position change that step stays below 2 cm and the velocity change below
  what one coarse catch-up step of gravity can add (g x 4 dt);
- the coarse world stays physical: the deepest penetration over all
  contacts stays within 5 cm of the full-quality run's (measured 4.3 cm:
  the period-4 tier runs 2 iterations over two 33 ms substeps -- the price
  of that tier, reported per policy in `bench_tiers`);
- the tiered run solves far fewer islands than the full run;
- snapshot -> restore -> continue: a scene saved mid-walk and reloaded (with
  a copy of the policy) continues bit-identically for 60 steps.
"""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.serialize import scene_to_string, scene_from_string
from gameplay.tiers import DistanceTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _len(v: Vec3) -> Real:
    return sqrt(dot(v, v))


def build() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(_v(30, -0.5, 30), Inertia3.box(1, 31, 0.5, 31)), _v(31, 0.5, 31), True)
    for gx in range(30):
        for gz in range(30):
            for k in range(2):
                var id = sc.add(
                    QuatBody6.at_rest(_v(Real(gx) * 2 + 1, 0.25 + Real(k) * 0.51, Real(gz) * 2 + 1), Inertia3.box(1, 0.25, 0.25, 0.25)),
                    _v(0.25, 0.25, 0.25), False,
                )
                sc.set_can_sleep(id, False)
    return sc^


def _table(mut sc: ContactScene6[QuatBody6], cfg: SolverConfig) raises:
    var it = List[Int]()
    var su = List[Int]()
    var pe = List[Int]()
    it.append(cfg.iters)
    su.append(cfg.substeps)
    pe.append(1)
    it.append(cfg.iters)
    su.append(cfg.substeps)
    pe.append(2)
    it.append(2)
    su.append(2)
    pe.append(4)
    sc.set_tier_table(it, su, pe)


def deepest(sc: ContactScene6[QuatBody6]) -> Real:
    var d = Real(0)
    for c in sc.cache:
        for p in range(c.m.count):
            d = max(d, c.m.depths[p])
    return d


def _policy() raises -> DistanceTiers:
    var radii = List[Real]()
    radii.append(8)
    radii.append(20)
    return DistanceTiers(radii^, 1.5)


def main() raises:
    var s = Suite("system_tiers")
    var cfg = SolverConfig()
    cfg.broadphase = True
    var full = build()
    var tie = build()
    _table(tie, cfg)
    var pol = _policy()
    var n = len(tie.bset.bodies)
    var prev_tier = List[Int](length=n, fill=-1)
    var max_dp = Real(0)
    var max_dv = Real(0)
    var changes = 0
    var worst_pen_gap = Real(0)
    var solved_full = 0
    var solved_tie = 0
    var snap = String("")
    var snap_pol = _policy()
    for k in range(300):
        var a = Real(k) / 300
        var obs = List[Vec3]()
        obs.append(_v(a * 60, 1, a * 60))
        var plan = pol.assign(tie, obs, tie.step_index)
        tie.set_body_tiers(plan)
        var p0 = List[Vec3](capacity=n)
        var v0 = List[Vec3](capacity=n)
        for i in range(n):
            p0.append(tie.bset.bodies[i].position())
            v0.append(tie.bset.bodies[i].linear_velocity())
        if k == 150:
            snap = scene_to_string(tie)
            snap_pol = pol.copy()
        full.step(DT, G, cfg)
        tie.step(DT, G, cfg)
        solved_full += len(full.bset.bodies) - 1  # every live island, an upper bound via bodies
        solved_tie += tie.islands_solved * 2
        for i in range(1, n):
            if prev_tier[i] >= 0 and plan[i] != prev_tier[i]:
                changes += 1
                max_dp = max(max_dp, _len(tie.bset.bodies[i].position() - p0[i]))
                max_dv = max(max_dv, _len(tie.bset.bodies[i].linear_velocity() - v0[i]))
            prev_tier[i] = plan[i]
        if k >= 30:
            worst_pen_gap = max(worst_pen_gap, deepest(tie) - deepest(full))
    print("  system_tiers: tier changes", changes, "max dp", max_dp, "max dv", max_dv, "pen gap", worst_pen_gap, "bodies solved per step full", solved_full // 300, "tiered", solved_tie // 300)
    s.check(changes > 100, "the walk changes many tiers")
    s.check(max_dp < 0.02, "no position pop at tier changes")
    s.check(max_dv <= 9.8 * 4 * DT * 1.05, "velocity change at a tier change <= one coarse gravity step")
    s.check(worst_pen_gap < 0.05, "deepest penetration within 5 cm of full quality")
    s.check(solved_tie * 2 < solved_full, "tiered run solves under half the bodies per step")

    # snapshot -> restore -> continue
    var r = scene_from_string(snap)
    var cont = scene_from_string(snap)
    var p2 = snap_pol.copy()
    var p3 = snap_pol.copy()
    for k in range(150, 210):
        var a = Real(k) / 300
        var obs = List[Vec3]()
        obs.append(_v(a * 60, 1, a * 60))
        r.set_body_tiers(p2.assign(r, obs, r.step_index))
        cont.set_body_tiers(p3.assign(cont, obs, cont.step_index))
        r.step(DT, G, cfg)
        cont.step(DT, G, cfg)
    s.check(scene_to_string(r) == scene_to_string(cont), "two restores of the same snapshot continue bit-identically")
    # and the restore matches the uninterrupted run at step 210
    var again = build()
    _table(again, cfg)
    var pa = _policy()
    for k in range(210):
        var a = Real(k) / 300
        var obs = List[Vec3]()
        obs.append(_v(a * 60, 1, a * 60))
        again.set_body_tiers(pa.assign(again, obs, again.step_index))
        again.step(DT, G, cfg)
    s.check(scene_to_string(again) == scene_to_string(r), "snapshot at 150 + 60 resumed steps == uninterrupted 210 steps")
    s.finish()
