"""Tiered simulation (ROADMAP 17.85): step cost per policy.

n awake boxes in two-box stacks on a square floor (sleeping off, so every
island is live), one observer at a corner: the interactable set (within 8 m)
is about 1e2 bodies regardless of n. Tier table: 0 = full config, 1 = same
quality every 2nd step, 2 = 2 iterations / 2 substeps every 4th step (both
catch up the skipped time). Policies: untiered, DistanceTiers (8 / 20 m),
CausalReach (seed 8 m, depth 0 / 2), RoundRobin (everything tier 2),
BudgetTiers (DistanceTiers whose radii follow a 50 %-of-untiered budget),
AggregateTiers (resting islands beyond 20 m frozen in tier 3, period 0, and
kept as cluster proxies).
The DBVH row runs the same scene on the persistent `DbvhBroadPhase` (only
moved proxies are re-inserted) instead of the default per-step BVH build.
The `+ reuse_still_pairs` rows copy last collection's narrowphase output
for pairs whose bodies did not move (bit-identical, `test_np_reuse`).
Labels: islands solved per step and, for n = 1e3 (run beside an untiered
copy), the deepest penetration beyond the untiered run's.

Run: pixi run mojo run -I build benchmarks/bench_tiers.mojo
"""

from std.benchmark import keep
from std.math import sqrt
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from physics.rigid6 import Body6, Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase
from physics.solver_config import SolverConfig
from gameplay.tiers import TierPolicy, DistanceTiers, CausalReach, RoundRobin, BudgetTiers, AggregateTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 40
comptime WARM = 10


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def build[BP: BroadPhase = BVHBroadPhase[3]](n: Int, tiered: Bool) raises -> ContactScene6[QuatBody6, BP]:
    var side = Int(sqrt(Float64(n // 2))) + 1
    var sc = ContactScene6[QuatBody6, BP]()
    var L = Real(side) * 2
    _ = sc.add(QuatBody6.at_rest(_v(L / 2, -0.5, L / 2), Inertia3.box(1, L, 0.5, L)), _v(L / 2 + 1, 0.5, L / 2 + 1), True)
    var made = 0
    for gx in range(side):
        for gz in range(side):
            if made >= n:
                break
            for k in range(2):
                var id = sc.add(
                    QuatBody6.at_rest(_v(Real(gx) * 2 + 1, 0.25 + Real(k) * 0.51, Real(gz) * 2 + 1), Inertia3.box(1, 0.25, 0.25, 0.25)),
                    _v(0.25, 0.25, 0.25), False,
                )
                sc.set_can_sleep(id, False)
                made += 1
    if tiered:
        var cfg = SolverConfig()
        cfg.broadphase = True
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
        it.append(2)  # tier 3: frozen (AggregateTiers)
        su.append(2)
        pe.append(0)
        sc.set_tier_table(it, su, pe)
    return sc^


def deepest[BP: BroadPhase](sc: ContactScene6[QuatBody6, BP]) -> Real:
    var d = Real(0)
    for c in sc.cache:
        for p in range(c.m.count):
            d = max(d, c.m.depths[p])
    return d


def _run[P: TierPolicy, BP: BroadPhase = BVHBroadPhase[3]](mut t: BenchTable, var pol: P, name: String, n: Int, budget_ns: Int, reuse: Bool = False) raises:
    var sc = build[BP](n, True)
    var full = build(n, False)
    var cfg = SolverConfig()
    cfg.broadphase = True
    cfg.reuse_still_pairs = reuse
    var obs = List[Vec3]()
    obs.append(_v(0, 1, 0))
    var ns = 0
    var solved = 0
    var gap = Real(0)
    for k in range(WARM + STEPS):
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        var t0 = now()
        sc.step(DT, G, cfg)
        var dt_ns = now() - t0
        if k >= WARM:
            ns += dt_ns
            solved += sc.islands_solved
        if n <= 1000:
            full.step(DT, G, cfg)
            if k >= WARM:
                gap = max(gap, deepest(sc) - deepest(full))
    var label = name + " (" + String(solved // STEPS) + " islands solved / step"
    if n <= 1000:
        label += ", penetration +" + String(Int(gap * 1000)) + " mm"
    label += ")"
    t.add(label, n, "step", ns, STEPS)


struct Untiered(TierPolicy):
    def __init__(out self):
        pass

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        return List[Int](length=len(scene.bset.bodies), fill=0)


struct Budgeted(TierPolicy):
    """BudgetTiers fed with the measured cost of the step it planned."""

    var inner: BudgetTiers
    var t0: Int

    def __init__(out self, target_ns: Int) raises:
        var r = List[Real]()
        r.append(8)
        r.append(20)
        self.inner = BudgetTiers(r^, target_ns, 1.5, 0.8)
        self.t0 = 0

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        var t = now()
        if self.t0 > 0:
            self.inner.measured(t - self.t0)
        self.t0 = t
        return self.inner.assign(scene, observers, step)


def main() raises:
    var t = BenchTable("Tiered simulation (17.85): awake two-box stacks, observer at a corner")
    for n in [1000, 10000]:
        # untiered reference cost
        var base = build(n, False)
        var cfg = SolverConfig()
        cfg.broadphase = True
        for _ in range(WARM):
            base.step(DT, G, cfg)
        var t0 = now()
        for _ in range(STEPS):
            base.step(DT, G, cfg)
        var full_ns = (now() - t0) // STEPS
        t.add("untiered", n, "step", full_ns * STEPS, STEPS)
        var r1 = List[Real]()
        r1.append(8)
        r1.append(20)
        _run(t, DistanceTiers(r1^, 1.5), "DistanceTiers 8 / 20 m", n, 0)
        var d = List[Int]()
        d.append(0)
        d.append(2)
        _run(t, CausalReach(8, d^), "CausalReach seed 8 m, depth 0 / 2", n, 0)
        _run(t, RoundRobin(2), "RoundRobin (all tier 2)", n, 0)
        _run(t, Budgeted(full_ns // 2), "BudgetTiers (50 % of untiered)", n, full_ns // 2)
        _run(t, Untiered(), "all tier 0 (parity anchor)", n, 0)
        _run(t, AggregateTiers(20, 0.05, 3), "AggregateTiers 20 m (rest stacks beyond frozen as proxies)", n, 0)
        var r2 = List[Real]()
        r2.append(8)
        r2.append(20)
        _run(t, DistanceTiers(r2^, 1.5), "DistanceTiers 8 / 20 m + reuse_still_pairs", n, 0, True)
        _run(t, RoundRobin(2), "RoundRobin + reuse_still_pairs", n, 0, True)
        var r3 = List[Real]()
        r3.append(8)
        r3.append(20)
        _run[DistanceTiers, DbvhBroadPhase[3]](t, DistanceTiers(r3^, 1.5), "DistanceTiers 8 / 20 m + reuse_still_pairs, DBVH broadphase", n, 0, True)
        var r4 = List[Real]()
        r4.append(8)
        r4.append(20)
        _run[DistanceTiers, DbvhBroadPhase[3]](t, DistanceTiers(r4^, 1.5), "DistanceTiers 8 / 20 m, DBVH broadphase", n, 0, False)
    t.print_report()
