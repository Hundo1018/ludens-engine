"""Articulated chain: reduced coordinates (CRBA+RNEA) vs maximal (solver6).

The same n-link pendulum chain in the two formulations the engine now has:
`physics/chain.mojo` integrates n joint coordinates with exact constraints;
`ContactScene6` integrates 6n rigid coordinates with soft hinge joints.
`test_chain` shows they agree on the physics (shared analytic period);
this table shows what each formulation costs as the chain grows.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 600


def bench_reduced(n: Int) raises -> Int:
    var c = Chain()
    for i in range(n):
        c.add_link(
            ChainLink(
                Vec3(0, 0, 1),
                Vec3(0, 0, 0) if i == 0 else Vec3(0, -1, 0),
                Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
    c.q[0] = 0.3
    var tau = List[Real]()
    for _ in range(n):
        tau.append(0)
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        c.step(DT, tau, G)
    return Int(perf_counter_ns()) - t0


def bench_aba(n: Int) raises -> Int:
    var c = Chain()
    for i in range(n):
        c.add_link(
            ChainLink(
                Vec3(0, 0, 1),
                Vec3(0, 0, 0) if i == 0 else Vec3(0, -1, 0),
                Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
    c.q[0] = 0.3
    var tau = List[Real]()
    for _ in range(n):
        tau.append(0)
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        c.step_aba(DT, tau, G)
    return Int(perf_counter_ns()) - t0


def bench_maximal(n: Int) raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05),
        True,
    )
    var ib = Inertia3.box(1, 0.05, 0.5, 0.05)
    for i in range(n):
        var idx = sc.add(
            QuatBody6.at_rest(Vec3(0, -0.5 - Real(i), 0), ib),
            Vec3(0.05, 0.5, 0.05),
            False,
        )
        _ = sc.add_joint(
            Joint6.hinge(idx - 1, idx, Vec3(0, 0, 0) if i == 0 else Vec3(0, -0.5, 0),
                         Vec3(0, 0.5, 0), Vec3(0, 0, 1))
        )
    sc.bodies[1].vel = Vec3(0.3, 0, 0)
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("articulated chain: reduced (CRBA+RNEA) vs maximal (soft joints)")
    for size in range(4):
        var n = 4 if size == 0 else (
            8 if size == 1 else (16 if size == 2 else 64)
        )
        t.add("reduced n=" + String(n), n, "step", bench_reduced(n), STEPS)
        t.add("aba n=" + String(n), n, "step", bench_aba(n), STEPS)
        if n <= 16:
            t.add(
                "maximal n=" + String(n), n, "step", bench_maximal(n), STEPS
            )
    t.print_report()
