# tier: integration
"""Weld joint (ROADMAP 17.5; the rigid bond fracture is built from).

`JOINT_WELD` = ball + a full 3-axis angular lock to a reference relative
rotation. The 3-D scene had ball, distance and hinge joints only.

  ordinary     a box welded to a static anchor by an OFF-CENTRE point keeps its
               pose under gravity (a ball joint at the same point swings it --
               the differential proves the angular lock is what holds it); a
               weld made with a relative twist keeps THAT twist.
  integration  two welded dynamic boxes fall and land as one rigid body; a weld
               with a break threshold releases (`JOINT_BROKEN`, 17.29) when
               overloaded and the halves then separate; welded bodies do not
               collide with each other while unwelded overlapping ones do.
  extreme      a weld between two static bodies is inert; a weld to itself's
               partner removed from the pair by a break leaves the pair free to
               collide the next step.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6, JOINT_BROKEN, JOINT_WELD

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _anchor_scene(weld: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var b = sc.add(QuatBody6.at_rest(Vec3(1.0, 5, 0, 0), Inertia3.box(2, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    sc.set_can_sleep(b, False)
    # the anchor sits at the static body's centre, 1 m from the box's centre
    if weld:
        _ = sc.add_joint(Joint6.weld(0, 1, Vec3(0, 0, 0, 0), Vec3(-1, 0, 0, 0), Quat.identity()))
    else:
        _ = sc.add_joint(Joint6.ball(0, 1, Vec3(0, 0, 0, 0), Vec3(-1, 0, 0, 0)))
    return sc^


def main() raises:
    var s = Suite("weld")

    # ---- ordinary --------------------------------------------------------
    var w = _anchor_scene(True)
    var bl = _anchor_scene(False)
    for _ in range(180):
        w.step_soft(DT, G)
        bl.step_soft(DT, G)
    var dw = length(w.bset.bodies[1].position() - Vec3(1, 5, 0, 0))
    var db = length(bl.bset.bodies[1].position() - Vec3(1, 5, 0, 0))
    var tilt = abs(w.bset.bodies[1].rotation().z) + abs(w.bset.bodies[1].rotation().x) + abs(w.bset.bodies[1].rotation().y)
    print("  weld drift", dw, " ball drift", db, " weld tilt", tilt)
    s.check(dw < 0.02, "welded box stays put on an off-centre anchor")
    s.check(tilt < 0.02, "...and keeps its orientation")
    s.check(db > 0.5, "the same anchor as a ball joint swings (the lock is the weld)")

    # a weld made with a relative twist keeps the twist
    var tw = ContactScene6[QuatBody6]()
    _ = tw.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var twist = Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.6)
    var tb = QuatBody6(Vec3(1, 5, 0, 0), twist, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), Inertia3.box(2, 0.3, 0.3, 0.3))
    var tid = tw.add(tb^, Vec3(0.3, 0.3, 0.3, 0), False)
    tw.set_can_sleep(tid, False)
    _ = tw.add_joint(Joint6.weld(0, 1, Vec3(0, 0, 0, 0), Vec3(-1, 0, 0, 0), twist))
    for _ in range(180):
        tw.step_soft(DT, G)
    var q = tw.bset.bodies[1].rotation()
    var dot = q.x * twist.x + q.y * twist.y + q.z * twist.z + q.w * twist.w
    s.check(abs(dot) > 0.9995, "weld keeps its reference twist (|q . q_ref| = " + String(abs(dot)) + ")")

    # ---- integration -----------------------------------------------------
    # two welded boxes fall together and land as one body
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)), Vec3(30, 1, 30, 0), True)
    var ia = sc.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var ib = sc.add(QuatBody6.at_rest(Vec3(0.5, 2, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var j = sc.add_joint(Joint6.weld(ia.index(), ib.index(), Vec3(0.25, 0, 0, 0), Vec3(-0.25, 0, 0, 0), Quat.identity()))
    for _ in range(240):
        sc.step_soft(DT, G)
    var pa = sc.bset.bodies[ia.index()].position()
    var pb = sc.bset.bodies[ib.index()].position()
    print("  landed pair: gap", length(pb - pa), "heights", pa[1], pb[1])
    s.almost(Float64(length(pb - pa)), 0.5, "welded pair keeps its spacing through a fall and landing", 0.02)
    s.check(abs(pa[1] - 0.25) < 0.05 and abs(pb[1] - 0.25) < 0.05, "...and rests on the floor")
    s.check(sc.bset.sleeping[ia.index()] and sc.bset.sleeping[ib.index()], "...and sleeps as one island")
    s.eqi(sc.island_count(), 1, "one island for the welded pair")

    # overloaded weld breaks, is reported once, then the halves separate
    var br = ContactScene6[QuatBody6]()
    _ = br.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var hb = br.add(QuatBody6.at_rest(Vec3(0, 4, 0, 0), Inertia3.box(5, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    br.set_can_sleep(hb, False)
    var jb = br.add_joint(Joint6.weld(0, 1, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0), Quat.identity()))
    br.set_joint_break(jb, 5 * 9.8 * 0.5, 1e6)  # half the weight
    var reports = 0
    for _ in range(60):
        br.step_soft(DT, G)
        reports += len(br.broken_joints)
    s.check(br.joints[jb].kind == JOINT_BROKEN, "overloaded weld breaks")
    s.eqi(reports, 1, "...reported once")
    s.check(br.bset.bodies[1].position()[1] < 3.5, "...and the load falls")

    # welded bodies do not collide; overlapping unwelded ones do
    var ov = ContactScene6[QuatBody6]()
    var ox = ov.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var oy = ov.add(QuatBody6.at_rest(Vec3(0.6, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    _ = ov.add_joint(Joint6.weld(ox.index(), oy.index(), Vec3(0.3, 0, 0, 0), Vec3(-0.3, 0, 0, 0), Quat.identity()))
    var free = ContactScene6[QuatBody6]()
    var fx = free.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var fy = free.add(QuatBody6.at_rest(Vec3(0.6, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    for _ in range(30):
        ov.step_soft(DT, Vec3(0, 0, 0, 0))
        free.step_soft(DT, Vec3(0, 0, 0, 0))
    var wgap = Float64(ov.bset.bodies[oy.index()].position()[0] - ov.bset.bodies[ox.index()].position()[0])
    var fgap = Float64(free.bset.bodies[fy.index()].position()[0] - free.bset.bodies[fx.index()].position()[0])
    print("  overlap 0.4: welded spacing", wgap, " free spacing", fgap)
    s.almost(wgap, 0.6, "welded overlapping boxes are left alone", 0.01)
    s.check(fgap > 0.8, "unwelded overlapping boxes are pushed apart")

    # ---- extreme ---------------------------------------------------------
    var st = ContactScene6[QuatBody6]()
    _ = st.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
    _ = st.add(QuatBody6.at_rest(Vec3(3, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
    _ = st.add_joint(Joint6.weld(0, 1, Vec3(1.5, 0, 0, 0), Vec3(-1.5, 0, 0, 0), Quat.identity()))
    for _ in range(10):
        st.step_soft(DT, G)
    s.check(length(st.bset.bodies[0].position()) == 0 and length(st.bset.bodies[1].position() - Vec3(3, 0, 0, 0)) == 0, "weld between two static bodies is inert")

    # after the break the pair collides again
    var rb = ContactScene6[QuatBody6]()
    var ra = rb.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var rc = rb.add(QuatBody6.at_rest(Vec3(0.6, 0, 0, 0), Inertia3.box(2, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var jr = rb.add_joint(Joint6.weld(ra.index(), rc.index(), Vec3(0.3, 0, 0, 0), Vec3(-0.3, 0, 0, 0), Quat.identity()))
    rb.joints[jr].kind = JOINT_BROKEN  # as if released
    for _ in range(30):
        rb.step_soft(DT, Vec3(0, 0, 0, 0))
    s.check(
        rb.bset.bodies[rc.index()].position()[0] - rb.bset.bodies[ra.index()].position()[0] > 0.8,
        "a released weld no longer exempts the pair from contact",
    )
    s.finish()
