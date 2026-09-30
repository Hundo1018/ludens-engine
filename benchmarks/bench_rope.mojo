"""Ropes (ROADMAP 17.41): XPBD rope vs a chain of rigid links on distance
joints for the same span, over node count; and the rope's collision pass
(one world query per particle per substep) switched on over a static box.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.rope import Rope

comptime DT: Real = 1.0 / 60.0
comptime FRAMES = 30
comptime G = Vec3(0, -9.8, 0, 0)


def main() raises:
    var t = BenchTable("Rope per frame: XPBD rope vs distance-joint link chain; rope collision on/off")
    for n in [16, 64, 256]:
        var empty = ContactScene6[QuatBody6]()
        var r = Rope(Vec3(-1, 0, 0, 0), Vec3(1, 0, 0, 0), n, 1, 0, 0, 3)
        r.pin(0, Vec3(-1, 0, 0, 0))
        r.pin(1, Vec3(1, 0, 0, 0))
        var t0 = Int(perf_counter_ns())
        for _ in range(FRAMES):
            r.step(empty, DT, G, 8, 8)
        t.add("XPBD rope (8 substeps x 8 iters)", n, "frame", Int(perf_counter_ns()) - t0, FRAMES)
        keep(r.x[n // 2][1])

        var ch = ContactScene6[QuatBody6]()
        _ = ch.add(QuatBody6.at_rest(Vec3(-1, 0, 0, 0), Inertia3.box(1, 0.01, 0.01, 0.01)), Vec3(0.01, 0.01, 0.01, 0), True)
        for i in range(n - 1):
            var x = -1 + 2 * Real(i + 1) / Real(n)
            var id = ch.add(QuatBody6.at_rest(Vec3(x, 0, 0, 0), Inertia3.box(1.0 / Real(n), 0.005, 0.005, 0.005)), Vec3(0.005, 0.005, 0.005, 0), False)
            ch.set_filter(id.index(), 2, 1)
        _ = ch.add(QuatBody6.at_rest(Vec3(1, 0, 0, 0), Inertia3.box(1, 0.01, 0.01, 0.01)), Vec3(0.01, 0.01, 0.01, 0), True)
        for i in range(n):
            _ = ch.add_joint(Joint6.distance(i, i + 1, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), Real(3) / Real(n)))
        var t1 = Int(perf_counter_ns())
        for _ in range(FRAMES):
            ch.step_soft(DT, G, substeps=8, iters=8, broadphase=True)
        t.add("distance-joint link chain (8 x 8)", n, "frame", Int(perf_counter_ns()) - t1, FRAMES)
        keep(ch.bset.bodies[1].position()[1])

    for n in [16, 64]:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), True)
        var r = Rope(Vec3(-1, 1, 0, 0), Vec3(1, 1, 0, 0), n, 0.3, 0, 0.03)
        var t0 = Int(perf_counter_ns())
        for _ in range(FRAMES):
            r.step(sc, DT, G)
        t.add("XPBD rope, collision on (8 substeps x 4 iters)", n, "frame", Int(perf_counter_ns()) - t0, FRAMES)
        keep(r.x[n // 2][1])
    t.print_report()
