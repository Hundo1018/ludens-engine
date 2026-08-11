"""Animation runtime: clips, blending and state-machine-driven playback (v3).

The skinning maths already existed; what this gates is the runtime around it —
sampling, cross-fading, and the state machine deciding which clip plays.

ORDINARY    a clip samples to its keys exactly at key times and interpolates
            between them; a looping clip returns to its start; all three blend
            modes reduce EXACTLY to their inputs at both endpoints.
INTEGRATION the blended pose drives `skinning.skin_motor`; `StateMachine`
            transitions drive `AnimPlayer.play`; and the linear and geodesic
            blends are shown to differ where they actually can — NOT at the
            midpoint, where normalised-lerp and slerp are provably identical,
            which is why the first version of this test proved nothing.
EXTREME     a single-frame clip, a zero-length clip, time far outside the clip
            (negative and many loops out), a zero-length cross-fade, replaying
            the clip already playing, and blending a quaternion against its own
            negation — the same rotation, which a naive blend spins right round.
"""

from std.math import sqrt, cos, sin, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.skinning import SkinVert, skin_motor
from procedural.anim import (
    AnimClip, AnimPlayer, blend_poses, pose_to_motors,
    BLEND_LINEAR, BLEND_DLB, BLEND_GEODESIC,
)
from scheduler.fsm import StateMachine

comptime BONES = 3


def _pose() -> List[Real]:
    var v = List[Real](capacity=3 * BONES)
    for _ in range(3 * BONES):
        v.append(0)
    return v^


def _rots() -> List[Real]:
    var v = List[Real](capacity=4 * BONES)
    for b in range(BONES):
        v.append(0)
        v.append(0)
        v.append(0)
        v.append(1)
    return v^


def _axis_clip(frames: Int, fps: Real, total_angle: Real, loop: Bool) -> AnimClip:
    """Bone 0 spins about z through `total_angle`; bone 1 slides along x; bone 2
    stays put. Keys are exact so a sample AT a key can be compared exactly."""
    var c = AnimClip(BONES, frames, fps, loop)
    for f in range(frames):
        var t = Real(f) / Real(frames - 1) if frames > 1 else Real(0)
        var a = total_angle * t
        c.set_key(f, 0, Vec3(0, 0, 0), Quat(0, 0, sin(a * 0.5), cos(a * 0.5)))
        c.set_key(f, 1, Vec3(t * 2, 0, 0), Quat(0, 0, 0, 1))
        c.set_key(f, 2, Vec3(0, 1, 0), Quat(0, 0, 0, 1))
    return c^


