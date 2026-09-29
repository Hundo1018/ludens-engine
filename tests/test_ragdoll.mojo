# tier: integration
"""Active ragdoll (ROADMAP 17.2): a leg -- animated pelvis, simulated thigh
and shin -- in a `ContactScene6`, driven by an animation pose.

  ordinary     starting straight, the drives bend the leg into the animated
               pose and hold it against gravity (a steady sag that shrinks
               with stiffness); limp (strength 0) it hangs.
  seam parity  drives with a zero torque cap step bit-identically to the
               same scene with no drives at all.
  integration  the animated pelvis walks and the kinematic body follows it
               exactly while the simulated leg stays attached; a hit knocks
               the shin off its pose and the drives pull it back; the
               get-up blend is the animation exactly at weight 0 and the
               ragdoll exactly at weight 1.
  extreme      a very stiff drive (1000 Hz) stays finite and on target;
               add_drive out of range raises; removing a driven body raises.
"""

from std.math import sin, cos, acos, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import AngularDrive
from procedural.anim_graph import Pose, to_world
from gameplay.ragdoll import Ragdoll, blend_world

comptime DT: Real = 1.0 / 60.0


def _qx(deg: Real) -> Quat:
    var h = deg * Real(3.14159265358979 / 360.0)
    return Quat(sin(h), 0, 0, cos(h))


def _parents() -> List[Int]:
    var p = List[Int]()
    p.append(-1)
    p.append(0)
    p.append(1)
    return p^


def _local(hip_deg: Real, knee_deg: Real, pelvis_x: Real) -> Pose:
    var l = Pose(3)
    l.set(0, Vec3(pelvis_x, 2, 0, 0), Quat.identity())
    l.set(1, Vec3(0, -0.1, 0, 0), _qx(hip_deg))
    l.set(2, Vec3(0, -0.45, 0, 0), _qx(knee_deg))
    return l^


def _leg(mut sc: ContactScene6[QuatBody6], start: Pose, max_torque: Real, hertz: Real = 8) raises -> Ragdoll:
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
    return Ragdoll(sc, to_world(start, _parents()), _parents(), half, off^, sim, 5, hertz, 1, max_torque)


def _err_deg(a: Quat, b: Quat) -> Real:
    var d = a * b.conjugate()
    return 2 * acos(min(abs(d.w), Real(1))) * Real(180.0 / 3.14159265358979)


def _worst(rd: Ragdoll, sc: ContactScene6[QuatBody6], anim_world: Pose) -> Real:
    var ph = rd.physics_pose(sc)
    return max(_err_deg(ph.q(1), anim_world.q(1)), _err_deg(ph.q(2), anim_world.q(2)))


