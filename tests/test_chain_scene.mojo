# tier: integration
"""Two-way contact between a `Chain` and `ContactScene6` bodies (ROADMAP
17.51, `physics.chain_scene.couple_contacts`).

  1. Ordinary: a 1 m pendulum released from -1 rad strikes a 1 kg box
     resting on a frictionless floor: the box leaves with exactly the
     momentum the chain gave it (sum of the returned impulses, within
     0.1 %), and the pendulum slows.
  2. Integration: a 5 kg leg on a vertical prismatic joint stands on a 1 kg
     box on the floor: after 2 s the leg rests on the box top, the box on
     the floor, and the leg pushes the box with its weight (49 N, from the
     impulses per step).
  3. Parity: the leg falling onto a STATIC box in the scene lands where
     `Chain.resolve_contacts` against the same colliders puts it (within
     1 mm).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.chain import Chain, ChainLink
from physics.chain_scene import couple_contacts

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6], top: Real) raises:
    var f = sc.add(QuatBody6.at_rest(Vec3(0, top - 0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    sc.set_friction(f.index(), 0)


def _leg() -> Chain:
    var c = Chain()
    c.add_link(ChainLink.prismatic(Vec3(0, 1, 0, 0), Vec3(0, 1.0, 0, 0), ZERO, 5, Vec3(0.1, 0.1, 0.1, 0)))
    return c^


def main() raises:
    var s = Suite("chain_scene")

    # ---- pendulum strikes a box -----------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _floor(sc, 0.35)
    var box = sc.add(QuatBody6.at_rest(Vec3(0.4, 0.6, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_friction(box.index(), 0)
    sc.set_sleep_thresholds(box, 0, 0)
    var pend = Chain()
    pend.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 1.6, 0, 0), Vec3(0, -0.5, 0, 0), 2, Vec3(2.0 / 12.0, 1e-3, 2.0 / 12.0, 0)))
    pend.q[0] = -1.0
    var pts = List[Int]()
    pts.append(0)
    var locs = List[Vec3]()
    locs.append(Vec3(0, -1, 0, 0))
    var z1 = List[Real](length=1, fill=0)
    for _ in range(30):  # let the box settle on the floor first
        sc.step_soft(DT, G)
    var given = Vec3(0, 0, 0, 0)
    var p_before = sc.velocity(box)[0] * 1
    var w_peak = Real(0)
    for _ in range(120):
        pend.step(DT, z1, G)
        var r = couple_contacts(pend, sc, pts, locs, DT)
        given = given + r[1]
        w_peak = max(w_peak, pend.qd[0])
        sc.step_soft(DT, G)
    var p_box = sc.velocity(box)[0] * 1 - p_before
    print("  pendulum strikes a box: impulse given", given[0], " box momentum", p_box, " pendulum peak", w_peak, "rad/s, after", pend.qd[0])
    s.check(given[0] > 0.5 and abs(p_box - given[0]) < 1e-3 * abs(given[0]), "the box leaves with the momentum the chain gave it (0.1 %)")
    s.check(pend.qd[0] < w_peak - 0.5, "the pendulum slows at the impact")

    # ---- a leg standing on a dynamic box ----------------------------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _floor(sl, 0)
    var lb = sl.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sl.set_sleep_thresholds(lb, 0, 0)
    var leg = _leg()
    var lp = List[Int]()
    lp.append(0)
    var ll = List[Vec3]()
    ll.append(Vec3(0, -0.5, 0, 0))
    var push = Real(0)
    for k in range(240):
        leg.step(DT, z1, G)
        var r = couple_contacts(leg, sl, lp, ll, DT)
        sl.step_soft(DT, G)
        if k >= 180:
            push += r[1][1]
    push = push / (60 * DT)
    var foot = leg.point_world(0, ll[0])[1]
    var by = sl.pose(lb).pos[1]
    print("  5 kg leg on a 1 kg box: foot y", foot, " box top", by + 0.25, " push on the box", push, "N (weight -49)")
    s.check(abs(foot - (by + 0.25)) < 0.02 and abs(by - 0.25) < 0.02, "the leg rests on the box, the box on the floor")
    s.check(abs(push + 49) < 2.5, "the leg pushes the box with its weight (49 N within 5 %)")

    # ---- static parity --------------------------------------------------------------------------------------------
    var ss = ContactScene6[QuatBody6]()
    _ = ss.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), True)
    var la = _leg()
    var lr = _leg()
    la.q[0] = 0.3
    lr.q[0] = 0.3
    var poses = ss.query_poses()
    var dq = Real(0)
    for _ in range(120):
        la.step(DT, z1, G)
        lr.step(DT, z1, G)
        _ = couple_contacts(la, ss, lp, ll, DT)
        _ = lr.resolve_contacts(ss.colliders, poses, 0.0, lp, ll, DT)
        dq = max(dq, abs(la.q[0] - lr.q[0]))
    print("  leg falling on a static box: couple_contacts vs resolve_contacts max |dq|", dq, " rest q", la.q[0])
    s.check(dq < 1e-3, "on static bodies couple_contacts lands like resolve_contacts (1 mm)")
    s.finish()
