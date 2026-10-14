# tier: integration
"""Universal, gear and pulley joints (ROADMAP 17.47, second slice).

  1. Ordinary:
     - universal (Cardan) joint between an input shaft driven at 2 rad/s
       about x and an output shaft hinged 30 deg off it: the output speed
       swings between cos 30 = 0.866 and 1 / cos 30 = 1.155 times the input,
       twice per revolution (the analytic Cardan ratio);
     - gear, ratio 2: a wheel driven at 1 rad/s turns its partner at
       -2 rad/s; a constant 1 N m torque on the first accelerates it at
       tau / (I_a + r^2 I_b) (analytic);
     - pulley: an Atwood machine of 1 kg and 3 kg accelerates at
       (3 - 1) / (3 + 1) g = 4.9 m/s^2.
  2. Integration: a block and tackle (ratio 2) holds 2 kg against 1 kg
     still (2 m_a = m_b); a pulley's tension reads m g through
     `joint_reaction`; a snapshot taken mid-run restores all three kinds bit
     for bit.
  3. Extreme: a slack pulley does not pull (a body thrown up rises to its
     free-flight peak); a universal joint folded to parallel axes stays
     finite; a gear between two static bodies does nothing.
"""

from std.math import sqrt, cos, sin, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6, JOINT_HINGE
from physics.joint_ext import MOTOR_VELOCITY
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(QuatBody6.at_rest(Vec3(0, -10, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(0.1, 0.1, 0.1, 0), True).index()


def _cardan(beta: Real) raises -> Tuple[Real, Real]:
    """(min, max) of output / input shaft speed over the second revolution."""
    var sc = ContactScene6[QuatBody6]()
    var g = _ground(sc)
    var d = Vec3(cos(beta), sin(beta), 0, 0)
    var a = sc.add(QuatBody6.at_rest(Vec3(-0.5, 0, 0, 0), Inertia3.box(1, 0.5, 0.05, 0.05)), Vec3(0.5, 0.05, 0.05, 0), False)
    var bq = Quat.from_axis_angle(Vec3(0, 0, 1, 0), beta)
    var b = sc.add(QuatBody6(d * 0.5, bq, ZERO, ZERO, Inertia3.box(1, 0.5, 0.05, 0.05)), Vec3(0.5, 0.05, 0.05, 0), False)
    sc.set_can_sleep(a, False)
    sc.set_can_sleep(b, False)
    # ground hinges: a about x through its centre, b about d through its centre
    var ha = sc.add_joint(Joint6.hinge(g, a.index(), Vec3(-0.5, 10, 0, 0), ZERO, Vec3(1, 0, 0, 0)))
    var hb_axis_local = Vec3(1, 0, 0, 0)  # b's long axis is d
    _ = sc.add_joint(Joint6(JOINT_HINGE, g, b.index(), d * 0.5 + Vec3(0, 10, 0, 0), ZERO, 0, d, hb_axis_local, ZERO, ZERO, 1))
    # the cross: a's pin along z, b's along d x z (in b's frame: -y)
    var uj = sc.add_joint(Joint6.universal(a.index(), b.index(), Vec3(0.5, 0, 0, 0), Vec3(-0.5, 0, 0, 0), Vec3(0, 0, 1, 0), Vec3(0, -1, 0, 0)))
    for k in range(3):
        sc.set_collide_connected(k, False)
    sc.set_joint_motor(ha, MOTOR_VELOCITY, 2, 1e4)
    var lo = Real(1e9)
    var hi = Real(-1e9)
    var steps_per_rev = Int(3.14159265 / DT)  # 2 pi / 2 rad/s
    for k in range(2 * steps_per_rev):
        sc.step_soft(DT, ZERO)
        if k >= steps_per_rev:
            var wi = dot(sc.angular_velocity(a), Vec3(1, 0, 0, 0))
            var wo = dot(sc.angular_velocity(b), d)
            if abs(wi) > 0.5:
                lo = min(lo, wo / wi)
                hi = max(hi, wo / wi)
    _ = uj
    return (lo, hi)


def main() raises:
    var s = Suite("joint_kinds")

    # ---- universal ------------------------------------------------------------------------------------
    var beta = Real(0.5235988)
    var cr = _cardan(beta)
    print("  Cardan joint, 30 deg: output / input speed", cr[0], "..", cr[1], " (analytic", cos(beta), "..", 1 / cos(beta), ")")
    s.check(abs(cr[0] - cos(beta)) < 0.01 and abs(cr[1] - 1 / cos(beta)) < 0.01, "universal joint follows the Cardan speed ratio (cos b .. 1 / cos b)")
    var c0 = _cardan(0)
    s.check(abs(c0[0] - 1) < 1e-3 and abs(c0[1] - 1) < 1e-3, "universal joint with aligned shafts: constant 1:1")

    # ---- gear -----------------------------------------------------------------------------------------
    var sg = ContactScene6[QuatBody6]()
    var gg = _ground(sg)
    var wa = sg.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.1)), Vec3(0.5, 0.5, 0.1, 0), False)
    var wb = sg.add(QuatBody6.at_rest(Vec3(3, 0, 0, 0), Inertia3.box(2, 0.3, 0.3, 0.1)), Vec3(0.3, 0.3, 0.1, 0), False)
    sg.set_can_sleep(wa, False)
    sg.set_can_sleep(wb, False)
    var z = Vec3(0, 0, 1, 0)
    _ = sg.add_joint(Joint6.hinge(gg, wa.index(), Vec3(0, 10, 0, 0), ZERO, z))
    _ = sg.add_joint(Joint6.hinge(gg, wb.index(), Vec3(3, 10, 0, 0), ZERO, z))
    var gj = sg.add_joint(Joint6.gear(wa.index(), wb.index(), z, z, 2))
    for k in range(3):
        sg.set_collide_connected(k, False)
    var tau = Real(1)
    for _ in range(60):
        sg.add_torque(wa, z * tau)
        sg.step_soft(DT, ZERO)
    var w1 = sg.angular_velocity(wa)[2]
    var w2 = sg.angular_velocity(wb)[2]
    var ia = Real(1) * (0.5 * 0.5 + 0.5 * 0.5) * 4 / 12  # box 1 x 1, mass 1, about z
    var ib = Real(2) * (0.3 * 0.3 + 0.3 * 0.3) * 4 / 12
    var want = tau / (ia + 4 * ib) * 1.0
    print("  gear 2:1 under 1 N m for 1 s: w_a", w1, " w_b", w2, " ratio", w2 / w1, " w_a analytic", want)
    s.check(abs(w2 / w1 + 2) < 1e-3, "gear: b turns -2 times as fast as a")
    s.check(abs(w1 / want - 1) < 0.01, "gear: torque on a accelerates both at tau / (I_a + r^2 I_b)")

    # ---- pulley: Atwood --------------------------------------------------------------------------------
    var sp = ContactScene6[QuatBody6]()
    var gp = _ground(sp)
    var ma = sp.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var mb = sp.add(QuatBody6.at_rest(Vec3(2, 2, 0, 0), Inertia3.box(3, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    sp.set_can_sleep(ma, False)
    sp.set_can_sleep(mb, False)
    _ = sp.add_joint(Joint6.pulley(ma.index(), mb.index(), ZERO, ZERO, Vec3(0, 5, 0, 0), Vec3(2, 5, 0, 0), 6, 1))
    _ = gp
    for _ in range(30):
        sp.step_soft(DT, G)
    var vya = sp.velocity(ma)[1]
    var vyb = sp.velocity(mb)[1]
    var acc_a = vya / (30 * DT)
    print("  Atwood 1 kg / 3 kg, 0.5 s: v_a", vya, " v_b", vyb, " a", acc_a, " (analytic 4.9)")
    s.check(abs(acc_a - 4.9) < 0.05 and abs(vya + vyb) < 1e-3, "Atwood machine accelerates at (m_b - m_a) / (m_a + m_b) g")

    # ---- block and tackle, tension ----------------------------------------------------------------------
    var st = ContactScene6[QuatBody6]()
    _ = _ground(st)
    var ta = st.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var tb = st.add(QuatBody6.at_rest(Vec3(2, 3.5, 0, 0), Inertia3.box(2, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    st.set_can_sleep(ta, False)
    st.set_can_sleep(tb, False)
    var pj = st.add_joint(Joint6.pulley(ta.index(), tb.index(), ZERO, ZERO, Vec3(0, 5, 0, 0), Vec3(2, 5, 0, 0), 6, 2))
    var ya0 = st.pose(ta).pos[1]
    for _ in range(120):
        st.step_soft(DT, G)
    var drift = abs(st.pose(ta).pos[1] - ya0)
    var tension = length(st.joint_reaction(pj)[0])
    print("  block and tackle 1 kg vs 2 kg (ratio 2), 2 s: drift", drift, " tension", tension, " (m_a g = 9.8)")
    s.check(drift < 0.01 and abs(tension - 9.8) < 0.1, "ratio 2 holds 2 kg against 1 kg; tension reads m_a g")

    # ---- snapshot ----------------------------------------------------------------------------------------
    var sn = ContactScene6[QuatBody6]()
    var gn = _ground(sn)
    var n1 = sn.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.1)), Vec3(0.5, 0.5, 0.1, 0), False)
    var n2 = sn.add(QuatBody6.at_rest(Vec3(3, 0, 0, 0), Inertia3.box(2, 0.3, 0.3, 0.1)), Vec3(0.3, 0.3, 0.1, 0), False)
    var n3 = sn.add(QuatBody6.at_rest(Vec3(6, 2, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var n4 = sn.add(QuatBody6.at_rest(Vec3(8, 2, 0, 0), Inertia3.box(1.5, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    _ = sn.add_joint(Joint6.hinge(gn, n1.index(), Vec3(0, 10, 0, 0), ZERO, z))
    _ = sn.add_joint(Joint6.hinge(gn, n2.index(), Vec3(3, 10, 0, 0), ZERO, z))
    _ = sn.add_joint(Joint6.gear(n1.index(), n2.index(), z, z, -1.5))
    _ = sn.add_joint(Joint6.pulley(n3.index(), n4.index(), ZERO, ZERO, Vec3(6, 5, 0, 0), Vec3(8, 5, 0, 0), 6, 1))
    _ = sn.add_joint(Joint6.universal(n1.index(), n3.index(), Vec3(0.5, 0, 0, 0), ZERO, z, Vec3(1, 0, 0, 0)))
    for k in range(5):
        sn.set_collide_connected(k, False)
    sn.apply_angular_impulse(n1, z * 0.3)
    for _ in range(20):
        sn.step_soft(DT, G)
    var back = scene_from_bytes(scene_to_bytes(sn))
    for _ in range(40):
        sn.step_soft(DT, G)
        back.step_soft(DT, G)
    var same = True
    for b in range(len(sn.bset.bodies)):
        var p = sn.bset.bodies[b].pos
        var q = back.bset.bodies[b].pos
        if p[0] != q[0] or p[1] != q[1] or p[2] != q[2]:
            same = False
    s.check(same and back.joints[2].ratio == -1.5, "a snapshot restores gear, pulley and universal joints bit for bit")

    # ---- extremes -------------------------------------------------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _ = _ground(sl)
    var la = sl.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var lb = sl.add(QuatBody6.at_rest(Vec3(2, 2, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    _ = sl.add_joint(Joint6.pulley(la.index(), lb.index(), ZERO, ZERO, Vec3(0, 5, 0, 0), Vec3(2, 5, 0, 0), 20, 1))
    sl.set_velocity(la, Vec3(0, 4, 0, 0), ZERO)
    var peak = Real(0)
    for _ in range(60):
        sl.step_soft(DT, G)
        peak = max(peak, sl.pose(la).pos[1])
    var free_peak = Real(2) + 16 / (2 * 9.8)
    print("  slack pulley: thrown up at 4 m/s, peak", peak, " (free flight", free_peak, ")")
    s.check(abs(peak - free_peak) < 0.02, "a slack pulley does not pull")

    var sf = ContactScene6[QuatBody6]()
    var gf = _ground(sf)
    var fa = sf.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var fb = sf.add(QuatBody6.at_rest(Vec3(1, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    _ = sf.add_joint(Joint6.ball(gf, fa.index(), Vec3(0, 10, 0, 0), ZERO))
    _ = sf.add_joint(Joint6.universal(fa.index(), fb.index(), Vec3(0.5, 0, 0, 0), Vec3(-0.5, 0, 0, 0), z, z))
    for _ in range(60):
        sf.step_soft(DT, G)
    var pf = sf.pose(fb).pos
    s.check(isfinite(pf[0]) and isfinite(pf[1]) and isfinite(pf[2]), "a universal joint built with parallel axes stays finite")

    var s0 = ContactScene6[QuatBody6]()
    var x1 = s0.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var x2 = s0.add(QuatBody6.at_rest(Vec3(1, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    _ = s0.add_joint(Joint6.gear(x1.index(), x2.index(), z, z, 3))
    s0.step_soft(DT, G)
    s.check(s0.pose(x2).pos[0] == 1, "a gear between two static bodies does nothing")
    s.finish()
