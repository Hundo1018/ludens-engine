# tier: integration
"""Six-axis (D6) joint (ROADMAP 17.47).

Each axis of body a's frame -- translation along x / y / z, rotation about
them -- is free, locked or limited.

  1. Ordinary (D6 configured as an existing joint, same scene):
     - all six locked: a 1 m bar held off a pivot stays where a weld holds
       it (tip positions within 1 mm over 2 s);
     - only rotation about z free: swings like a hinge pendulum (angles
       within 0.01 rad over 2 s);
     - only translation along x free, gravity tilted 30 deg: slides at
       g sin 30 = 4.9 m/s^2 like a slider.
  2. Integration: a 0.2 m travel limit on x holds a body pushed with 20 N
     at 0.2; a 0.5 rad limit on rotation z holds a bar driven by 6 N m at
     0.5; a snapshot restores a limited D6 mid-run bit for bit.
  3. Extreme: set_d6_axis on a hinge, axis 6, lo > hi raise; all axes free
     leaves the bodies independent (free fall at g).
"""

from std.math import sin, cos, atan2
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.joint_ext import D6_FREE, D6_LOCKED, D6_LIMITED
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime Z = Vec3(0, 0, 1, 0)


def _bar_scene(q0: Real) raises -> ContactScene6[QuatBody6]:
    """Static pivot (body 0) and a 1 kg, 1 m bar (body 1) hanging from it,
    turned q0 about z."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), True)
    var r = Quat.from_axis_angle(Z, q0)
    var bar = sc.add(QuatBody6(r.rotate(Vec3(0, -0.5, 0, 0)), r, ZERO, ZERO, Inertia3.box(1, 0.05, 0.5, 0.05)), Vec3(0.05, 0.5, 0.05, 0), False)
    sc.set_can_sleep(bar, False)
    return sc^


def _tip(sc: ContactScene6[QuatBody6]) -> Vec3:
    return sc.bset.bodies[1].act(Vec3(0, -0.5, 0, 0))


def _angle(sc: ContactScene6[QuatBody6]) -> Real:
    var t = _tip(sc)
    return atan2(t[0], -t[1])


def main() raises:
    var s = Suite("joint_d6")

    # ---- all locked == weld ---------------------------------------------------------------------------
    var sw = _bar_scene(0.6)
    var sd = _bar_scene(0.6)
    _ = sw.add_joint(Joint6.weld(0, 1, ZERO, sw.bset.bodies[1].to_local(ZERO), sw.bset.bodies[0].rotation().conjugate() * sw.bset.bodies[1].rotation()))
    _ = sd.add_joint(Joint6.d6(0, 1, ZERO, sd.bset.bodies[1].to_local(ZERO)))
    var worst = Real(0)
    for _ in range(120):
        sw.step_soft(DT, G)
        sd.step_soft(DT, G)
        worst = max(worst, length(_tip(sw) - _tip(sd)))
    print("  all six locked vs weld, bar held at 0.6 rad, 2 s: max tip distance", worst, " tip sag", length(_tip(sd) - Vec3(sin(Real(0.6)), -cos(Real(0.6)), 0, 0)))
    s.check(worst < 1e-3, "D6 all locked holds like a weld (tips within 1 mm)")

    # ---- rotation z free == hinge ------------------------------------------------------------------------
    var sh = _bar_scene(0.3)
    var s6 = _bar_scene(0.3)
    var hj = sh.add_joint(Joint6.hinge(0, 1, ZERO, sh.bset.bodies[1].to_local(ZERO), Z))
    sh.set_collide_connected(hj, False)
    var dj = s6.add_joint(Joint6.d6(0, 1, ZERO, s6.bset.bodies[1].to_local(ZERO)))
    s6.set_d6_axis(dj, 5, D6_FREE)
    var dq = Real(0)
    var amp = Real(0)
    for _ in range(120):
        sh.step_soft(DT, G)
        s6.step_soft(DT, G)
        dq = max(dq, abs(_angle(sh) - _angle(s6)))
        amp = max(amp, abs(_angle(s6)))
    print("  rotation z free vs hinge, 0.3 rad swing, 2 s: max angle difference", dq, " amplitude", amp)
    s.check(dq < 0.01 and amp > 0.29, "D6 with rotation z free swings like a hinge")

    # ---- translation x free == slider ----------------------------------------------------------------------
    var g30 = Vec3(9.8 * sin(Real(0.5235988)), -9.8 * cos(Real(0.5235988)), 0, 0)
    var ss = ContactScene6[QuatBody6]()
    _ = ss.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var bob = ss.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    ss.set_can_sleep(bob, False)
    var sj = ss.add_joint(Joint6.d6(0, 1, ZERO, ZERO))
    ss.set_d6_axis(sj, 0, D6_FREE)
    for _ in range(60):
        ss.step_soft(DT, g30)
    var vx = ss.velocity(bob)[0]
    var p = ss.pose(bob).pos
    print("  translation x free, gravity 30 deg off: v_x after 1 s", vx, " (analytic 4.9)  y", p[1], " z", p[2])
    s.check(abs(vx - 4.9) < 0.02 and abs(p[1]) < 1e-3 and abs(p[2]) < 1e-3, "D6 with translation x free slides at g sin 30, held on the axis")

    # ---- linear limit ------------------------------------------------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _ = sl.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var lb = sl.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    sl.set_can_sleep(lb, False)
    var lj = sl.add_joint(Joint6.d6(0, 1, ZERO, ZERO))
    sl.set_d6_axis(lj, 0, D6_LIMITED, -0.2, 0.2)
    var over = Real(0)
    for _ in range(180):
        sl.add_force(lb, Vec3(20, 0, 0, 0))
        sl.step_soft(DT, ZERO)
        over = max(over, sl.pose(lb).pos[0] - 0.2)
    print("  x limited to [-0.2, 0.2], pushed with 20 N, 3 s: x", sl.pose(lb).pos[0], " overshoot", over)
    s.check(abs(sl.pose(lb).pos[0] - 0.2) < 2e-3 and over < 0.01, "linear limit holds at 0.2")

    # ---- angular limit -----------------------------------------------------------------------------------------
    var sa = _bar_scene(0)
    var aj = sa.add_joint(Joint6.d6(0, 1, ZERO, sa.bset.bodies[1].to_local(ZERO)))
    sa.set_d6_axis(aj, 5, D6_LIMITED, -0.5, 0.5)
    for _ in range(300):
        sa.add_torque(sa.bset.id_of(1), Z * 6)
        sa.step_soft(DT, G)
    print("  rotation z limited to 0.5 rad, 6 N m, 5 s: angle", _angle(sa))
    s.check(abs(_angle(sa) - 0.5) < 0.01, "angular limit holds at 0.5 rad")

    # ---- snapshot ------------------------------------------------------------------------------------------------
    var sn = _bar_scene(0.2)
    var nj = sn.add_joint(Joint6.d6(0, 1, ZERO, sn.bset.bodies[1].to_local(ZERO)))
    sn.set_d6_axis(nj, 5, D6_LIMITED, -0.3, 0.3)
    sn.set_d6_axis(nj, 1, D6_LIMITED, -0.05, 0.05)
    sn.set_d6_axis(nj, 3, D6_FREE)
    for _ in range(20):
        sn.step_soft(DT, G)
    var back = scene_from_bytes(scene_to_bytes(sn))
    for _ in range(40):
        sn.step_soft(DT, G)
        back.step_soft(DT, G)
    var a = sn.bset.bodies[1].pos
    var b = back.bset.bodies[1].pos
    s.check(a[0] == b[0] and a[1] == b[1] and a[2] == b[2], "a limited D6 restored mid-run steps bit for bit")

    # ---- extremes -----------------------------------------------------------------------------------------------------
    var raised = 0
    try:
        sh.set_d6_axis(hj, 0, D6_FREE)
    except:
        raised += 1
    try:
        s6.set_d6_axis(dj, 6, D6_FREE)
    except:
        raised += 1
    try:
        s6.set_d6_axis(dj, 0, D6_LIMITED, 1, -1)
    except:
        raised += 1
    s.check(raised == 3, "a hinge, axis 6 and lo > hi raise")
    var sf = _bar_scene(0)
    var fj = sf.add_joint(Joint6.d6(0, 1, ZERO, sf.bset.bodies[1].to_local(ZERO)))
    for k in range(6):
        sf.set_d6_axis(fj, k, D6_FREE)
    for _ in range(30):
        sf.step_soft(DT, G)
    print("  all axes free: v_y after 0.5 s", sf.velocity(sf.bset.id_of(1))[1], " (free fall -4.9)")
    s.check(abs(sf.velocity(sf.bset.id_of(1))[1] + 4.9) < 1e-3, "all axes free: the bar falls freely")
    s.finish()
