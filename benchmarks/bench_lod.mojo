"""Physics LOD (ROADMAP 17.31): the quality-vs-cost curve the budget moves
along, and what freezing buys.

Curve: a 10-box stack stepped 2 s at iterations 1..8 (4 substeps): time per
frame and the stack's settled top height error against the ideal 0.2 + 9 x
0.4 + 0.2 -- the degradation a budget trades for time. Freeze: N crates on
the ground, all awake vs half frozen by a DistanceLOD.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.lod import DistanceLOD

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def main() raises:
    var t = BenchTable("Physics LOD: iterations vs cost and stack error; freezing half the scene")
    for iters in [1, 2, 4, 8]:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
        for k in range(10):
            var id = sc.add(QuatBody6.at_rest(Vec3(0, 0.2 + Real(k) * 0.41, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
            sc.set_can_sleep(id, False)
        var cfg = SolverConfig()
        cfg.iters = iters
        var t0 = Int(perf_counter_ns())
        for _ in range(120):
            sc.step(DT, G, cfg)
        var d = Int(perf_counter_ns()) - t0
        var err = abs(sc.bset.bodies[10].position()[1] - Real(0.2 + 9 * 0.4))
        keep(err)
        t.add("10-stack, iters=" + String(iters) + " (top error " + String(Int(err * 1000)) + " mm)", 10, "frame", d, 120)
    for n in [256, 1024]:
        for frozen in [False, True]:
            var sc = ContactScene6[QuatBody6]()
            _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 60, 0.5, 60)), Vec3(60, 0.5, 60, 0), True)
            for i in range(n):
                var x = Real(i % 32) * 1.2 - 19
                var z = Real(i // 32) * 1.2 - 19
                var id = sc.add(QuatBody6.at_rest(Vec3(x, 0.2, z, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
                sc.set_can_sleep(id, False)
            if frozen:
                var lod = DistanceLOD(0.1, 0)
                # observer far out on -x: the half at x > 0 is beyond reach
                _ = lod.update(sc, Vec3(-1000, 0, 0, 0))
                for i in range(1, len(sc.bset.bodies)):
                    if sc.bset.bodies[i].position()[0] < 0:
                        sc.unfreeze(sc.bset.id_of(i))
            var t0 = Int(perf_counter_ns())
            for _ in range(30):
                sc.step_soft(DT, G, broadphase=True)
            var d = Int(perf_counter_ns()) - t0
            keep(sc.bset.bodies[1].position()[1])
            t.add("crates, " + ("half frozen" if frozen else "all awake"), n, "frame", d, 30)
    t.print_report()
