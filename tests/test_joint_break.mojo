# tier: integration
"""Breakable joints (ROADMAP 17.29).

  ordinary     a 2 kg box hanging on a distance joint: with a threshold above
               its weight it holds; below, it breaks within the first frames,
               is reported once, and the box falls.
  seam parity  the load estimate (peak over substeps of accumulated impulse
               / substep) of the hanging box equals m·g, the analytic
               constraint force -- a last-substep-only estimate reads the
               same in a steady state but misses impacts (the twisted
               hinge below breaks only under per-substep sampling); an
               unbreakable joint steps bit-identically to a joint with no
               threshold call at all.
  integration  a ragdoll's hip joint (17.2) with a break force: a heavy hit
               tears the leg off the pelvis; the break is published on a
               `scheduler.events.Channel` (17.38) and read back.
  extreme      thresholds <= 0 and an out-of-range joint raise; a torque threshold alone breaks
               a hinge twisted by a big angular impulse.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6, JOINT_BROKEN
from scheduler.events import Channel
from procedural.anim_graph import Pose, to_world
from gameplay.ragdoll import Ragdoll
from std.math import sin, cos

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _hang(mut sc: ContactScene6[QuatBody6]) raises -> Int:
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var id = sc.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(2, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_can_sleep(id, False)
    return sc.add_joint(Joint6.distance(0, 1, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1))


def main() raises:
    var s = Suite("joint_break")

    # ---- ordinary + parity: hanging box ------------------------------------
    var hold = ContactScene6[QuatBody6]()
    var jh = _hang(hold)
    hold.set_joint_break(jh, 2 * 9.8 * 1.2, 1e6)
    var any_break = False
    for _ in range(180):
        hold.step_soft(DT, G)
        if len(hold.broken_joints) > 0:
            any_break = True
    s.check(not any_break and hold.joints[jh].kind != JOINT_BROKEN, "threshold above the weight: holds")
    var h = DT / 4
    var load = length(hold.joints[jh].acc) / h  # last-substep estimate
    print("  load estimate", load, " m*g", 2 * 9.8)
    s.almost(Float64(load), 2 * 9.8, "load estimate == m*g in the steady state", 0.02 * 19.6)

    var brk = ContactScene6[QuatBody6]()
    var jb = _hang(brk)
    brk.set_joint_break(jb, 2 * 9.8 * 0.8, 1e6)
    var reports = 0
    for _ in range(60):
        brk.step_soft(DT, G)
        reports += len(brk.broken_joints)
    s.check(brk.joints[jb].kind == JOINT_BROKEN, "threshold below the weight: breaks")
    s.eqi(reports, 1, "the break is reported exactly once")
    s.check(brk.bset.bodies[1].position()[1] < 1.5, "the released box falls")

    var u1 = ContactScene6[QuatBody6]()
    var u2 = ContactScene6[QuatBody6]()
    var j1 = _hang(u1)
    _ = _hang(u2)
    u1.set_joint_break(j1, 1e9, 1e9)
    u1.bset.bodies[1].vel = Vec3(1, 0, 0.5, 0)
    u2.bset.bodies[1].vel = Vec3(1, 0, 0.5, 0)
    for _ in range(120):
        u1.step_soft(DT, G)
        u2.step_soft(DT, G)
    var dp = u1.bset.bodies[1].position() - u2.bset.bodies[1].position()
    s.check(dp[0] == 0 and dp[1] == 0 and dp[2] == 0, "unbreakable threshold == no threshold, bit for bit")

    # ---- integration: tear a ragdoll leg, publish the event ------------------
    var rc = ContactScene6[QuatBody6]()
    var par = List[Int]()
    par.append(-1)
    par.append(0)
    par.append(1)
    var loc = Pose(3)
    loc.set(0, Vec3(0, 2, 0, 0), Quat.identity())
    loc.set(1, Vec3(0, -0.1, 0, 0), Quat.identity())
    loc.set(2, Vec3(0, -0.45, 0, 0), Quat.identity())
    var half = List[Vec3]()
    half.append(Vec3(0.15, 0.08, 0.1, 0))
    half.append(Vec3(0.06, 0.2, 0.06, 0))
    half.append(Vec3(0.05, 0.2, 0.05, 0))
    var off = List[Vec3]()
    off.append(Vec3(0, 0, 0, 0))
    off.append(Vec3(0, -0.225, 0, 0))
    off.append(Vec3(0, -0.225, 0, 0))
    var sim = List[Bool]()
    sim.append(False)
    sim.append(True)
    sim.append(True)
    var world = to_world(loc, par)
    var rd = Ragdoll(rc, world, par.copy(), half, off^, sim)
    rc.set_joint_break(0, 3000, 1e6)  # hip = the first joint added
    var bus = Channel[Int]()
    var reader = bus.register_reader()
    var got = List[Int]()
    for f in range(60):
        if f == 10:
            var shin = rc.bset.bodies[rd.ids[2].index()].position()
            rd.hit(rc, 2, Vec3(0, -40, 60, 0), shin)
        rd.follow(rc, world, DT)
        rc.step_soft(DT, G)
        for k in range(len(rc.broken_joints)):
            bus.send(rc.broken_joints[k])
        bus.update()
        bus.read(reader, got)
    var ph = rd.physics_pose(rc)
    var gap = length(ph.p(1) - (ph.p(0) + Vec3(0, -0.1, 0, 0)))
    print("  torn leg: hip gap", gap, " events", len(got))
    s.check(rc.joints[0].kind == JOINT_BROKEN, "a heavy hit tears the hip joint")
    s.check(gap > 0.2, "the leg separates from the pelvis")
    s.check(len(got) == 1 and got[0] == 0, "the break arrives on the event channel")

    # ---- extremes -------------------------------------------------------------
    var bad = 0
    try:
        hold.set_joint_break(jh, 0, 10)
    except:
        bad += 1
    try:
        hold.set_joint_break(99, 10, 10)
    except:
        bad += 1
    s.eqi(bad, 2, "threshold <= 0 and out-of-range joint raise")

    var tw = ContactScene6[QuatBody6]()
    _ = tw.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var tb = tw.add(QuatBody6.at_rest(Vec3(0, 2.5, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    var jt = tw.add_joint(Joint6.hinge(0, 1, Vec3(0, -0.25, 0, 0), Vec3(0, 0.25, 0, 0), Vec3(0, 0, 1, 0)))
    tw.set_joint_break(jt, 1e6, 5)
    tw.bset.bodies[tb.index()].omega = Vec3(40, 0, 0, 0)
    for _ in range(10):
        tw.step_soft(DT, G)
    s.check(tw.joints[jt].kind == JOINT_BROKEN, "torque threshold alone breaks a twisted hinge")

    s.finish()
