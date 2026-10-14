# tier: integration
"""Camera math, rigs and sequences (ROADMAP 17.68).

  1. Ordinary: `look_rotation` faces any direction, including straight up
     and down (the pole); the frustum's sphere test agrees with clipping
     through the reference `perspective` matrix on 2000 random points; the
     spring's exact solution gives the same state after two steps of dt as
     after one of 2 dt; a sequence read by random seeks equals a cursor
     playing it with uneven (and negative) steps bit for bit, and fires each
     event once forward and again, in reverse, on a backward scrub.
  2. Integration: a spring arm behind a wall stops in front of it (no
     overlap) and lets out smoothly when the wall is passed; a camera brain
     blends to the higher-priority camera and lands on it exactly.
  3. Extreme: zero trauma shakes exactly zero, the same seed repeats, trauma
     decays to 0; a NaN target is treated as the origin; a target inside a
     wall gives a zero-length arm.
"""

from std.math import sqrt, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from procedural.camera_math import CameraPose, Frustum, perspective, look_rotation, spring_damp, Shake
from procedural.sequence import Sequence, SeqCursor
from procedural.tween import EASE_CUBIC_OUT, EASE_LINEAR
from gameplay.camera_rig import SpringArm, CameraBrain


struct _Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.s >> 11) & 0xFFFFFFFF) / 4294967296.0)


