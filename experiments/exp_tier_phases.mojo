"""Where a tiered step's time goes at n = 1e4 and 1e5 (ROADMAP 17.85).

The 17.85 leftovers are questions of share: is sleep / island bookkeeping
worth an awake list, is an incremental `BroadPhase.update_moved` worth it
over the persistent DBVH, and does n = 1e5 run at all. This steps the
`bench_tiers` scene (awake two-box stacks on one floor, observer at a
corner) under `DistanceTiers` 8 / 20 m with the persistent DBVH and
`reuse_still_pairs`, and prints each traced phase's share of the step.

Run (tracing must be compiled in):
    pixi run mojo run -D LUDENS_TRACE -I build experiments/exp_tier_phases.mojo
"""

from std.math import sqrt
from harness.bench import now
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.bp_dbvh import DbvhBroadPhase
from physics.solver_config import SolverConfig
from gameplay.tiers import DistanceTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 20
comptime WARM = 5


def build(n: Int) raises -> ContactScene6[QuatBody6, DbvhBroadPhase[3]]:
    var side = Int(sqrt(Float64(n // 2))) + 1
    var sc = ContactScene6[QuatBody6, DbvhBroadPhase[3]]()
    var L = Real(side) * 2
    _ = sc.add(QuatBody6.at_rest(Vec3(L / 2, -0.5, L / 2, 0), Inertia3.box(1, L, 0.5, L)), Vec3(L / 2 + 1, 0.5, L / 2 + 1, 0), True)
    var made = 0
    for gx in range(side):
        for gz in range(side):
            if made >= n:
                break
            for k in range(2):
                var id = sc.add(
                    QuatBody6.at_rest(Vec3(Real(gx) * 2 + 1, 0.25 + Real(k) * 0.51, Real(gz) * 2 + 1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
                    Vec3(0.25, 0.25, 0.25, 0), False,
                )
                sc.set_can_sleep(id, False)
                made += 1
    var it: List[Int] = [4, 4, 2]
    var su: List[Int] = [4, 4, 2]
    var pe: List[Int] = [1, 2, 4]
    sc.set_tier_table(it, su, pe)
    sc.trace.capacity = 4096
    return sc^


def run(n: Int) raises:
    var sc = build(n)
    var cfg = SolverConfig()
    cfg.broadphase = True
    cfg.reuse_still_pairs = True
    var r: List[Real] = [8, 20]
    var pol = DistanceTiers(r^, 1.5)
    var obs: List[Vec3] = [Vec3(0, 1, 0, 0)]
    var plan_ns = 0
    var step_ns = 0
    for k in range(WARM + STEPS):
        if k == WARM:
            sc.trace.events = List[type_of(sc.trace.events[0])]() if len(sc.trace.events) > 0 else sc.trace.events.copy()
        var t0 = now()
        sc.set_body_tiers(pol.assign(sc, obs, sc.step_index))
        var t1 = now()
        sc.step(DT, G, cfg)
        var t2 = now()
        if k >= WARM:
            plan_ns += t1 - t0
            step_ns += t2 - t1
    var per = Float64(step_ns) / STEPS / 1e6
    print("n =", n, " bodies", len(sc.bset.bodies), " step", per, "ms  tier plan", Float64(plan_ns) / STEPS / 1e6, "ms")
    for st in sc.trace.stats():
        var ms = Float64(st.total_ns) / Float64(st.count) / 1e6
        print("   ", st.name, " ", ms, "ms /", Int(100 * ms / per), "% of the step")


def main() raises:
    run(10000)
    run(100000)
