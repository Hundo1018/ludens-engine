"""A floating base against the way you would fake one without it.

The standard workaround for a free-flying body in a fixed-base solver is to
bolt it to the world through six pseudo-joints: three prismatic for position,
three revolute for orientation. It needs no new code, it reuses the whole
articulated pipeline, and for most configurations it is right. So it is the
control group, and the first table gives it the cost comparison.

That table read the other way at first. With the mass matrix assembled by unit
accelerations the pseudo-joint version won by 2-4.3x, and the breakdown table
below is why it was worth looking: the assembly was 88-94% of the solve and
the dense elimination only 5-6%, so the deficit was one routine and not the
idea. Extending the composite-inertia recursion to the base closed it and the
verdict reversed. Both assemblies are still here, and the slow one still earns
its place -- it derives the coupling block from nothing the recursion shares,
so the test that demands they agree means something.

The second table is where it stops being right. Three revolute joints are an
EULER ANGLE parameterisation, and Euler angles are singular: at a pitch of
90 degrees the first and third axes align, the map from joint rates to angular
velocity loses rank, and there is no assignment of joint accelerations that
produces a rotation about the lost direction. The mass matrix goes singular
with it. The sweep walks pitch toward the singularity and reports the joint
accelerations the solver must produce to represent a bounded physical motion —
they diverge, and the number is the evidence. A quaternion base holds the same
motion at a fixed cost because it never builds the map that degenerates.

This is a capability difference wearing a performance table's clothes: the
last rows of the second sweep are not "slower", they are wrong, and no amount
of tuning the pseudo-joint version fixes an angle that has no inverse.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.chain import Chain, ChainLink
from physics.floating import FloatingChain

comptime REPS = 3
comptime ITERS = 200
comptime BASE_M = Real(4.0)
comptime BASE_I = Vec3(0.3, 0.4, 0.35)


def _arm(i: Int) -> ChainLink:
    return ChainLink.revolute(
        Vec3(0, 0, 1) if i % 2 == 0 else Vec3(0, 1, 0),
        Vec3(0.5, 0.1, 0),
        Vec3(0.25, 0, 0),
        0.8 + Real(i) * 0.1,
        Vec3(0.02, 0.03, 0.025),
    )


def _floating(n: Int) -> FloatingChain:
    var f = FloatingChain(BASE_M, Vec3(0, 0, 0), BASE_I)
    for i in range(n):
        f.add_link(_arm(i))
    return f^


def _emulated(n: Int) raises -> Chain:
    """Six pseudo-joints carrying the same base body and the same arm.

    The three prismatic joints are massless; the base's inertia sits on the
    last revolute link, which is the body itself. That keeps the two models
    describing the same physical system rather than merely the same DOF
    count."""
    var c = Chain()
    var tiny = Vec3(1e-9, 1e-9, 1e-9)
    c.add_link(ChainLink.prismatic(Vec3(1, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), 1e-9, tiny))
    _ = c.add_link_to(0, ChainLink.prismatic(Vec3(0, 1, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), 1e-9, tiny))
    _ = c.add_link_to(1, ChainLink.prismatic(Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0), 1e-9, tiny))
    _ = c.add_link_to(2, ChainLink.revolute(Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0), 1e-9, tiny))
    _ = c.add_link_to(3, ChainLink.revolute(Vec3(0, 1, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), 1e-9, tiny))
    _ = c.add_link_to(4, ChainLink.revolute(Vec3(1, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), BASE_M, BASE_I))
    var prev = 5
    for i in range(n):
        prev = c.add_link_to(prev, _arm(i))
    return c^


def _cost(mut t: BenchTable, n: Int) raises:
    var f = _floating(n)
    for i in range(n):
        f.chain.q[i] = 0.2 + Real(i) * 0.1
        f.chain.qd[i] = 0.3 - Real(i) * 0.05
    var tau = List[Real]()
    for _ in range(n):
        tau.append(0.1)
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var a = f.dynamics(tau, Vec3(0, -9.81, 0))
            keep(a[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add("quaternion floating base", n, "solve", best, ITERS)

    var c = _emulated(n)
    for i in range(n):
        c.q[6 + i] = 0.2 + Real(i) * 0.1
        c.qd[6 + i] = 0.3 - Real(i) * 0.05
    var tau2 = List[Real]()
    for _ in range(6 + n):
        tau2.append(0)
    for i in range(n):
        tau2[6 + i] = 0.1
    var best2 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var a = c.dynamics(tau2, Vec3(0, -9.81, 0))
            keep(a[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best2:
            best2 = dt
    t.add("six pseudo-joints (Euler)", n, "solve", best2, ITERS)


def _breakdown(mut t: BenchTable, n: Int) raises:
    """Where the floating solve spends its time.

    Printed because the cost table above is a LOSS and a loss is only useful
    if it says what to fix. The three rows split the solve into assembling H,
    computing the bias, and the dense elimination. If the assembly dominates
    then the deficit is the unit-acceleration shortcut and not the floating
    base itself, and a floating-base CRBA — one sweep instead of 6+n of them,
    with no per-column allocation — is the specific thing that closes it."""
    var f = _floating(n)
    for i in range(n):
        f.chain.q[i] = 0.2 + Real(i) * 0.1
        f.chain.qd[i] = 0.3 - Real(i) * 0.05
    var d = f.dof()

    var b1 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var h = f.mass_matrix()
            keep(h[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < b1:
            b1 = dt
    t.add("assemble H by CRBA", n, "call", b1, ITERS)

    f.use_crba = False
    var b0 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var h = f.mass_matrix()
            keep(h[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < b0:
            b0 = dt
    t.add("assemble H by unit accelerations", n, "call", b0, ITERS)
    f.use_crba = True

    var b2 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var bb = f.bias(Vec3(0, -9.81, 0))
            keep(bb[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < b2:
            b2 = dt
    t.add("bias (one RNEA sweep)", n, "call", b2, ITERS)

    var b3 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var h = f.mass_matrix()
            var rhs = List[Real]()
            for j in range(d):
                rhs.append(Real(j) * 0.1)
            var x = Chain.solve_h(h^, rhs^, d)
            keep(x[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < b3:
            b3 = dt
    t.add("assemble H + dense solve", n, "call", b3, ITERS)


def _gimbal() raises:
    """Walk the pitch angle toward 90 degrees and watch the two models part."""
    print("  pitch(deg)   pseudo-joint max|qdd|      quaternion |base_wa|")
    for k in range(8):
        var pitch = Real(89.0) - Real(89.0) / Real(1 << k)
        var rad = pitch * Real(3.14159265 / 180.0)

        var c = _emulated(1)
        c.q[4] = rad  # the middle Euler angle: this is the one that locks
        c.q[6] = 0.3
        c.qd[6] = 0.2
        var t2 = List[Real]()
        for _ in range(7):
            t2.append(0)
        t2[3] = 1.0  # unit torque about the outer axis
        var a2 = c.dynamics(t2, Vec3(0, 0, 0))
        var worst = Real(0)
        for i in range(7):
            var v = Real(abs(Float64(a2[i])))
            if v > worst:
                worst = v

        var f = _floating(1)
        f.base_rot = Quat.from_axis_angle(Vec3(0, 1, 0), rad)
        f.chain.q[0] = 0.3
        f.chain.qd[0] = 0.2
        var tf = List[Real]()
        tf.append(0)
        var af = f.dynamics(tf, Vec3(0, 0, 0))
        # same unit torque, applied about the world outer axis
        var bw = Real(0)
        var h = f.mass_matrix()
        var d = f.dof()
        var rhs = List[Real]()
        for j in range(d):
            rhs.append(0)
        rhs[2] = 1.0
        var x = Chain.solve_h(h^, rhs^, d)
        for j in range(d):
            var v = Real(abs(Float64(x[j])))
            if v > bw:
                bw = v

        print("  ", pitch, "      ", worst, "      ", bw)


def main() raises:
    var t = BenchTable("Floating base: quaternion root vs six pseudo-joints")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (6 if li == 1 else 16)
        _cost(t, NL)
    t.print_report()

    var b = BenchTable("Where the floating solve spends its time")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (6 if li == 1 else 16)
        _breakdown(b, NL)
    b.print_report()

    print("")
    print("Approaching gimbal lock: unit torque, bounded physical motion")
    _gimbal()
