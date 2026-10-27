"""Experiment — where the 6-DOF solver spends its step at N ~ 4096 (ROADMAP 17.19).

The grid of 2-box towers from `benchmarks/bench_solver_scale.mojo` (side 45,
N = 2 * 45^2 = 4050 dynamic bodies) is stepped STEPS times through
`step_soft(broadphase=True)`. Built as a standalone binary and run under
callgrind, the inclusive cost of the BVH rebuild (`physics/solver6.mojo`
`_collect_pairs`), the contact colouring (`_color_pairs`) and the CCD pass is
read from `callgrind_annotate --inclusive=yes`. Wall time is printed too, but
the instruction profile is the measurement; one hotspot is changed per commit.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime SIDE = 45
comptime STEPS = 20
comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)


def _grid(side: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var g = Real(side) * 3
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, g, 1, g)),
        Vec3(g, 1, g, 0),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for a in range(side):
        for b in range(side):
            var x = Real(a) * 3 - g * 0.5
            var z = Real(b) * 3 - g * 0.5
            for i in range(2):
                _ = sc.add(
                    QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), z, 0), bi),
                    Vec3(0.25, 0.25, 0.25, 0),
                    False,
                )
    return sc^


def main() raises:
    var sc = _grid(SIDE)
    print("bodies", 2 * SIDE * SIDE, "steps", STEPS)
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, broadphase=True)
    var ms = Real(Int(perf_counter_ns()) - t0) / 1e6
    print("wall ms", ms, "per step ms", ms / Real(STEPS))
