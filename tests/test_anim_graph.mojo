# tier: integration
"""Animation graph nodes (ROADMAP 17.6).

  ordinary     a 1-D idle/walk/run space: at a sample value it IS that clip
               (bit for bit), between two it is their blend at a shared phase.
  seam parity  every node at its boundary weights reduces exactly to one
               input: 1-D and 2-D spaces at sample points, `layer` at mask
               0/1, `apply_additive` at weight 0.
  integration  an upper-body aim layer over locomotion touches only the
               masked bones; a half-weight additive of a 90-degree turn is
               45 degrees (motor geodesic); root motion extracted from the
               walk cycle drives the 17.1 character controller the same
               distance in the open and stops it at a wall.
  extreme      2-D weights non-negative and summing to 1 everywhere incl.
               far outside; duplicated sample points; a NaN clip weighted out
               leaves no NaN; a single-frame clip; an empty space; retarget
               onto a skeleton with 10x longer bones; motion matching finds
               a frame's own features.
"""

from std.math import sqrt, isfinite, acos, cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController
from procedural.anim import AnimClip, BLEND_DLB, BLEND_LINEAR, BLEND_GEODESIC
from procedural.anim_graph import (
    Pose, sample_phase, blend, BlendSpace1D, BlendSpace2D, layer,
    make_additive, apply_additive, root_motion, strip_root, Skeleton,
    retarget, MotionDB,
)

comptime BONES = 3  # root, spine, arm
comptime DT: Real = 1.0 / 60.0


def _qy(deg: Real) -> Quat:
    var h = deg * Real(3.14159265358979 / 360.0)
    return Quat(0, sin(h), 0, cos(h))


def _cycle(frames: Int, fps: Real, speed: Real, sway: Real) raises -> AnimClip:
    """Root translates at `speed` along x over the clip; spine sways."""
    var c = AnimClip(BONES, frames, fps)
    var dur = Real(frames - 1) / fps
    for f in range(frames):
        var t = Real(f) / fps
        c.set_key(f, 0, Vec3(speed * t, 1, 0, 0), Quat.identity())
        c.set_key(f, 1, Vec3(0, 0.5, 0, 0), _qy(sway * sin(t / dur * 6.2831853)))
        c.set_key(f, 2, Vec3(0.3, 0.4, 0, 0), Quat.identity())
    return c^


def _still(q_arm: Quat) raises -> AnimClip:
    var c = AnimClip(BONES, 2, 10)
    for f in range(2):
        c.set_key(f, 0, Vec3(0, 1, 0, 0), Quat.identity())
        c.set_key(f, 1, Vec3(0, 0.5, 0, 0), Quat.identity())
        c.set_key(f, 2, Vec3(0.3, 0.4, 0, 0), q_arm)
    return c^


def _same(a: Pose, b: Pose) -> Bool:
    for i in range(len(a.pos)):
        if a.pos[i] != b.pos[i]:
            return False
    for i in range(len(a.rot)):
        if a.rot[i] != b.rot[i]:
            return False
    return True


def _finite(a: Pose) -> Bool:
    for i in range(len(a.pos)):
        if not isfinite(a.pos[i]):
            return False
    for i in range(len(a.rot)):
        if not isfinite(a.rot[i]):
            return False
    return True


def _angle(q: Quat) -> Real:
    return 2 * acos(min(abs(q.w), Real(1))) * Real(180.0 / 3.14159265358979)