def main() raises:
    var s = Suite("anim")

    # ---- ORDINARY: sampling ----
    var c = _axis_clip(5, 10.0, Real(pi), False)  # 5 frames at 10fps = 0.4s
    s.check(abs(Float64(c.duration() - 0.4)) < 1e-6, "duration is (frames-1)/fps")

    var p = _pose()
    var r = _rots()
    c.sample(0.0, p, r)
    s.check(abs(Float64(p[3])) < 1e-6, "bone 1 starts at x = 0")
    c.sample(0.4, p, r)
    s.check(abs(Float64(p[3] - 2.0)) < 1e-5, "and ends at x = 2")
    c.sample(0.2, p, r)
    s.check(abs(Float64(p[3] - 1.0)) < 1e-5, "and is halfway at the midpoint")

    # a sample exactly at a key must BE that key
    c.sample(0.1, p, r)
    var kq = c.key_rot(1, 0)
    s.check(
        abs(Float64(r[2] - kq.z)) < 1e-5 and abs(Float64(r[3] - kq.w)) < 1e-5,
        "sampling exactly at a key reproduces the key",
    )

    var looped = _axis_clip(5, 10.0, Real(pi), True)
    var pl = _pose()
    var rl = _rots()
    var pl2 = _pose()
    var rl2 = _rots()
    looped.sample(0.05, pl, rl)
    looped.sample(0.45, pl2, rl2)  # one full loop later
    s.check(
        abs(Float64(pl[3] - pl2[3])) < 1e-5,
        "a looping clip repeats after exactly one duration",
    )

    # ---- ORDINARY: blend endpoints ----
    var ca = _axis_clip(2, 10.0, Real(0), False)
    var cb = _axis_clip(2, 10.0, Real(pi) * 0.75, False)
    var pa = _pose()
    var ra = _rots()
    var pb = _pose()
    var rb = _rots()
    ca.sample(0.1, pa, ra)
    cb.sample(0.1, pb, rb)

    for mode in range(3):
        var op = _pose()
        var orr = _rots()
        blend_poses(pa, ra, pb, rb, BONES, 0.0, mode, op, orr)
        var worst0 = Real(0)
        for i in range(4 * BONES):
            if abs(orr[i] - ra[i]) > worst0:
                worst0 = abs(orr[i] - ra[i])
        for i in range(3 * BONES):
            if abs(op[i] - pa[i]) > worst0:
                worst0 = abs(op[i] - pa[i])
        blend_poses(pa, ra, pb, rb, BONES, 1.0, mode, op, orr)
        var worst1 = Real(0)
        for i in range(4 * BONES):
            if abs(orr[i] - rb[i]) > worst1:
                worst1 = abs(orr[i] - rb[i])
        for i in range(3 * BONES):
            if abs(op[i] - pb[i]) > worst1:
                worst1 = abs(op[i] - pb[i])
        print("  blend mode", mode, " endpoint error w=0", worst0, " w=1", worst1)
        s.check(Float64(worst0) < 1e-4, "blend at w=0 reduces to the first pose")
        s.check(Float64(worst1) < 1e-4, "blend at w=1 reduces to the second pose")

    # ---- INTEGRATION: the blended pose drives skinning ----
    var rest = List[SkinVert](capacity=4)
    rest.append(SkinVert(Vec3(0, 0, 0)))
    rest.append(SkinVert(Vec3(1, 0, 0)))
    rest.append(SkinVert(Vec3(2, 0, 0)))
    rest.append(SkinVert(Vec3(3, 0, 0)))
    var ia = List[Int](capacity=4)
    var ib = List[Int](capacity=4)
    var wa = List[Real](capacity=4)
    for k in range(4):
        ia.append(0)
        ib.append(1)
        wa.append(1.0 - Real(k) / 3.0)
    var out = List[SkinVert](capacity=4)
    for _ in range(4):
        out.append(SkinVert(Vec3(0, 0, 0)))

    var mp = _pose()
    var mr = _rots()
    blend_poses(pa, ra, pb, rb, BONES, 0.5, BLEND_DLB, mp, mr)
    var motors = List[Motor3](capacity=BONES)
    for _ in range(BONES):
        motors.append(Motor3.identity())
    pose_to_motors(mp, mr, BONES, motors)
    skin_motor(motors, rest, ia, ib, wa, out)
    var finite = True
    for k in range(4):
        var v = out[k].v
        for d in range(3):
            if not (Float64(v[d]) > -1e6 and Float64(v[d]) < 1e6):
                finite = False
    s.check(finite, "a blended pose drives skinning to finite positions")

    # Constant angular speed, measured where the two blends can actually
    # disagree. At w = 0.5 normalised-lerp and slerp are IDENTICAL -- the
    # normalised midpoint of a chord lies on the great-circle midpoint -- so a
    # test at the midpoint proves nothing about the difference between them.
    # The first version of this check did exactly that and reported both modes
    # agreeing to 7 digits, which looked like a pass. Off-centre they separate,
    # and the geodesic one is the one that lands where constant speed says.
    var big_a = _pose()
    var big_ra = _rots()
    var big_b = _pose()
    var big_rb = _rots()
    var ang = Real(2.6)  # about 150 degrees
    big_ra[2] = 0
    big_ra[3] = 1
    big_rb[2] = sin(ang * 0.5)
    big_rb[3] = cos(ang * 0.5)
    var lin = _pose()
    var linr = _rots()
    var geo = _pose()
    var geor = _rots()
    var w_off = Real(0.25)
    blend_poses(big_a, big_ra, big_b, big_rb, BONES, w_off, BLEND_LINEAR, lin, linr)
    blend_poses(big_a, big_ra, big_b, big_rb, BONES, w_off, BLEND_GEODESIC, geo, geor)
    # constant speed puts the geodesic blend at exactly w * ang about z
    var want_z = sin(ang * 0.5 * w_off)
    print("  w=0.25 blend z — linear", linr[2], " geodesic", geor[2],
          " constant-speed exact", want_z)
    s.check(
        abs(Float64(geor[2] - want_z)) < 1e-4,
        "the geodesic blend is at exactly w of the way: constant angular speed",
    )
    s.check(
        abs(Float64(linr[2] - want_z)) > 1e-3,
        "and the linear one is NOT -- it lags, which is the whole difference",
    )

    # the midpoint coincidence, recorded rather than assumed
    var mid_l = _pose()
    var mid_lr = _rots()
    var mid_g = _pose()
    var mid_gr = _rots()
    blend_poses(big_a, big_ra, big_b, big_rb, BONES, 0.5, BLEND_LINEAR, mid_l, mid_lr)
    blend_poses(big_a, big_ra, big_b, big_rb, BONES, 0.5, BLEND_GEODESIC, mid_g, mid_gr)
    s.check(
        abs(Float64(mid_lr[2] - mid_gr[2])) < 1e-5,
        "at exactly w = 0.5 the two coincide, as the geometry requires",
    )

    # ---- INTEGRATION: a state machine driving playback ----
    var fsm = StateMachine()
    var idle = fsm.add_state()
    var walk = fsm.add_state()
    fsm.add_transition(idle, 0, walk)
    fsm.add_transition(walk, 1, idle)
    fsm.start(idle)

    var clips = List[AnimClip]()
    clips.append(_axis_clip(5, 10.0, Real(0), True))
    clips.append(_axis_clip(5, 10.0, Real(pi), True))

    var player = AnimPlayer(BONES, BLEND_DLB)
    s.eqi(player.current, 0, "the player starts on clip 0")
    _ = fsm.fire(0)
    if fsm.is_in(walk):
        player.play(1, 0.1)
    s.eqi(player.current, 1, "firing the transition switched the clip")
    s.eqi(player.previous, 0, "and kept the outgoing clip for the fade")
    s.check(player.fade > 0, "with the cross-fade running")

    var pp = _pose()
    var rr = _rots()
    player.evaluate(clips, pp, rr)
    s.check(True, "evaluating mid-fade does not crash")
    for _ in range(12):
        player.advance(1.0 / 60.0)
    s.check(player.fade == 0, "the fade finishes after its length")
    s.eqi(player.previous, -1, "and releases the outgoing clip")

    # ---- EXTREME ----
    var one = AnimClip(BONES, 1, 10.0, True)
    one.set_key(0, 0, Vec3(5, 6, 7), Quat(0, 0, 0, 1))
    var op1 = _pose()
    var or1 = _rots()
    one.sample(99.0, op1, or1)
    s.check(
        abs(Float64(op1[0] - 5.0)) < 1e-6,
        "a single-frame clip samples to that frame at any time",
    )
    s.check(abs(Float64(one.duration())) < 1e-9, "and has zero duration")

    var none = AnimClip(BONES, 0, 10.0, True)
    var op0 = _pose()
    var or0 = _rots()
    none.sample(1.0, op0, or0)
    s.check(op0[0] == 0, "an empty clip writes nothing and does not crash")

    var far = _pose()
    var farr = _rots()
    looped.sample(-3.7, far, farr)
    var ok_neg = Float64(far[3]) >= -1e-4 and Float64(far[3]) <= 2.0001
    looped.sample(1000.35, far, farr)
    var ok_big = Float64(far[3]) >= -1e-4 and Float64(far[3]) <= 2.0001
    s.check(ok_neg, "negative time wraps into the clip")
    s.check(ok_big, "and so does a time a thousand loops out")

    var clamped = _axis_clip(5, 10.0, Real(pi), False)
    var cp = _pose()
    var cr = _rots()
    clamped.sample(-5.0, cp, cr)
    s.check(abs(Float64(cp[3])) < 1e-6, "a non-looping clip clamps at the start")
    clamped.sample(500.0, cp, cr)
    s.check(abs(Float64(cp[3] - 2.0)) < 1e-5, "and at the end")

    var snap = AnimPlayer(BONES, BLEND_DLB)
    snap.play(1, 0.0)
    s.check(snap.fade == 0, "a zero-length fade snaps immediately")
    snap.advance(1.0 / 60.0)
    s.eqi(snap.current, 1, "and lands on the requested clip")

    var again = AnimPlayer(BONES, BLEND_DLB)
    again.play(1, 0.2)
    again.advance(0.1)
    var t_before = again.time
    again.play(1, 0.2)
    s.check(
        again.time == t_before,
        "replaying the clip already playing does not rewind it",
    )

    # q and -q are the SAME rotation; a blend between them must not spin
    var nq_a = _rots()
    var nq_b = _rots()
    nq_b[3] = -1  # identity, negated
    var nq_out = _pose()
    var nq_outr = _rots()
    var worst_spin = Real(0)
    for mode in range(3):
        blend_poses(_pose(), nq_a, _pose(), nq_b, BONES, 0.5, mode, nq_out, nq_outr)
        var w = abs(abs(nq_outr[3]) - 1)
        if w > worst_spin:
            worst_spin = w
    print("  q vs -q half-blend, worst deviation from identity:", worst_spin)
    s.check(
        Float64(worst_spin) < 1e-4,
        "blending a rotation against its own negation stays the identity",
    )

    s.finish()