def main() raises:
    var s = Suite("ragdoll")
    var g = Vec3(0, -9.8, 0, 0)
    var anim = to_world(_local(30, -40, 0), _parents())
    var straight = _local(0, 0, 0)

    # ---- ordinary: drive into the pose and hold it ----------------------
    var sc = ContactScene6[QuatBody6]()
    var rd = _leg(sc, straight, 400)
    for _ in range(120):
        rd.follow(sc, anim, DT)
        sc.step_soft(DT, g)
    var held = _worst(rd, sc, anim)
    print("  driven: worst joint error (deg)", held)
    # a soft drive has no integral term: under gravity it settles with a
    # steady sag that shrinks as the drive stiffens (checked below)
    s.check(held < 5, "drives bend the leg into the animated pose and hold it (8 Hz sag < 5 deg)")
    var sc20 = ContactScene6[QuatBody6]()
    var rd20 = _leg(sc20, straight, 400, 20)
    for _ in range(120):
        rd20.follow(sc20, anim, DT)
        sc20.step_soft(DT, g)
    var held20 = _worst(rd20, sc20, anim)
    print("  driven at 20 Hz: worst joint error (deg)", held20)
    s.check(held20 < held, "a stiffer drive sags less")
    var lc = ContactScene6[QuatBody6]()
    var limp = _leg(lc, straight, 400)
    limp.set_strength(lc, 0)
    for _ in range(120):
        limp.follow(lc, anim, DT)
        lc.step_soft(DT, g)
    var hang = _worst(limp, lc, anim)
    print("  limp: worst joint error (deg)", hang)
    s.check(hang > 20, "limp (strength 0): the leg hangs instead")

    # ---- seam parity: zero-cap drives == no drives --------------------------
    var za = ContactScene6[QuatBody6]()
    var zb = ContactScene6[QuatBody6]()
    var ra = _leg(za, _local(30, -40, 0), 0)
    var rb = _leg(zb, _local(30, -40, 0), 0)
    zb.drives = List[AngularDrive]()
    var same = True
    for _ in range(120):
        za.step_soft(DT, g)
        zb.step_soft(DT, g)
    for i in range(len(za.bset.bodies)):
        var d = za.bset.bodies[i].position() - zb.bset.bodies[i].position()
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            same = False
    s.check(same, "zero-cap drives step bit-identically to no drives")
    _ = ra.drive
    _ = rb.drive

    # ---- integration: walking pelvis, hit reaction, get-up blend ----------
    var wc = ContactScene6[QuatBody6]()
    var wr = _leg(wc, _local(30, -40, 0), 400)
    var gap = Real(0)
    var track = Real(0)
    for f in range(120):
        var x = Real(f + 1) * DT * 0.5
        var aw = to_world(_local(30, -40, x), _parents())
        wr.follow(wc, aw, DT)
        wc.step_soft(DT, g)
        var ph = wr.physics_pose(wc)
        track = max(track, length(ph.p(0) - aw.p(0)))
        # hip joint: the thigh's origin must stay on the pelvis's hip point
        gap = max(gap, length(ph.p(1) - (ph.p(0) + ph.q(0).rotate(Vec3(0, -0.1, 0, 0)))))
    print("  walking: pelvis tracking error", track, " hip gap", gap)
    s.check(track < 1e-3, "animated (kinematic) pelvis follows the animation")
    s.check(gap < 2e-2, "simulated leg stays attached to the moving pelvis")

    var before = _worst(rd, sc, anim)
    var shin_c = sc.bset.bodies[rd.ids[2].index()].position()
    rd.hit(sc, 2, Vec3(0, 0, 8, 0), shin_c)
    var peak = Real(0)
    for _ in range(90):
        rd.follow(sc, anim, DT)
        sc.step_soft(DT, g)
        peak = max(peak, _worst(rd, sc, anim))
    var after = _worst(rd, sc, anim)
    print("  hit: before", before, " peak", peak, " after 1.5 s", after)
    s.check(peak > before + 5, "a hit knocks the leg off its pose")
    s.check(after < before + 1, "the drives pull it back to its pre-hit state")

    var ph = rd.physics_pose(sc)
    var b0 = blend_world(anim, ph, 0)
    var b1 = blend_world(anim, ph, 1)
    var ex0 = True
    var ex1 = True
    for i in range(len(anim.pos)):
        if b0.pos[i] != anim.pos[i]:
            ex0 = False
        if b1.pos[i] != ph.pos[i]:
            ex1 = False
    s.check(ex0, "get-up blend at weight 0 IS the animation")
    s.check(ex1, "get-up blend at weight 1 IS the ragdoll")

    # ---- extremes -------------------------------------------------------------
    var hc = ContactScene6[QuatBody6]()
    var hr = _leg(hc, straight, 4000, 1000)
    for _ in range(120):
        hr.follow(hc, anim, DT)
        hc.step_soft(DT, g)
    var he = _worst(hr, hc, anim)
    var fin = True
    for i in range(len(hc.bset.bodies)):
        var p = hc.bset.bodies[i].position()
        if not (isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2])):
            fin = False
    print("  1000 Hz drive: error", he)
    s.check(fin and he < 3, "a 1000 Hz drive stays finite and on target")
    var raised = False
    try:
        _ = hc.add_drive(AngularDrive.make(0, 99, Quat.identity(), 5, 1, 10))
    except:
        raised = True
    s.check(raised, "add_drive out of range raises")
    raised = False
    try:
        hc.remove_body(hr.ids[2])
    except:
        raised = True
    s.check(raised, "removing a driven body raises")

    s.finish()
