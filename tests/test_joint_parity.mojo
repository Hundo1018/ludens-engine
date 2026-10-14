# tier: integration
"""Maximal- vs reduced-coordinate hinge parity (ROADMAP 17.47 / 17.51).

The same 1 kg, 1 m bar hung from a pivot, as a `ContactScene6` hinge
(maximal coordinates, soft constraints) and as a `Chain` revolute link
(reduced coordinates, exact):

  1. free swing from 0.3 rad: both follow the physical pendulum; their
     angles stay within 0.015 rad of each other over 4 s (measured 0.0099:
     the soft hinge's anchor gives a little) and both periods
     match 2 pi sqrt(I_pivot / (m g d));
  2. a constant 2 N m torque with damping: both settle at
     asin(tau / (m g d)) = 0.4204 rad (the maximal side read 0.4091 while
     `_props_pre` damped the torque impulse along with the velocity);
  3. a 6 N m torque against a 0.5 rad limit (`set_joint_limits` vs
     `ChainLink.limited` + `resolve_limits`): both rest on the stop, final
     angles within 0.01 rad, overshoot under 0.02 rad.
"""

from std.math import sqrt, asin, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.chain import Chain, ChainLink

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime Z = Vec3(0, 0, 1, 0)


def _maximal(q0: Real, lim: Bool) raises -> ContactScene6[QuatBody6]:
    """The bar scene; its hinge is joint 0."""
    var sc = ContactScene6[QuatBody6]()
    var p = sc.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), True)
    var bar = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 0.05, 0.5, 0.05)), Vec3(0.05, 0.5, 0.05, 0), False)
    sc.set_can_sleep(bar, False)
    var j = sc.add_joint(Joint6.hinge(p.index(), bar.index(), ZERO, Vec3(0, 0.5, 0, 0), Z))
    sc.set_collide_connected(j, False)
    if lim:
        sc.set_joint_limits(j, -0.5, 0.5)
    if q0 != 0:
        # rotate the bar about the pivot by q0 (joint coordinate measured from the build pose)
        var r = Quat.from_axis_angle(Z, q0)
        sc.teleport(bar, Pose6(r.rotate(Vec3(0, -0.5, 0, 0)), r))
    return sc^


def _reduced(lim: Bool) -> Chain:
    var c = Chain()
    var ib = Inertia3.box(1, 0.05, 0.5, 0.05)
    var link = ChainLink.revolute(Z, ZERO, Vec3(0, -0.5, 0, 0), 1.0, Vec3(ib.ix, ib.iy, ib.iz, 0))
    if lim:
        link = link.limited(-0.5, 0.5)
    c.add_link(link)
    return c^


def main() raises:
    var s = Suite("joint_parity")
    var ib = Inertia3.box(1, 0.05, 0.5, 0.05)
    var i_pivot = ib.iz + 1 * 0.25
    var period = 2 * pi * sqrt(i_pivot / (1 * 9.8 * 0.5))

    # ---- 1. free swing -----------------------------------------------------------------------------
    var sc = _maximal(0.3, False)
    var j = 0
    var ch = _reduced(False)
    ch.q[0] = 0.3
    var zero_tau = List[Real]()
    zero_tau.append(0)
    var worst = Real(0)
    var cross_m = List[Real]()
    var cross_r = List[Real]()
    var prev_m = sc.joint_coordinate(j)
    var prev_r = ch.q[0]
    for k in range(240):
        sc.step_soft(DT, G)
        ch.step_aba(DT, zero_tau, G)
        var qm = sc.joint_coordinate(j)
        var qr = ch.q[0]
        worst = max(worst, abs(qm - qr))
        if prev_m > 0 and qm <= 0:
            cross_m.append(Real(k + 1) * DT)
        if prev_r > 0 and qr <= 0:
            cross_r.append(Real(k + 1) * DT)
        prev_m = qm
        prev_r = qr
    var pm = (cross_m[len(cross_m) - 1] - cross_m[0]) / Real(len(cross_m) - 1) if len(cross_m) > 1 else Real(0)
    var pr = (cross_r[len(cross_r) - 1] - cross_r[0]) / Real(len(cross_r) - 1) if len(cross_r) > 1 else Real(0)
    print("  free swing 0.3 rad, 4 s: max |q_max - q_red|", worst, " periods", pm, pr, " (analytic", period, ")")
    s.check(worst < 0.015, "free swing: maximal and reduced angles within 0.015 rad over 4 s")
    s.check(abs(pm / period - 1) < 0.02 and abs(pr / period - 1) < 0.02, "both periods match the physical pendulum within 2 %")

    # ---- 2. torque equilibrium -----------------------------------------------------------------------
    var tau = Real(2)
    var want = asin(tau / (1 * 9.8 * 0.5))
    var se = _maximal(0, False)
    var je = 0
    se.set_damping(se.bset.id_of(1), 0, 2)
    var ce = _reduced(False)
    ce.damping[0] = 0.5
    var t_list = List[Real]()
    t_list.append(tau)
    for _ in range(1200):
        se.add_torque(se.bset.id_of(1), Z * tau)
        se.step_soft(DT, G)
        ce.step_implicit(DT, t_list, G)
    var qe_m = se.joint_coordinate(je)
    var qe_r = ce.q[0]
    print("  2 N m with damping, 20 s: maximal", qe_m, " reduced", qe_r, " (analytic", want, ")")
    s.check(abs(qe_m - want) < 0.01 and abs(qe_r - want) < 0.01, "both settle at asin(tau / m g d)")

    # ---- 3. limit stop ---------------------------------------------------------------------------------
    var sl = _maximal(0, True)
    var jl = 0
    var cl = _reduced(True)
    var t6 = List[Real]()
    t6.append(6)
    var over_m = Real(0)
    var over_r = Real(0)
    for _ in range(300):
        sl.add_torque(sl.bset.id_of(1), Z * 6)
        sl.step_soft(DT, G)
        cl.step_aba(DT, t6, G)
        _ = cl.resolve_limits(DT)
        over_m = max(over_m, sl.joint_coordinate(jl) - 0.5)
        over_r = max(over_r, cl.q[0] - 0.5)
    var fm = sl.joint_coordinate(jl)
    var fr = cl.q[0]
    print("  6 N m against a 0.5 rad stop, 5 s: final maximal", fm, " reduced", fr, " overshoot", over_m, over_r)
    s.check(abs(fm - fr) < 0.01 and abs(fm - 0.5) < 0.01, "both rest on the stop (within 0.01 rad of each other)")
    s.check(over_m < 0.02 and over_r < 0.02, "overshoot under 0.02 rad in both")
    s.finish()
