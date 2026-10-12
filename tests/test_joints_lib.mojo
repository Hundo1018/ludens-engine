# tier: unit  (override: exercises the physics articulated-body code alone; numerics.dense (the shared dense solve) and collision (chain's ground contact) are its internal wiring, not a second package under test)
"""Prismatic joints and joint limits.

The prismatic checks are physical rather than numerical: a sliding mass under
gravity along its own axis is free fall, and a sliding joint perpendicular to
gravity feels nothing. Those two pin the motion subspace — S = (0, axis) for a
prismatic joint against (axis, 0) for a revolute one — because getting the
halves backwards produces motion that still looks like a joint moving, just
driven by the wrong component of the force.

The mixed-chain round trip (tau -> qdd -> tau with both joint kinds present)
is the check that the two subspaces coexist. A chain of one kind exercises only
one branch of every sweep, so it cannot catch a projection that is right for
revolute and silently wrong for prismatic.

A bead sliding on a spinning rod pins the Coriolis coupling between the two
kinds against its closed form (theta'', r'' and the kinetic energy).

Limits are checked for the failure that clamping q produces: a clamped joint
leaves its velocity pointing into the stop, so it re-violates every step. The
gate is therefore that the joint STAYS at the stop over many steps, not merely
that it is inside the range once.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 480.0
comptime INER = Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0, 0)


def main() raises:
    var s = Suite("joints_lib")

    # ---- 1. a prismatic joint along gravity is free fall ----
    var slide = Chain()
    slide.add_link(
        ChainLink.prismatic(Vec3(0, 1, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 2.0, INER)
    )
    var zero1 = List[Real]()
    zero1.append(0)
    for _ in range(480):  # 1 second
        slide.step(DT, zero1, G)
    print("  prismatic along gravity: q =", slide.q[0], " qd =", slide.qd[0])
    s.check(abs(slide.qd[0] + 9.8) < 0.1, "slides at exactly g after 1 s")
    s.check(abs(slide.q[0] + 4.9) < 0.1, "travels g*t^2/2")

    # ---- 2. a prismatic joint ACROSS gravity feels nothing ----
    var across = Chain()
    across.add_link(
        ChainLink.prismatic(Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 2.0, INER)
    )
    for _ in range(480):
        across.step(DT, zero1, G)
    print("  prismatic across gravity: q =", across.q[0])
    s.check(abs(across.q[0]) < 1e-3, "a perpendicular slider does not move")

    # ---- 3. a unit force on a free slider gives a = F/m ----
    var push = Chain()
    push.add_link(
        ChainLink.prismatic(Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 4.0, INER)
    )
    var f1 = List[Real]()
    f1.append(8.0)
    var acc = push.dynamics(f1, Vec3(0, 0, 0, 0))
    print("  a = F/m:", acc[0], " (want 2.0)")
    s.check(abs(acc[0] - 2.0) < 1e-4, "prismatic obeys a = F/m")

    # ---- 4. MIXED chain: both subspaces in one system, round trip ----
    var mix = Chain()
    var b = mix.add_link_to(
        -1, ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, -0.5, 0, 0), 1.0, INER)
    )
    var sl = mix.add_link_to(
        b, ChainLink.prismatic(Vec3(0, -1, 0, 0), Vec3(0, -1, 0, 0), Vec3(0, -0.3, 0, 0), 1.0, INER)
    )
    _ = mix.add_link_to(
        sl, ChainLink.revolute(Vec3(1, 0, 0, 0), Vec3(0, -0.6, 0, 0), Vec3(0, -0.5, 0, 0), 1.0, INER)
    )
    mix.q[0] = 0.4
    mix.q[1] = 0.25
    mix.q[2] = -0.6
    mix.qd[0] = 0.7
    mix.qd[1] = -0.3
    mix.qd[2] = 0.5
    var tau = List[Real]()
    tau.append(1.3)
    tau.append(-0.8)
    tau.append(0.45)
    var qdd = mix.dynamics(tau, G)
    var tau2 = mix.inverse_dynamics(qdd, G)
    var worst = Real(0)
    for i in range(3):
        var e = abs(tau[i] - tau2[i])
        if e > worst:
            worst = e
    print("  mixed revolute+prismatic round trip:", worst)
    s.check(worst < 1e-3, "mixed-kind chain: tau -> qdd -> tau round trips")

    # ---- 5. joint limits hold over time, not just once ----
    var lim = Chain()
    lim.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, -0.5, 0, 0), 1.0, INER
        ).limited(-0.5, 0.5)
    )
    lim.q[0] = 0.3
    var drive = List[Real]()
    drive.append(6.0)  # torque pushing hard past the upper stop
    var worst_over = Real(0)
    for _ in range(960):
        lim.step(DT, drive, Vec3(0, 0, 0, 0))
        _ = lim.resolve_limits(DT)
        var over = lim.q[0] - 0.5
        if over > worst_over:
            worst_over = over
    print("  worst overshoot past the stop:", worst_over, " final q =", lim.q[0])
    s.check(worst_over < 1e-2, "a driven joint stays at its limit")
    s.check(abs(lim.q[0] - 0.5) < 1e-2, "and rests exactly on the stop")

    # ---- 6. the limit is ONE-SIDED: leaving is free ----
    var back = Chain()
    back.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, -0.5, 0, 0), 1.0, INER
        ).limited(-0.5, 0.5)
    )
    back.q[0] = 0.5
    back.qd[0] = -2.0  # moving AWAY from the upper stop
    var qd_before = back.qd[0]
    _ = back.resolve_limits(DT)
    print("  qd leaving the stop:", qd_before, "->", back.qd[0])
    s.check(
        abs(back.qd[0] - qd_before) < 1e-6,
        "a joint moving away from its stop is untouched",
    )

    # ---- 7. a slider on a spinning rod: the Coriolis coupling ----
    # Bead (point mass m, prismatic along x) on a rod spinning about z with
    # inertia I0, no gravity. Closed form: theta'' = -2 m r r' theta' /
    # (I0 + m r^2), r'' = r theta'^2, KE = (I0 + m r^2) theta'^2 / 2 + m r'^2 / 2.
    # Before 17.17 link_motion doubled the prismatic velocity-product term
    # (theta'' came out 1.5x too large) and energy() treated the slider as
    # revolute (KE 0.42 instead of 1.41).
    var bead = Chain()
    bead.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1.0, Vec3(0.5, 0.5, 0.5, 0)))
    _ = bead.add_link_to(0, ChainLink.prismatic(Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 2.0, Vec3(1e-6, 1e-6, 1e-6, 0)))
    bead.q[1] = 0.7
    bead.qd[0] = 1.3
    bead.qd[1] = 0.4
    var z2 = List[Real]()
    z2.append(0)
    z2.append(0)
    var bq = bead.dynamics(z2, Vec3(0, 0, 0, 0))
    var itot = Real(0.5 + 2.0 * 0.49 + 1e-6)
    print("  bead on spinning rod: theta'' =", bq[0], " r'' =", bq[1])
    s.check(abs(bq[0] + 2 * 2.0 * 0.7 * 0.4 * 1.3 / itot) < 1e-5, "Coriolis: theta'' matches the closed form")
    s.check(abs(bq[1] - 0.7 * 1.69) < 1e-5, "centrifugal: r'' = r theta'^2")
    var ke = 0.5 * itot * 1.69 + Real(0.5 * 2.0 * 0.16)
    s.check(abs(bead.energy(Vec3(0, 0, 0, 0)) - ke) < 1e-5, "energy() counts the slider's velocity")

    s.finish()
