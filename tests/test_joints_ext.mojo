# tier: integration
"""Joint limits, motors, springs and the slider / cone-twist / rope kinds
(ROADMAP 17.47).

  1. Ordinary:
     - a 1 m bar on a hinge swings down under gravity and stops at its
       -0.5 rad limit;
     - a velocity motor spins a free wheel to 3 rad/s; with a small torque
       cap the wheel instead accelerates at cap / I (analytic);
     - a slider with a spring (2 Hz, no damping) released 0.5 m from rest
       oscillates with period 0.5 s;
     - a vertical slider with travel [-1, 0] lets a body fall exactly 1 m
       and holds its sideways position and rotation.
  2. Integration:
     - cone-twist: a bar hung 60 deg off the twist axis is pulled inside a
       30 deg cone; spun about its own axis it stays inside the twist range;
     - rope: a ball hung on a 2 m rope with slack falls until taut (2 m),
       and thrown back up at 4 m/s it reaches the free-flight peak (the slack
       rope does not push);
     - collide_connected = False stops two overlapping jointed boxes from
       pushing apart (with True they separate);
     - snapshot (format 4) carries the exts: a motorised, limited hinge
       restored mid-run steps bit-identically.
  3. Extreme: limits lo > hi and a cone on a hinge raise; a motor with zero
     torque applies nothing.
"""

from std.math import sqrt, pi, atan2
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.joint_ext import MOTOR_VELOCITY, MOTOR_NONE
from physics.serialize import scene_to_string, scene_from_string

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 0.1, 0.1, 0.1))


def _pivot(mut sc: ContactScene6[QuatBody6], p: Vec3) -> Int:
    var id = sc.add(_st(p), Vec3(0.05, 0.05, 0.05, 0), True)
    return id.index()


