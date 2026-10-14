# tier: integration
"""Ball (spherical) joints in reduced coordinates (ROADMAP 17.51).

`Chain.add_ball` is three revolute DOFs about the body's own axes whose
angles are folded into a quaternion after every step, so they stay near 0
and the Euler-angle singularity is never reached.

  1. Ordinary: a 1 kg, 1 m rod on a ball joint swings with the physical
     pendulum period 2 pi sqrt(I_p / (m g d)); without gravity, tumbling
     about all three axes, its kinetic energy and angular momentum about
     the pivot drift under 5 % in 2 s and the drift halves with dt (the
     first-order step's error, measured 4.6 % / 2.3 %; no fold error).
  2. Integration (the seam): the same rod as three plain revolute joints
     (no folding), spun at (0.3, 2, 0.3) rad/s so the middle angle passes
     pi / 2 where the x and z axes align (a body of principal inertia
     0.1 / 0.15 / 0.2): the outer rates blow up (13.6 rad/s) and the energy
     error is 10x the ball joint's, which passes the same motion at rates
     <= 0.5 rad/s. Against a
     maximal-coordinate `Joint6.ball` in `ContactScene6`, the tip
     trajectories agree within 1 cm over 2 s; a snapshot restored mid-run
     steps bit for bit.
  3. Extreme: spinning at 10 rad/s for 5 s (many full turns) the
     quaternion stays unit; mass 0 and a stiffness on a ball DOF raise;
     `ArticBatch` refuses a chain with a ball.
"""

from std.math import sqrt, pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, cross
from geometry.quat import Quat
from physics.chain import Chain, ChainLink, write_chain, read_chain
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.artic_batch import ArticBatch
from physics.serialize import BinWriter, BinReader

comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime ROD_I = Vec3(1.0 / 12.0, 1e-3, 1.0 / 12.0, 0)


def _ball_rod(idiag: Vec3 = ROD_I) raises -> Chain:
    var c = Chain()
    _ = c.add_ball(-1, ZERO, Vec3(0, -0.5, 0, 0), 1, idiag)
    return c^


def _plain_rod(idiag: Vec3 = ROD_I) raises -> Chain:
    """The same three revolutes, never folded."""
    var c = Chain()
    var hx = c.add_link_to(-1, ChainLink.revolute(Vec3(1, 0, 0, 0), ZERO, ZERO, 0, ZERO))
    var hy = c.add_link_to(hx, ChainLink.revolute(Vec3(0, 1, 0, 0), ZERO, ZERO, 0, ZERO))
    _ = c.add_link_to(hy, ChainLink.revolute(Vec3(0, 0, 1, 0), ZERO, Vec3(0, -0.5, 0, 0), 1, idiag))
    return c^


def _l_pivot(c: Chain) raises -> Vec3:
    """Angular momentum about the pivot, world frame, from the body's
    world angular velocity and its centre's velocity."""
    var r = c.ball_orientation(2)
    var w_body = Vec3(c.qd[0], c.qd[1], c.qd[2], 0)
    var w = r.rotate(w_body)
    var com = r.rotate(Vec3(0, -0.5, 0, 0))
    var v = cross(w, com)
    var ib = r.rotate(Vec3(ROD_I[0] * w_body[0], ROD_I[1] * w_body[1], ROD_I[2] * w_body[2], 0))
    return ib + cross(com, v)


def _tumble(dt: Real) raises -> Tuple[Real, Real]:
    """Max relative energy and angular momentum drift over 2 s of free
    tumbling (no gravity) from body rates (1, 2, 0.5)."""
    var c = _ball_rod()
    c.qd[0] = 1
    c.qd[1] = 2
    c.qd[2] = 0.5
    var z = List[Real](length=3, fill=0)
    var e0 = c.energy(ZERO)
    var l0 = _l_pivot(c)
    var e_dev = Real(0)
    var l_dev = Real(0)
    for _ in range(Int(Real(2) / dt + 0.5)):
        c.step(dt, z, ZERO)
        e_dev = max(e_dev, abs(c.energy(ZERO) / e0 - 1))
        l_dev = max(l_dev, length(_l_pivot(c) - l0) / length(l0))
    return (e_dev, l_dev)


def _through_singular(ball: Bool) raises -> Tuple[Real, Real]:
    """(max energy drift, max x / z joint rate) over 2 s without gravity
    from rates (0.3, 2, 0.3): the middle angle passes pi / 2 for the plain
    revolutes."""
    var box_i = Vec3(0.1, 0.15, 0.2, 0)  # the rod's 1e-3 axis adds its own stiff drift
    var c = _ball_rod(box_i) if ball else _plain_rod(box_i)
    c.qd[0] = 0.3
    c.qd[1] = 2
    c.qd[2] = 0.3
    var z = List[Real](length=3, fill=0)
    var e0 = c.energy(ZERO)
    var dev = Real(0)
    var rate = Real(0)
    for _ in range(480):
        c.step(DT, z, ZERO)
        var e = c.energy(ZERO)
        if not isfinite(e):
            return (Real(1e30), Real(1e30))
        dev = max(dev, abs(e / e0 - 1))
        rate = max(rate, max(abs(c.qd[0]), abs(c.qd[2])))
    return (dev, rate)


