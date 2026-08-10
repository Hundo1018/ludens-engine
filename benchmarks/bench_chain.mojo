"""Articulated chain: reduced coordinates (CRBA+RNEA) vs maximal (solver6).

The same n-link pendulum chain in the two formulations the engine now has:
`physics/chain.mojo` integrates n joint coordinates with exact constraints;
`ContactScene6` integrates 6n rigid coordinates with soft hinge joints.
`test_chain` shows they agree on the physics (shared analytic period);
this table shows what each formulation costs as the chain grows.
"""

from std.time import perf_counter_ns
from std.benchmark import keep
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
            ChainLink.revolute(
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
            ChainLink.revolute(
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


def bench_id(n: Int) raises -> Int:
    """Inverse dynamics alone: one O(n) Newton-Euler sweep, no mass matrix."""
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
    for i in range(n):
        c.q[i] = Real(i) * 0.1
        c.qd[i] = Real(i) * 0.05
    var qdd = List[Real]()
    for i in range(n):
        qdd.append(Real(i) * 0.02)
    var best = Int.MAX
    for _ in range(3):
        var t0 = Int(perf_counter_ns())
        for _ in range(STEPS):
            var tau = c.inverse_dynamics(qdd, G)
            keep(tau[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    return best


def bench_kind(n: Int, prismatic: Bool, limits: Bool) raises -> Int:
    """Step cost by joint kind, and what a limit pass adds."""
    var c = Chain()
    for i in range(n):
        var l = (
            ChainLink.prismatic(
                Vec3(0, -1, 0), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
            if (prismatic and i % 2 == 1)
            else ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
        c.add_link(l.limited(-0.8, 0.8) if limits else l)
    var zero = List[Real]()
    for _ in range(n):
        zero.append(0)
    var best = Int.MAX
    for _ in range(3):
        var t0 = Int(perf_counter_ns())
        for _ in range(STEPS):
            c.step(DT, zero, G)
            if limits:
                _ = c.resolve_limits(DT)
        var dt = Int(perf_counter_ns()) - t0
        keep(c.q[0])
        if dt < best:
            best = dt
    return best


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
    # --- inverse vs forward dynamics -----------------------------------
    # ID is one O(n) sweep; FD forms the CRBA mass matrix and solves it
    # densely, which is O(n^3). Controllers use ID for feed-forward precisely
    # because of this gap, so the axis is n and the point is the SHAPE of the
    # two curves rather than either absolute number.
    var idt = BenchTable("Inverse vs forward dynamics (O(n) sweep vs dense O(n^3) solve)")
    comptime for ni in range(4):
        comptime NL = 2 if ni == 0 else (8 if ni == 1 else (24 if ni == 2 else 64))
        idt.add("inverse dynamics (RNEA)", NL, "step", bench_id(NL), STEPS)
        idt.add("forward dynamics (CRBA+solve)", NL, "step", bench_reduced(NL), STEPS)
    idt.print_report()

    # --- joint kind and limits -----------------------------------------
    # The prismatic rows exist to show the motion-subspace branch costs
    # nothing measurable: S is (axis,0) or (0,axis) and every sweep picks one,
    # so a mixed chain should track a revolute one. The limit rows price the
    # one-sided constraint pass, which is only paid while a joint is actually
    # against its stop.
    var jt = BenchTable("Joint kinds and limits: step cost")
    comptime for ki in range(3):
        comptime NL = 4 if ki == 0 else (8 if ki == 1 else 16)
        jt.add("revolute only", NL, "step", bench_kind(NL, False, False), STEPS)
        jt.add("mixed revolute+prismatic", NL, "step", bench_kind(NL, True, False), STEPS)
        jt.add("revolute + limit pass", NL, "step", bench_kind(NL, False, True), STEPS)
    jt.print_report()

    t.print_report()
