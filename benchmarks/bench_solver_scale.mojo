"""Production 6-DOF solver: O(n²) brute pair collection vs per-frame BVH.

`_collect_pairs` used to double-loop every body pair; `broadphase=True` swaps
that for a BVH over fat world-AABBs (`test_solver_broadphase` proves the two
are bit-identical). This table shows the crossover: brute wins at small N
(no build/query overhead), the BVH wins as N grows and the O(n²) enumeration
dominates. Scene = a grid of separated small towers so most pairs are
non-neighbours the broadphase can prune.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 80


def _grid(side: Int) raises -> ContactScene6[QuatBody6]:
    """side×side separated 2-box stacks on one ground plane. Total dynamic
    bodies = 2·side². Stacks are 3 m apart so only within-stack pairs touch —
    the O(n²) loop still visits all ~2n² of them; the BVH prunes to O(n)."""
    var sc = ContactScene6[QuatBody6]()
    var g = Real(side) * 3
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, g, 1, g)),
        Vec3(g, 1, g),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for a in range(side):
        for b in range(side):
            var x = Real(a) * 3 - g * 0.5
            var z = Real(b) * 3 - g * 0.5
            for i in range(2):
                _ = sc.add(
                    QuatBody6.at_rest(
                        Vec3(x, 0.3 + 0.52 * Real(i), z), bi
                    ),
                    Vec3(0.25, 0.25, 0.25),
                    False,
                )
    return sc^


def _run(mut sc: ContactScene6[QuatBody6], bp: Bool) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, broadphase=bp)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("6-DOF solver pair collection: brute O(n²) vs BVH")
    var sides = List[Int]()
    sides.append(2)
    sides.append(4)
    sides.append(8)
    sides.append(12)
    sides.append(16)
    for si in range(len(sides)):
        var side = sides[si]  # N = 2·side² -> 8, 32, 128, 288, 512
        var n = 2 * side * side
        var sb = _grid(side)
        t.add("brute N=" + String(n), n, "step", _run(sb, False), STEPS)
        var sp = _grid(side)
        t.add("bvh   N=" + String(n), n, "step", _run(sp, True), STEPS)
    t.print_report()