def main() raises:
    var s = Suite("joints_ext")

    # ---- hinge limit ---------------------------------------------------
    var sh = ContactScene6[QuatBody6]()
    var p0 = _pivot(sh, ZERO)
    var bar = sh.add(QuatBody6.at_rest(Vec3(0.5, 0, 0, 0), Inertia3.box(1, 0.5, 0.05, 0.05)), Vec3(0.5, 0.05, 0.05, 0), False)
    sh.set_can_sleep(bar, False)
    var hj = sh.add_joint(Joint6.hinge(p0, bar.index(), ZERO, Vec3(-0.5, 0, 0, 0), Vec3(0, 0, 1, 0)))
    sh.set_collide_connected(hj, False)
    sh.set_joint_limits(hj, -0.5, 0.5)
    var lowest = Real(0)
    for _ in range(180):
        sh.step_soft(DT, G)
        lowest = min(lowest, sh.joint_coordinate(hj))
    var q = sh.joint_coordinate(hj)
    print("  hinge bar with limit -0.5: rest angle", q, " lowest", lowest)
    s.check(abs(q + 0.5) < 0.02, "hinge: the bar rests at its -0.5 rad limit")
    s.check(lowest > -0.55, "hinge: overshoot past the limit under 0.05 rad")

    # ---- velocity motor ------------------------------------------------
    var sm = ContactScene6[QuatBody6]()
    var p1 = _pivot(sm, ZERO)
    var wheel = sm.add(QuatBody6.at_rest(ZERO, Inertia3.box(2, 0.5, 0.5, 0.1)), Vec3(0.5, 0.5, 0.1, 0), False)
    sm.set_can_sleep(wheel, False)
    var mj = sm.add_joint(Joint6.hinge(p1, wheel.index(), ZERO, ZERO, Vec3(0, 0, 1, 0)))
    sm.set_collide_connected(mj, False)
    sm.set_joint_motor(mj, MOTOR_VELOCITY, 3, 100)
    for _ in range(60):
        sm.step_soft(DT, ZERO)
    var w = sm.angular_velocity(wheel)[2]
    print("  velocity motor target 3 rad/s: omega", w)
    s.check(abs(w - 3) < 0.03, "velocity motor reaches 3 rad/s")
    var sc2 = ContactScene6[QuatBody6]()
    var p2 = _pivot(sc2, ZERO)
    var wheel2 = sc2.add(QuatBody6.at_rest(ZERO, Inertia3.box(2, 0.5, 0.5, 0.1)), Vec3(0.5, 0.5, 0.1, 0), False)
    sc2.set_can_sleep(wheel2, False)
    var mj2 = sc2.add_joint(Joint6.hinge(p2, wheel2.index(), ZERO, ZERO, Vec3(0, 0, 1, 0)))
    sc2.set_collide_connected(mj2, False)
    sc2.set_joint_motor(mj2, MOTOR_VELOCITY, 30, 0.1)
    for _ in range(60):
        sc2.step_soft(DT, ZERO)
    var iz = Real(2.0 / 3.0) * (0.25 + 0.25)  # box: m/3 (hx^2 + hy^2)
    var want = Real(0.1) / iz * 1.0
    var w2 = sc2.angular_velocity(wheel2)[2]
    print("  torque-capped motor: omega after 1 s", w2, " cap / I x t", want)
    s.check(abs(w2 - want) < 0.02 * want, "torque cap 0.1 N m: omega = cap / I x t")

    # ---- slider + spring -----------------------------------------------
    var ss = ContactScene6[QuatBody6]()
    var p3 = _pivot(ss, ZERO)
    var bob = ss.add(QuatBody6.at_rest(Vec3(0.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    ss.set_can_sleep(bob, False)
    var sj = ss.add_joint(Joint6.slider(p3, bob.index(), ZERO, ZERO, Vec3(1, 0, 0, 0)))
    ss.set_collide_connected(sj, False)
    ss.set_joint_spring(sj, 2, 0, 0)
    var prev = ss.joint_coordinate(sj)
    var crossings = List[Real]()
    for k in range(240):
        ss.step_soft(DT, ZERO)
        var cur = ss.joint_coordinate(sj)
        if prev > 0 and cur <= 0:
            crossings.append(Real(k + 1) * DT - DT * cur / (cur - prev))
        prev = cur
    var period = (crossings[len(crossings) - 1] - crossings[0]) / Real(len(crossings) - 1) if len(crossings) > 1 else Real(0)
    var drift = length(ss.pose(bob).pos - Vec3(ss.pose(bob).pos[0], 0, 0, 0))
    print("  slider spring 2 Hz: period", period, " (want 0.5) down-crossings", len(crossings), " sideways drift", drift)
    s.check(abs(period - 0.5) < 0.025, "spring 2 Hz on a slider: period 0.5 s (5 %)")
    s.check(drift < 1e-4, "slider holds the sideways position")

    var sv = ContactScene6[QuatBody6]()
    var p4 = _pivot(sv, ZERO)
    var drop = sv.add(QuatBody6.at_rest(Vec3(0.3, 0, -0.2, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    sv.set_can_sleep(drop, False)
    # the axis line runs through a's anchor (0.3, 0, -0.2): the body's own line
    var vj = sv.add_joint(Joint6.slider(p4, drop.index(), Vec3(0.3, 0, -0.2, 0), ZERO, Vec3(0, 1, 0, 0)))
    sv.set_collide_connected(vj, False)
    sv.set_joint_limits(vj, -1, 0)
    for _ in range(120):
        sv.step_soft(DT, G)
    var pd = sv.pose(drop)
    print("  vertical slider travel [-1, 0]: y", pd.pos[1], " x", pd.pos[0], " z", pd.pos[2], " rot w", pd.rot.w)
    s.check(abs(pd.pos[1] + 1) < 0.01, "slider: falls exactly to its -1 m end stop")
    s.check(abs(pd.pos[0] - 0.3) < 1e-3 and abs(pd.pos[2] + 0.2) < 1e-3 and abs(pd.rot.w) > 0.9999, "slider: no sideways drift or rotation")

    # ---- cone-twist ----------------------------------------------------
    var ct = ContactScene6[QuatBody6]()
    var p5 = _pivot(ct, ZERO)
    var tilt = Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 3)
    var arm = QuatBody6.at_rest(tilt.rotate(Vec3(0, -0.5, 0, 0)), Inertia3.box(1, 0.05, 0.5, 0.05))
    arm.q = tilt
    var aid = ct.add(arm^, Vec3(0.05, 0.5, 0.05, 0), False)
    ct.set_can_sleep(aid, False)
    var cj = ct.add_joint(Joint6.cone_twist(p5, aid.index(), ZERO, Vec3(0, 0.5, 0, 0), Vec3(0, -1, 0, 0), Vec3(0, -1, 0, 0)))
    ct.set_collide_connected(cj, False)
    ct.set_cone_limit(cj, pi / 6)
    ct.set_joint_limits(cj, -0.2, 0.2)
    var worst_swing = Real(0)
    var worst_twist = Real(0)
    for k in range(120):
        if k == 30:
            # ~6 rad/s about the bar's long axis (I = 0.0017 kg m^2)
            ct.apply_angular_impulse(aid, ct.pose(aid).rot.rotate(Vec3(0, 0.01, 0, 0)))
        ct.step_soft(DT, G)
        if k >= 20:
            var axb = ct.pose(aid).rot.rotate(Vec3(0, -1, 0, 0))
            worst_swing = max(worst_swing, atan2(length(Vec3(axb[0], 0, axb[2], 0)), -axb[1]))
            worst_twist = max(worst_twist, abs(ct.joint_coordinate(cj)))
    print("  cone-twist 30 deg cone, started at 60: worst swing after 1/3 s", worst_swing * 180 / pi, "deg  worst twist", worst_twist)
    s.check(worst_swing < pi / 6 + 0.035, "cone-twist: pulled inside the 30 deg cone (2 deg)")
    s.check(worst_twist < 0.25, "cone-twist: spun about its axis it stays inside the +-0.2 rad twist range")

    # ---- rope ----------------------------------------------------------
    var sr = ContactScene6[QuatBody6]()
    var p6 = _pivot(sr, Vec3(0, 5, 0, 0))
    var ball = sr.add_sphere(QuatBody6.at_rest(Vec3(0, 4, 0, 0), Inertia3.sphere(1, 0.2)), 0.2, False)
    sr.set_can_sleep(ball, False)
    _ = sr.add_joint(Joint6.rope(p6, ball.index(), ZERO, ZERO, 2))
    for _ in range(120):
        sr.step_soft(DT, G)
    var yb = sr.pose(ball).pos[1]
    print("  rope 2 m: ball rests at y", yb)
    s.check(abs(yb - 3) < 0.01, "rope: taut at 2 m (y = 3)")
    sr.add_force(ball, Vec3(0, 4, 0, 0), 2)  # velocity change: 4 m/s up (stays below the pivot)
    var peak = yb
    for _ in range(60):
        sr.step_soft(DT, G)
        peak = max(peak, sr.pose(ball).pos[1])
    var free_peak = Real(3) + Real(16) / Real(2 * 9.8)
    print("  thrown up at 4 m/s: peak", peak, " free flight", free_peak)
    s.check(abs(peak - free_peak) < 0.05, "rope: slack rope does not push (free-flight peak)")

    # ---- collide_connected ----------------------------------------------
    for on in range(2):
        var sco = ContactScene6[QuatBody6]()
        var base = sco.add(_st(ZERO), Vec3(0.5, 0.5, 0.5, 0), True)
        var top = sco.add(QuatBody6.at_rest(Vec3(0, 0.8, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
        sco.set_can_sleep(top, False)
        var bj = sco.add_joint(Joint6.ball(base.index(), top.index(), Vec3(0, 0.4, 0, 0), Vec3(0, -0.4, 0, 0)))
        sco.set_collide_connected(bj, on == 1)
        for _ in range(30):
            sco.step_soft(DT, ZERO)
        var moved = length(sco.pose(top).pos - Vec3(0, 0.8, 0, 0))
        print("  jointed overlapping boxes, collide", on == 1, ": top moved", moved)
        if on == 0:
            s.check(moved < 1e-3, "collide_connected False: overlapping jointed boxes stay put")
        else:
            s.check(moved > 0.01, "collide_connected True: they push against the joint")

    # ---- snapshot round trip ---------------------------------------------
    var sn = ContactScene6[QuatBody6]()
    var p7 = _pivot(sn, ZERO)
    var bar2 = sn.add(QuatBody6.at_rest(Vec3(0.5, 0, 0, 0), Inertia3.box(1, 0.5, 0.05, 0.05)), Vec3(0.5, 0.05, 0.05, 0), False)
    sn.set_can_sleep(bar2, False)
    var nj = sn.add_joint(Joint6.hinge(p7, bar2.index(), ZERO, Vec3(-0.5, 0, 0, 0), Vec3(0, 0, 1, 0)))
    sn.set_collide_connected(nj, False)
    sn.set_joint_limits(nj, -0.4, 0.4)
    sn.set_joint_motor(nj, MOTOR_VELOCITY, 2, 3)
    for _ in range(40):
        sn.step_soft(DT, G)
    var blob = scene_to_string(sn)
    var rn = scene_from_string(blob)
    s.check(scene_to_string(rn) == blob, "snapshot: re-serialised blob identical")
    for _ in range(60):
        sn.step_soft(DT, G)
        rn.step_soft(DT, G)
    var same = True
    for a in range(3):
        if sn.bset.bodies[1].pos[a] != rn.bset.bodies[1].pos[a] or sn.bset.bodies[1].omega[a] != rn.bset.bodies[1].omega[a]:
            same = False
    s.check(same, "snapshot: a motorised, limited hinge restored mid-run steps bit-identically")

    # ---- extremes ------------------------------------------------------
    var raised = 0
    try:
        sn.set_joint_limits(nj, 1, -1)
    except:
        raised += 1
    try:
        sn.set_cone_limit(nj, 0.5)
    except:
        raised += 1
    try:
        sn.set_joint_limits(99, 0, 1)
    except:
        raised += 1
    s.eqi(raised, 3, "lo > hi, a cone on a hinge, a bad joint index: all raise")
    var sz = ContactScene6[QuatBody6]()
    var p8 = _pivot(sz, ZERO)
    var w3 = sz.add(QuatBody6.at_rest(ZERO, Inertia3.box(2, 0.5, 0.5, 0.1)), Vec3(0.5, 0.5, 0.1, 0), False)
    sz.set_can_sleep(w3, False)
    var zj = sz.add_joint(Joint6.hinge(p8, w3.index(), ZERO, ZERO, Vec3(0, 0, 1, 0)))
    sz.set_collide_connected(zj, False)
    sz.set_joint_motor(zj, MOTOR_VELOCITY, 5, 0)
    for _ in range(30):
        sz.step_soft(DT, ZERO)
    s.check(sz.angular_velocity(w3)[2] == 0, "motor with zero torque applies nothing")
    s.finish()