def main() raises:
    var s = Suite("camera_seq")

    # ---- look rotation -----------------------------------------------------
    var worst = Real(0)
    for f in [Vec3(1, 0, 0, 0), Vec3(0, 0, -1, 0), Vec3(0, 1, 0, 0), Vec3(0, -1, 0, 0), Vec3(1, 2, -3, 0)]:
        var dir = f / length(f)
        var cam = CameraPose(Vec3(0, 0, 0, 0), look_rotation(dir, Vec3(0, 1, 0, 0)), 1, 1, 0.1, 10)
        worst = max(worst, length(cam.forward() - dir))
    print("  look_rotation: worst forward error", worst)
    s.check(worst < 1e-5, "look_rotation faces every direction, the poles included")

    # ---- frustum vs projection -------------------------------------------------
    var cam = CameraPose(Vec3(1, 2, 3, 0), look_rotation(Vec3(0.3, -0.2, -1, 0), Vec3(0, 1, 0, 0)), 1.0, 1.5, 0.5, 40)
    var fr = Frustum(cam)
    var proj = perspective(cam.fov_y, cam.aspect, cam.near, cam.far)
    var inv = cam.rotation.conjugate()
    var rng = _Rng(7)
    var agree = 0
    var inside = 0
    for _ in range(2000):
        var p = Vec3(rng.next() * 60 - 30, rng.next() * 60 - 30, rng.next() * 60 - 30, 0)
        var c = inv.rotate(p - cam.position)
        var x = proj.get(0, 0) * c[0]
        var y = proj.get(1, 1) * c[1]
        var z = proj.get(2, 2) * c[2] + proj.get(2, 3)
        var w = -c[2]
        var clip_in = w > 0 and abs(x) <= w and abs(y) <= w and abs(z) <= w
        if clip_in:
            inside += 1
        if clip_in == fr.sphere_visible(p, 0):
            agree += 1
    print("  frustum vs perspective clip on 2000 points:", agree, "agree,", inside, "inside")
    s.check(agree == 2000 and inside > 20, "frustum planes agree with the reference projection")

    # ---- spring ----------------------------------------------------------------------
    var a1 = spring_damp(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(5, 0, 0, 0), 0.3, 0.05)
    var a2 = spring_damp(a1[0], a1[1], Vec3(5, 0, 0, 0), 0.3, 0.05)
    var b = spring_damp(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(5, 0, 0, 0), 0.3, 0.1)
    print("  spring: two steps of 0.05", a2[0][0], " one of 0.1", b[0][0])
    s.check(abs(a2[0][0] - b[0][0]) < 1e-5 and abs(a2[1][0] - b[1][0]) < 1e-5, "the spring's exact solution is step-size independent")

    # ---- sequence: seek vs cursor, events ------------------------------------------------
    var seq = Sequence(10)
    var ks = seq.add_scalar_track()
    var kv = seq.add_vec3_track()
    var kq = seq.add_quat_track()
    for i in range(11):
        seq.key_scalar(ks, Real(i), Real(i * i % 7), EASE_CUBIC_OUT if i % 2 == 0 else EASE_LINEAR)
        seq.key_vec3(kv, Real(i), Vec3(Real(i), Real(10 - i), Real(i % 3), 0))
        seq.key_quat(kq, Real(i), Quat.from_axis_angle(Vec3(0, 1, 0, 0), Real(i) * 0.5))
    seq.events.add(2.5, 1)
    seq.events.add(7.0, 2)
    var cur = SeqCursor(seq)
    var ev = List[Int]()
    var same = True
    var rr = _Rng(3)
    for k in range(400):
        var dt = rr.next() * 0.2 - (Real(0.15) if k % 50 > 44 else Real(0))
        cur.advance(seq, dt, ev)
        var t = cur.t
        if cur.scalar(seq, ks) != seq.scalar(ks, t) or cur.vec3(seq, kv) != seq.vec3(kv, t):
            same = False
        var q1 = cur.quat(seq, kq)
        var q2 = seq.quat(kq, t)
        if q1.x != q2.x or q1.y != q2.y or q1.z != q2.z or q1.w != q2.w:
            same = False
    s.check(same, "cursor playback == random seeks, bit for bit (uneven and negative steps)")
    var c2 = SeqCursor(seq)
    var e2 = List[Int]()
    c2.advance(seq, 10, e2)
    var back = List[Int]()
    c2.advance(seq, -10, back)
    print("  events forward", len(e2), "(", e2[0], e2[1], ")  backward", len(back), "(", back[0], back[1], ")")
    s.check(len(e2) == 2 and e2[0] == 1 and e2[1] == 2 and len(back) == 2 and back[0] == 2 and back[1] == 1, "events once forward, reversed on a backward scrub")
    var raised = False
    try:
        seq.key_scalar(ks, 3, 0)
    except:
        raised = True
    s.check(raised, "keys out of time order raise")

    # ---- spring arm -----------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 2.5, 0), Inertia3.box(1, 3, 3, 0.5)), Vec3(3, 3, 0.5, 0), True)  # wall face at z = 2
    var arm = SpringArm(5, 0.2)
    arm.pitch = 0
    var pose = arm.update(sc, Vec3(0, 1, 0, 0), 1.0 / 60.0)
    print("  arm behind a wall 2 m away: camera z", pose.position[2], " arm", arm.arm)
    s.check(pose.position[2] + arm.radius <= 2.0 + 1e-4 and pose.position[2] > 1.5, "spring arm stops in front of the wall")
    var sc2 = ContactScene6[QuatBody6]()
    var arm2 = arm.copy()
    var first = arm2.update(sc2, Vec3(0, 1, 0, 0), 1.0 / 60.0)
    var steps = 0
    while arm2.arm < 4.95 and steps < 300:
        _ = arm2.update(sc2, Vec3(0, 1, 0, 0), 1.0 / 60.0)
        steps += 1
    print("  wall gone: arm after one frame", first.position[2], " reaches 4.95 m after", steps, "frames")
    s.check(first.position[2] < 2.5 and steps > 5 and steps < 120, "it lets out smoothly, not at once")
    var inner = SpringArm(5, 0.2)
    var pin = inner.update(sc, Vec3(0, 0, 2.5, 0), 1.0 / 60.0)
    s.check(inner.arm == 0 and length(pin.position - Vec3(0, 0, 2.5, 0)) < 1e-6, "target inside the wall: zero-length arm")
    var zero = Real(0)
    var an = SpringArm(5, 0.2)
    var pn = an.update(sc2, Vec3(zero / zero, 0, 0, 0), 1.0 / 60.0)
    s.check(isfinite(pn.position[0]) and isfinite(pn.position[1]), "NaN target: treated as the origin")

    # ---- brain ------------------------------------------------------------------------------
    var ca = CameraPose(Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1), 1.0, 1.5, 0.1, 100)
    var cb = CameraPose(Vec3(10, 0, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 1.0), 0.5, 1.5, 0.1, 100)
    var cams: List[CameraPose] = [ca, cb]
    var brain = CameraBrain(1.0, EASE_LINEAR)
    var shown = brain.update(cams, [2, 1], 0.1, ca)
    var mid = shown
    for k in range(10):
        shown = brain.update(cams, [1, 2], 0.1, shown)
        if k == 4:
            mid = shown
    shown = brain.update(cams, [1, 2], 0.1, shown)
    print("  brain: halfway x", mid.position[0], " fov", mid.fov_y, "  end x", shown.position[0])
    s.check(abs(mid.position[0] - 5) < 1e-4 and abs(mid.fov_y - 0.75) < 1e-5 and shown.position[0] == 10 and shown.fov_y == 0.5, "brain blends to the higher-priority camera and lands on it")

    # ---- shake ----------------------------------------------------------------------------------
    var sh = Shake(42)
    var o0 = sh.offset(1.3)
    s.check(o0[0] == Vec3(0, 0, 0, 0) and o0[1] == Vec3(0, 0, 0, 0), "zero trauma: no shake")
    sh.add(0.8)
    var sh2 = Shake(42)
    sh2.add(0.8)
    var sh3 = Shake(43)
    sh3.add(0.8)
    s.check(sh.offset(1.3)[0] == sh2.offset(1.3)[0] and sh.offset(1.3)[0] != sh3.offset(1.3)[0], "same seed repeats, another seed differs")
    for _ in range(60):
        sh.advance(1.0 / 60.0)
    s.check(sh.trauma == 0, "trauma decays to 0 (0.8 at 1 per second, within 1 s)")
    s.finish()
