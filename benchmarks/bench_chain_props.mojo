"""ROADMAP 17.51: cost of the implicit joint-property step.

A serial chain of N revolute links under gravity, 120 steps each way:
`step` (CRBA + RNEA + dense solve) vs `step_implicit` with damping, spring,
armature and friction on every joint (the same factorisation plus one
matrix-vector product and the diagonal terms).
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 120


def _chain(n: Int, props: Bool) raises -> Chain:
    var c = Chain()
    for i in range(n):
        var axis = Vec3(0, 0, 1, 0) if i % 2 == 0 else Vec3(1, 0, 0, 0)
        c.add_link(ChainLink.revolute(axis, Vec3(0.2, 0, 0, 0) if i > 0 else Vec3(0, 0, 0, 0), Vec3(0.1, 0, 0, 0), 1, Vec3(0.01, 0.01, 0.01, 0)))
        if props:
            c.set_joint_props(i, Real(0.5), Real(30), Real(0), Real(0.02), Real(0.01))
    return c^


def main() raises:
    var t = BenchTable("Chain joint properties (17.51): step vs step_implicit")
    for n in [8, 32, 64]:
        var tau = List[Real]()
        for _ in range(n):
            tau.append(0)
        var a = _chain(n, False)
        var t0 = Int(perf_counter_ns())
        for _ in range(STEPS):
            a.step(DT, tau, G)
        var t1 = Int(perf_counter_ns())
        var b = _chain(n, True)
        var t2 = Int(perf_counter_ns())
        for _ in range(STEPS):
            b.step_implicit(DT, tau, G)
        var t3 = Int(perf_counter_ns())
        t.add("step (explicit)", n, "step", t1 - t0, STEPS)
        t.add("step_implicit, all properties", n, "step", t3 - t2, STEPS)
    t.print_report()
