"""Animation runtime: clips, blend trees, and a state machine driving them.

`geometry/skinning.mojo` already deforms a mesh given the bone motors for a
frame. What was missing is everything that decides WHAT those motors are: the
clips they are sampled from, the blend that mixes two clips during a transition,
and the state machine that decides which clips are playing.

Three ways to blend are offered, because they differ in a way that shows up on
screen rather than only in a table:

  LINEAR    component-wise on translation and quaternion, normalised. Cheapest,
            and wrong in the classic way — the interpolated rotation does not
            travel at constant angular speed, and a 180-degree blend can take a
            path through a shorter axis than the one the animator authored.
  DLB       dual-quaternion linear blend via `skinning.blend2` on the motors:
            hemisphere-align, weighted sum, normalise. Fixes the candy-wrapper
            collapse that plagues linear skinning.
  GEODESIC  `galie.geodesic3` — exp/log on the motor manifold, the actual
            shortest screw path. The most expensive and the only one that is
            constant-speed by construction.

All three agree exactly at the endpoints, which is what makes the choice safe
to change: a blend that did not reduce to its inputs at t=0 and t=1 would make
every transition pop.

Bone tracks are stored as flat `List[Real]` — a `List[Vec3]` loses its tail
elements when passed between functions on this nightly (`collision/hull.mojo`
carries the reduced probe), and a clip is nothing but arrays handed around.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat, slerp
from geometry.motor import Motor3
from geometry.galie import geodesic3
from geometry.skinning import blend2

comptime BLEND_LINEAR = 0
comptime BLEND_DLB = 1
comptime BLEND_GEODESIC = 2


struct AnimClip(Movable, ImplicitlyDeletable):
    """Uniformly-sampled keyframes for a fixed set of bones.

    Uniform sampling rather than arbitrary key times: it makes lookup a
    multiply and a floor instead of a search, and a runtime that has to sample
    every bone of every playing clip every frame spends more time searching
    than interpolating otherwise. Non-uniform authoring is a bake-time concern.
    """

    var bones: Int
    var frames: Int
    var fps: Real
    var loop: Bool
    var pos: List[Real]  # 3 per (frame, bone), frame-major
    var rot: List[Real]  # 4 per (frame, bone), frame-major, xyzw

    def __init__(out self, bones: Int, frames: Int, fps: Real, loop: Bool = True):
        self.bones = bones
        self.frames = frames
        self.fps = fps
        self.loop = loop
        self.pos = List[Real](capacity=3 * bones * frames)
        self.rot = List[Real](capacity=4 * bones * frames)
        for _ in range(bones * frames):
            self.pos.append(0)
            self.pos.append(0)
            self.pos.append(0)
            self.rot.append(0)
            self.rot.append(0)
            self.rot.append(0)
            self.rot.append(1)

    def duration(self) -> Real:
        """Seconds. A looping clip's last frame is the same pose as its first,
        so the loop length is one interval SHORTER than the frame count would
        suggest — getting this wrong makes a loop stutter once per cycle."""
        if self.frames <= 1:
            return 0
        return Real(self.frames - 1) / self.fps

    def set_key(mut self, frame: Int, bone: Int, p: Vec3, q: Quat):
        var i = frame * self.bones + bone
        self.pos[3 * i] = p[0]
        self.pos[3 * i + 1] = p[1]
        self.pos[3 * i + 2] = p[2]
        self.rot[4 * i] = q.x
        self.rot[4 * i + 1] = q.y
        self.rot[4 * i + 2] = q.z
        self.rot[4 * i + 3] = q.w

    def key_pos(self, frame: Int, bone: Int) -> Vec3:
        var i = frame * self.bones + bone
        return Vec3(self.pos[3 * i], self.pos[3 * i + 1], self.pos[3 * i + 2])

    def key_rot(self, frame: Int, bone: Int) -> Quat:
        var i = frame * self.bones + bone
        return Quat(
            self.rot[4 * i], self.rot[4 * i + 1],
            self.rot[4 * i + 2], self.rot[4 * i + 3],
        )

    def sample(self, t: Real, mut out_pos: List[Real], mut out_rot: List[Real]):
        """Pose at time `t` seconds, written flat into the two output arrays.

        Rotations are interpolated with slerp rather than component-wise: the
        two are indistinguishable between adjacent keys of a smooth clip and
        very different across a sparse one, and a runtime cannot know which it
        was handed."""
        if self.frames == 0:
            return
        if self.frames == 1:
            for b in range(self.bones):
                var p = self.key_pos(0, b)
                var q = self.key_rot(0, b)
                _write(out_pos, out_rot, b, p, q)
            return

        var dur = self.duration()
        var u = t
        if self.loop:
            if dur > 0:
                u = t - dur * Real(Int(t / dur))
                if u < 0:
                    u += dur
        else:
            if u < 0:
                u = 0
            if u > dur:
                u = dur
        var f = u * self.fps
        var i0 = Int(f)
        if i0 >= self.frames - 1:
            i0 = self.frames - 2
        if i0 < 0:
            i0 = 0
        var a = f - Real(i0)
        if a < 0:
            a = 0
        if a > 1:
            a = 1
        for b in range(self.bones):
            var p0 = self.key_pos(i0, b)
            var p1 = self.key_pos(i0 + 1, b)
            var q = slerp(self.key_rot(i0, b), self.key_rot(i0 + 1, b), a)
            _write(out_pos, out_rot, b, p0 + (p1 - p0) * a, q)


def _write(
    mut out_pos: List[Real], mut out_rot: List[Real], b: Int, p: Vec3, q: Quat
):
    out_pos[3 * b] = p[0]
    out_pos[3 * b + 1] = p[1]
    out_pos[3 * b + 2] = p[2]
    out_rot[4 * b] = q.x
    out_rot[4 * b + 1] = q.y
    out_rot[4 * b + 2] = q.z
    out_rot[4 * b + 3] = q.w


def pose_to_motors(
    p: List[Real], r: List[Real], bones: Int, mut out: List[Motor3]
):
    """A sampled pose as PGA motors, the form `skinning` consumes."""
    for b in range(bones):
        out[b] = Motor3.from_quat_translation(
            Quat(r[4 * b], r[4 * b + 1], r[4 * b + 2], r[4 * b + 3]),
            Vec3(p[3 * b], p[3 * b + 1], p[3 * b + 2]),
        )


def blend_poses(
    pa: List[Real], ra: List[Real],
    pb: List[Real], rb: List[Real],
    bones: Int, w: Real, mode: Int,
    mut out_pos: List[Real], mut out_rot: List[Real],
):
    """Mix two sampled poses, `w` being the weight of the SECOND.

    Every mode reduces exactly to its inputs at w = 0 and w = 1 — checked in
    `test_anim`, because a blend that did not would make every transition pop
    at both ends."""
    for b in range(bones):
        var p0 = Vec3(pa[3 * b], pa[3 * b + 1], pa[3 * b + 2])
        var p1 = Vec3(pb[3 * b], pb[3 * b + 1], pb[3 * b + 2])
        var q0 = Quat(ra[4 * b], ra[4 * b + 1], ra[4 * b + 2], ra[4 * b + 3])
        var q1 = Quat(rb[4 * b], rb[4 * b + 1], rb[4 * b + 2], rb[4 * b + 3])

        if mode == BLEND_LINEAR:
            # hemisphere-align first: without it a blend between q and -q, the
            # SAME rotation, spins the bone all the way round
            var d = q0.x * q1.x + q0.y * q1.y + q0.z * q1.z + q0.w * q1.w
            var s = Real(-1) if d < 0 else Real(1)
            var qx = q0.x * (1 - w) + s * q1.x * w
            var qy = q0.y * (1 - w) + s * q1.y * w
            var qz = q0.z * (1 - w) + s * q1.z * w
            var qw = q0.w * (1 - w) + s * q1.w * w
            var n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
            if n < 1e-12:
                n = 1
            _write(
                out_pos, out_rot, b,
                p0 + (p1 - p0) * w,
                Quat(qx / n, qy / n, qz / n, qw / n),
            )
        elif mode == BLEND_DLB:
            var m = blend2(
                Motor3.from_quat_translation(q0, p0),
                Motor3.from_quat_translation(q1, p1),
                1 - w, w,
            )
            _motor_out(out_pos, out_rot, b, m)
        else:
            var m = geodesic3(
                Motor3.from_quat_translation(q0, p0),
                Motor3.from_quat_translation(q1, p1),
                w,
            )
            _motor_out(out_pos, out_rot, b, m)


def _motor_out(
    mut out_pos: List[Real], mut out_rot: List[Real], b: Int, m: Motor3
):
    """Decompose a motor back into translation and quaternion.

    `Motor3.to_quat_translation` already inverts `from_quat_translation`
    exactly; writing the rotor extraction out again here would be a second
    place for the e23/e13/e12 sign convention to drift from the first."""
    var qt = m.to_quat_translation()
    _write(out_pos, out_rot, b, qt[1], qt[0])


struct AnimPlayer(Movable, ImplicitlyDeletable):
    """One clip fading into another, driven by whatever changes `target`.

    Cross-fading is the whole reason this is stateful. Snapping between clips
    is a pop; a fade needs a weight that advances with time and a memory of
    what was playing when the change was requested, and neither belongs in the
    clip or in the state machine."""

    var bones: Int
    var current: Int
    var previous: Int
    var time: Real
    var prev_time: Real
    var fade: Real  # 0 = fully faded into `current`
    var fade_len: Real
    var mode: Int

    def __init__(out self, bones: Int, mode: Int = BLEND_DLB):
        self.bones = bones
        self.current = 0
        self.previous = -1
        self.time = 0
        self.prev_time = 0
        self.fade = 0
        self.fade_len = 0.2
        self.mode = mode

    def play(mut self, clip: Int, fade_len: Real = 0.2):
        """Switch to `clip`, cross-fading from whatever is playing.

        Re-requesting the clip already playing is a no-op rather than a
        restart: a state machine that fires the same event twice in a frame
        should not rewind the animation."""
        if clip == self.current:
            return
        self.previous = self.current
        self.prev_time = self.time
        self.current = clip
        self.time = 0
        self.fade_len = fade_len
        self.fade = 1 if fade_len > 0 else 0

    def advance(mut self, dt: Real):
        self.time += dt
        self.prev_time += dt
        if self.fade > 0 and self.fade_len > 0:
            self.fade -= dt / self.fade_len
            if self.fade <= 0:
                self.fade = 0
                self.previous = -1

    def evaluate(
        self, clips: List[AnimClip],
        mut out_pos: List[Real], mut out_rot: List[Real],
    ):
        clips[self.current].sample(self.time, out_pos, out_rot)
        if self.previous < 0 or self.fade <= 0:
            return
        var pp = List[Real](capacity=3 * self.bones)
        var pr = List[Real](capacity=4 * self.bones)
        for _ in range(self.bones):
            pp.append(0)
            pp.append(0)
            pp.append(0)
            pr.append(0)
            pr.append(0)
            pr.append(0)
            pr.append(1)
        clips[self.previous].sample(self.prev_time, pp, pr)
        # `fade` counts DOWN from 1, so it is the weight of the OUTGOING clip
        var cur_pos = List[Real](capacity=3 * self.bones)
        var cur_rot = List[Real](capacity=4 * self.bones)
        for i in range(3 * self.bones):
            cur_pos.append(out_pos[i])
        for i in range(4 * self.bones):
            cur_rot.append(out_rot[i])
        blend_poses(
            cur_pos, cur_rot, pp, pr, self.bones, self.fade, self.mode,
            out_pos, out_rot,
        )
