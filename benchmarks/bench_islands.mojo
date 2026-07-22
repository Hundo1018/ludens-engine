"""Island-parallel solver: serial vs threaded on a many-island scene.

16 separated 4-box towers = 16 independent islands (64 dynamic bodies).
`test_islands_par` proves the two paths are bit-identical; this table shows
what the worker threads buy (and what they cost on a single big island,
where there is nothing to parallelise — honesty row).
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 300


def _towers(n_towers: Int, height: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 100, 1, 100)),
        Vec3(100, 1, 100),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for t in range(n_towers):
        var x = Real(t) * 3
        for i in range(height):
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    return sc^


def _run(mut sc: ContactScene6[QuatBody6], parallel: Bool) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, parallel=parallel)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("island-parallel solver: serial vs threads")
    # many small islands: the parallel win case
    var s16 = _towers(16, 4)
    t.add("serial 16 towers x4", 64, "step", _run(s16, False), STEPS)
    var p16 = _towers(16, 4)
    t.add("parallel 16 towers x4", 64, "step", _run(p16, True), STEPS)
    # one big island: nothing to parallelise (thread overhead honesty row)
    var s1 = _towers(1, 8)
    t.add("serial 1 tower x8", 8, "step", _run(s1, False), STEPS)
    var p1 = _towers(1, 8)
    t.add("parallel 1 tower x8", 8, "step", _run(p1, True), STEPS)
    t.print_report()
