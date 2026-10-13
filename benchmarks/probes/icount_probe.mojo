"""Fixed workload for the cachegrind instruction-count probe (ROADMAP 17.83).

A 40-box pile stepped `-D STEPS=N` times (default 60) with the default
solver configuration. `scripts/icount.py` runs it under
`valgrind --tool=cachegrind --cache-sim=no` and reads the instruction count;
`-D STEPS=66` is the injected +10 % regression its selftest must detect.
"""

from std.sys import get_defined_int
from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6


def main():
    comptime steps = get_defined_int["STEPS", 60]()
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k % 5) * 0.6 - 1.2, 0.3 + Real(k // 5) * 0.55, Real(k % 3) * 0.1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(steps):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    keep(sc.bset.bodies[3].pos[1])