def main() raises:
    var s = Suite("ball_joint")
    var zero3 = List[Real](length=3, fill=0)

    # ---- pendulum period ---------------------------------------------------------------------------------
    var pc = _ball_rod()
    pc.qd[2] = 0.3  # small swing in the x-y plane (body z)
    var crossings = List[Real]()
    var prev = Real(0)
    for k in range(1200):
        pc.step(DT, zero3, G)
        var x = pc.point_world(2, Vec3(0, -1, 0, 0))[0]
        if k > 0 and prev < 0 and x >= 0:
            crossings.append(Real(k + 1) * DT)
        prev = x
    var period = (crossings[len(crossings) - 1] - crossings[0]) / Real(len(crossings) - 1)
    var want = Real(2 * pi) * sqrt(Real((1.0 / 12.0 + 0.25) / (9.8 * 0.5)))
    print("  ball-jointed rod, small swing: period", period, " (analytic", want, ")")
    s.check(abs(period / want - 1) < 0.01, "pendulum period within 1 %")

    # ---- tumbling without gravity: energy and angular momentum --------------------------------------------------
    var td = _tumble(DT)
    var th = _tumble(DT / 2)
    print("  tumbling, no gravity, 2 s: energy drift", td[0], "(dt) ", th[0], "(dt / 2);  |dL| / |L|", td[1], th[1])
    s.check(td[0] < 0.05 and td[1] < 0.05 and abs(td[0] / th[0] - 2) < 0.2 and abs(td[1] / th[1] - 2) < 0.3, "energy and angular momentum drift under 5 % and halve with dt (first-order step, no fold error)")

    # ---- seam: plain revolutes vs ball through the singular pose -------------------------------------------------
    var pr = _through_singular(False)
    var pb = _through_singular(True)
    print("  spin (0.3, 2, 0.3) rad/s for 2 s: plain revolutes energy drift", pr[0], " max x / z rate", pr[1], ";  ball", pb[0], pb[1])
    s.check(pb[0] < 0.01 and pr[0] > 10 * pb[0] and pr[1] > 10, "near the middle-axis singularity the plain revolutes' rates blow up (> 10 rad/s, 10x the energy error); the ball does not")

    # ---- parity with maximal coordinates ------------------------------------------------------------------------
    var mc = ContactScene6[QuatBody6]()
    var piv = mc.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), True)
    var rod = mc.add(QuatBody6(Vec3(0, -0.5, 0, 0), Quat.identity(), ZERO, ZERO, Inertia3(1, ROD_I[0], ROD_I[1], ROD_I[2])), Vec3(0.05, 0.5, 0.05, 0), False)
    mc.set_can_sleep(rod, False)
    var bj = mc.add_joint(Joint6.ball(piv.index(), rod.index(), ZERO, Vec3(0, 0.5, 0, 0)))
    mc.set_collide_connected(bj, False)
    var rr = _ball_rod()
    rr.qd[0] = 0.8
    rr.qd[2] = 1.2
    mc.set_velocity(rod, cross(Vec3(0.8, 0, 1.2, 0), Vec3(0, -0.5, 0, 0)), Vec3(0.8, 0, 1.2, 0))
    var worst = Real(0)
    for _ in range(480):
        rr.step(DT, zero3, G)
        mc.step_soft(DT, G)
        var tip_r = rr.point_world(2, Vec3(0, -1, 0, 0))
        var tip_m = mc.bset.bodies[rod.index()].act(Vec3(0, -0.5, 0, 0))
        worst = max(worst, length(tip_r - tip_m))
    print("  ball joint vs maximal Joint6.ball, 3-D swing, 2 s: max tip distance", worst)
    s.check(worst < 0.01, "reduced and maximal ball joints: tips within 1 cm over 2 s")

    # ---- snapshot ---------------------------------------------------------------------------------------------------
    var sc = _ball_rod()
    sc.qd[0] = 0.7
    sc.qd[2] = -0.4
    for _ in range(100):
        sc.step(DT, zero3, G)
    var w = BinWriter()
    write_chain(sc, w)
    var rd = BinReader(w.b.copy())
    var back = read_chain(rd)
    for _ in range(200):
        sc.step(DT, zero3, G)
        back.step(DT, zero3, G)
    var same = True
    for k in range(3):
        if sc.qd[k] != back.qd[k]:
            same = False
    var qa = sc.ball_orientation(2)
    var qb = back.ball_orientation(2)
    s.check(same and qa.x == qb.x and qa.w == qb.w, "a ball chain restored mid-run steps bit for bit")

    # ---- extremes ----------------------------------------------------------------------------------------------------
    var sp = _ball_rod()
    sp.qd[2] = 10
    for _ in range(1200):
        sp.step(DT, zero3, ZERO)
    var qn = sp.ball_orientation(2)
    var norm = sqrt(qn.x * qn.x + qn.y * qn.y + qn.z * qn.z + qn.w * qn.w)
    print("  10 rad/s for 5 s (", Real(50 / (2 * pi)), "turns): |q| - 1 =", norm - 1, " spin", sp.qd[2])
    s.check(abs(norm - 1) < 1e-5 and abs(sp.qd[2] - 10) < 1e-3, "many full turns: unit quaternion, constant spin")
    var raised = 0
    var c0 = Chain()
    try:
        _ = c0.add_ball(-1, ZERO, ZERO, 0, ROD_I)
    except:
        raised += 1
    var c1 = _ball_rod()
    try:
        c1.set_joint_props(1, 0, 5)
    except:
        raised += 1
    try:
        _ = ArticBatch(c1, 4)
    except:
        raised += 1
    s.check(raised == 3, "mass 0, a stiffness on a ball DOF and ArticBatch with a ball raise")
    s.finish()
