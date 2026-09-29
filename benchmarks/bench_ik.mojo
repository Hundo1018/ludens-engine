"""IK solvers (ROADMAP 17.3): analytic two-bone vs FABRIK on the same leg,
and FABRIK's cost against chain length.

The two-bone rows are the seam (`test_ik` checks the two put the ankle in
the same place). The chain rows sweep joints at a fixed tolerance, reporting
the iterations FABRIK needed as well as the time.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from procedural.ik import two_bone, fabrik

comptime ITERS = 2000


def main() raises:
    var t = BenchTable("IK: analytic two-bone vs FABRIK; FABRIK vs chain length")
    var hip = Vec3(0, 1, 0, 0)
    var knee = Vec3(0, 0.55, 0.05, 0)
    var ankle = Vec3(0, 0.1, 0, 0)
    var t0 = Int(perf_counter_ns())
    for i in range(ITERS):
        var r = two_bone(hip, knee, ankle, Vec3(0.2, 0.3 + Real(i % 7) * 0.01, 0.3, 0), Vec3(0, 0.5, 1, 0))
        keep(r.end[0])
    t.add("two-bone analytic", 3, "solve", Int(perf_counter_ns()) - t0, ITERS)
    var t1 = Int(perf_counter_ns())
    var used = 0
    for i in range(ITERS):
        var leg = List[Vec3]()
        leg.append(hip)
        leg.append(knee)
        leg.append(ankle)
        used += fabrik(leg, Vec3(0.2, 0.3 + Real(i % 7) * 0.01, 0.3, 0), 64, 1e-4)
        keep(leg[2][0])
    t.add("two-bone by FABRIK (" + String(used // ITERS) + " iters avg)", 3, "solve", Int(perf_counter_ns()) - t1, ITERS)
    for n in [4, 16, 64]:
        var tn = Int(perf_counter_ns())
        var it_sum = 0
        for i in range(ITERS // 10):
            var ch = List[Vec3]()
            for j in range(n):
                ch.append(Vec3(0, Real(j) / Real(n), 0, 0))
            it_sum += fabrik(ch, Vec3(0.4, 0.5 + Real(i % 5) * 0.02, 0.2, 0), 64, 1e-4)
            keep(ch[n - 1][0])
        t.add("FABRIK chain (" + String(it_sum // (ITERS // 10)) + " iters avg)", n, "solve", Int(perf_counter_ns()) - tn, ITERS // 10)
    t.print_report()