def main() raises:
    var s = Suite("anim_graph")
    var clips = List[AnimClip]()
    clips.append(_still(Quat.identity()))  # 0 idle
    clips.append(_cycle(11, 10, 1.0, 10))  # 1 walk, 1.0 s, 1 m/s
    clips.append(_cycle(7, 10, 3.0, 20))  # 2 run, 0.6 s, 3 m/s
    clips.append(_still(_qy(90)))  # 3 aim (arm turned 90 deg)
    var nan_clip = AnimClip(BONES, 2, 10)
    var nanv = Real(0) / Real(0)
    for f in range(2):
        for b in range(BONES):
            nan_clip.set_key(f, b, Vec3(nanv, nanv, nanv, 0), Quat(nanv, nanv, nanv, nanv))
    clips.append(nan_clip^)  # 4 NaN
    var one = AnimClip(BONES, 1, 10)
    for b in range(BONES):
        one.set_key(0, b, Vec3(0, Real(b), 0, 0), _qy(15))
    clips.append(one^)  # 5 single frame

    # ---- ordinary + parity: 1-D -------------------------------------------
    var bs = BlendSpace1D()
    bs.add(3, 2)
    bs.add(0, 0)
    bs.add(1, 1)
    s.check(bs.params[0] == 0 and bs.params[2] == 3, "1-D: samples kept sorted")
    s.check(_same(bs.evaluate(clips, 1, 0.3), sample_phase(clips[1], 0.3)), "1-D at a sample value IS that clip (bit for bit)")
    s.check(_same(bs.evaluate(clips, -5, 0.3), sample_phase(clips[0], 0.3)), "1-D below range clamps to the first clip")
    s.check(_same(bs.evaluate(clips, 9, 0.3), sample_phase(clips[2], 0.3)), "1-D above range clamps to the last clip")
    var mid = bs.evaluate(clips, 2, 0.5)
    # walk root at phase .5 = 0.5 m, run root at phase .5 = 0.9 m: shared phase
    s.almost(Float64(mid.p(0)[0]), 0.7, "1-D between: blend at the SAME phase (feet in step)", 1e-4)

    # ---- 2-D gradient band --------------------------------------------------
    var b2 = BlendSpace2D()
    b2.add(0, 0, 0)
    b2.add(1, 0, 1)
    b2.add(0, 1, 2)
    b2.add(-1, 0, 3)
    b2.add(0, -1, 5)
    var onehot = True
    for i in range(5):
        var w = b2.weights(b2.xs[i], b2.ys[i])
        for j in range(5):
            if w[j] != (Real(1) if j == i else Real(0)):
                onehot = False
    s.check(onehot, "2-D: weight exactly 1 at its own sample point, 0 for the others")
    var ok = True
    for gx in range(-8, 9):
        for gy in range(-8, 9):
            var w = b2.weights(Real(gx) * 0.5, Real(gy) * 0.5)
            var sw = Real(0)
            for j in range(5):
                if w[j] < 0:
                    ok = False
                sw += w[j]
            if abs(sw - 1) > 1e-5:
                ok = False
    s.check(ok, "2-D: weights >= 0 and sum to 1 on a grid out to 4x the range")
    s.check(_same(b2.evaluate(clips, 1, 0, 0.25), sample_phase(clips[1], 0.25)), "2-D at a sample point IS that clip")
    var dup = BlendSpace2D()
    dup.add(0, 0, 0)
    dup.add(0, 0, 1)
    var wd = dup.weights(3, 3)
    s.check(abs(wd[0] + wd[1] - 1) < 1e-6, "2-D: duplicated sample points still give a normalised weight")

    # ---- layer + additive ----------------------------------------------------
    var base = sample_phase(clips[1], 0.4)
    var aim = sample_phase(clips[3], 0)
    var mask = List[Real]()
    mask.append(0)
    mask.append(0)
    mask.append(1)
    var lay = layer(base, aim, mask, 1)
    s.check(lay.p(0) == base.p(0) and lay.q(1).y == base.q(1).y, "layer: unmasked bones are the base exactly")
    s.check(lay.q(2).y == aim.q(2).y and lay.q(2).w == aim.q(2).w, "layer: mask-1 bone is the overlay exactly")
    s.check(_same(layer(base, aim, mask, 0), base), "layer: alpha 0 is the base")
    var ref_pose = sample_phase(clips[0], 0)
    var delta = make_additive(aim, ref_pose)
    s.check(_same(apply_additive(base, delta, 0), base), "additive: weight 0 is the base")
    var half = apply_additive(ref_pose, delta, 0.5)
    s.almost(Float64(_angle(half.q(2))), 45, "additive: half of a 90-degree delta is 45 degrees (geodesic)", 1e-2)
    var full = apply_additive(ref_pose, delta, 1)
    s.almost(Float64(_angle(full.q(2))), 90, "additive: weight 1 applies the whole delta", 1e-2)
    s.almost(Float64(_angle(full.q(0))), 0, "additive: bones with an identity delta are unchanged", 1e-3)

    # ---- root motion -> character controller --------------------------------
    s.almost(Float64(root_motion(clips[1], 0, 0, 2.5)[0]), 2.5, "root motion across 2.5 walk cycles = 2.5 m", 1e-3)
    s.almost(Float64(root_motion(clips[2], 0, 0.1, 0.4)[0]), 0.9, "root motion inside one run cycle = 0.9 m", 1e-3)
    var stripped = sample_phase(clips[1], 0.5)
    strip_root(stripped, 0)
    s.check(stripped.p(0)[0] == 0 and stripped.p(0)[1] == 1, "strip_root: horizontal root translation removed, height kept")

    var open_sc = ContactScene6[QuatBody6]()
    _ = open_sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(30, 1, 30, 0), True)
    var wall_sc = ContactScene6[QuatBody6]()
    _ = wall_sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(30, 1, 30, 0), True)
    _ = wall_sc.add(QuatBody6.at_rest(Vec3(2.0, 1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(0.2, 1, 3, 0), True)
    var c_open = CharacterController(Vec3(0, 0.92, 0, 0))
    var c_wall = CharacterController(Vec3(0, 0.92, 0, 0))
    var t = Real(0)
    var g = Vec3(0, -9.8, 0, 0)
    for _ in range(180):
        var v = root_motion(clips[1], 0, t, t + DT) * (1 / DT)
        c_open.update(open_sc, v, 0, DT, g)
        c_wall.update(wall_sc, v, 0, DT, g)
        t += DT
    var expected = root_motion(clips[1], 0, 0, t)[0]
    s.almost(Float64(c_open.position[0]), Float64(expected), "root motion drives the controller the extracted distance in the open", 1e-2)
    s.check(c_wall.position[0] < 1.8 - 0.3 + 0.02, "root motion into a wall: the controller stops at it")

    # ---- extremes -------------------------------------------------------------
    var bn = BlendSpace1D()
    bn.add(0, 1)
    bn.add(1, 4)
    s.check(_finite(bn.evaluate(clips, 0, 0.3)), "a NaN clip weighted out leaves no NaN")
    s.check(_same(bn.evaluate(clips, 0, 0.3), sample_phase(clips[1], 0.3)), "... and the result is the other clip exactly")
    var b1 = BlendSpace1D()
    b1.add(0, 5)
    b1.add(1, 1)
    var single = b1.evaluate(clips, 0, 0.7)
    s.check(_same(single, sample_phase(clips[5], 0)), "single-frame clip: the same pose at every phase")
    var empty = BlendSpace1D()
    var ep = empty.evaluate(clips, 0.5, 0.5)
    s.check(ep.bones == BONES and ep.q(0).w == 1, "empty space: identity pose")

    var parent = List[Int]()
    parent.append(-1)
    parent.append(0)
    parent.append(1)
    var rest_s = Pose(BONES)
    rest_s.set(0, Vec3(0, 1, 0, 0), Quat.identity())
    rest_s.set(1, Vec3(0, 0.5, 0, 0), Quat.identity())
    rest_s.set(2, Vec3(0.3, 0.4, 0, 0), Quat.identity())
    var rest_d = Pose(BONES)
    for b in range(BONES):
        rest_d.set(b, rest_s.p(b) * 10, Quat.identity())
    var sk_s = Skeleton(parent.copy(), rest_s^)
    var sk_d = Skeleton(parent^, rest_d^)
    var src = sample_phase(clips[1], 0.3)
    var dst = retarget(src, sk_s, sk_d)
    s.check(_finite(dst), "retarget to 10x bones: finite")
    s.almost(Float64(dst.p(2)[0]), Float64(src.p(2)[0] * 10), "retarget: translations scale with bone length", 1e-4)
    s.check(dst.q(1).y == src.q(1).y and dst.q(1).w == src.q(1).w, "retarget: rotations copied exactly")

    var db = MotionDB()
    var fb = List[Int]()
    fb.append(1)
    fb.append(2)
    db.add_clip(clips, 1, 0, fb)
    db.add_clip(clips, 2, 0, fb)
    var probe = MotionDB.feature(clips[2], 0, fb, 0.3)
    var hit = db.query(probe)
    s.check(db.clip_of[hit] == 2 and abs(db.time_of[hit] - 0.3) < 1e-4, "motion matching: a frame's own features find that frame")

    s.finish()
