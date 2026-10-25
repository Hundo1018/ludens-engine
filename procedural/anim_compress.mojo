"""Clip compression by key reduction (ROADMAP 17.64).

`AnimClip` stores every bone at every frame. `reduce_clip` keeps, per bone
and per channel (position, rotation), only the frames needed so that
interpolating between the kept keys -- linear for positions, slerp for
rotations, as `AnimClip.sample` does -- stays within `pos_tol` metres and
`rot_tol` radians of the original at every original frame. Between two
frames both curves are interpolations of nearby keys, so the frame error
bounds the error at any time (`test_anim_compress` samples off-frame times
to check it).

The greedy pass extends a segment from the last kept key as far as every
frame it skips stays within tolerance; a constant track keeps its two end
keys. `ReducedClip.sample` has `AnimClip.sample`'s time mapping (loop
wrap, clamp) and output layout; per bone it binary-searches the key list.
"""

from std.math import sqrt, asin
from std.sys import size_of
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat, slerp
from .anim import AnimClip


def _angle(a: Quat, b: Quat) -> Real:
    """Rotation angle between two unit quaternions from the chord,
    4 asin(|a -+ b| / 2) (exact near zero, where 2 acos(|a.b|) is not in
    32-bit floats)."""
    var sg = Real(1) if a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w >= 0 else Real(-1)
    var dx = a.x - sg * b.x
    var dy = a.y - sg * b.y
    var dz = a.z - sg * b.z
    var dw = a.w - sg * b.w
    return 4 * asin(min(sqrt(dx * dx + dy * dy + dz * dz + dw * dw) / 2, Real(1)))


struct ReducedClip(Movable):
    var bones: Int
    var frames: Int
    var fps: Real
    var loop: Bool
    var pk_lo: List[Int]  # per bone: start of its position keys in pk_f / pk_v
    var pk_f: List[Int]  # key frame indices
    var pk_v: List[Vec3]
    var rk_lo: List[Int]
    var rk_f: List[Int]
    var rk_q: List[Quat]

    def __init__(out self, bones: Int, frames: Int, fps: Real, loop: Bool):
        self.bones = bones
        self.frames = frames
        self.fps = fps
        self.loop = loop
        self.pk_lo = List[Int]()
        self.pk_f = List[Int]()
        self.pk_v = List[Vec3]()
        self.rk_lo = List[Int]()
        self.rk_f = List[Int]()
        self.rk_q = List[Quat]()

    def duration(self) -> Real:
        if self.frames <= 1:
            return 0
        return Real(self.frames - 1) / self.fps

    def key_count(self) -> Int:
        return len(self.pk_f) + len(self.rk_f)

    def bytes(self) -> Int:
        return len(self.pk_f) * (size_of[Int32]() + 3 * size_of[Real]()) + len(self.rk_f) * (size_of[Int32]() + 4 * size_of[Real]()) + (len(self.pk_lo) + len(self.rk_lo)) * size_of[Int32]()

    def _frame(self, t: Real) -> Real:
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
        return min(u * self.fps, Real(self.frames - 1))

    @staticmethod
    def _seg(keys: List[Int], lo: Int, hi: Int, f: Real) -> Int:
        """Index k in [lo, hi - 2] with keys[k] <= f < keys[k + 1]."""
        var a = lo
        var b = hi - 1
        while b - a > 1:
            var m = (a + b) // 2
            if Real(keys[m]) <= f:
                a = m
            else:
                b = m
        return a

    def sample(self, t: Real, mut out_pos: List[Real], mut out_rot: List[Real]):
        if self.frames == 0:
            return
        var f = self._frame(t)
        for b in range(self.bones):
            var lo = self.pk_lo[b]
            var hi = self.pk_lo[b + 1]
            var p: Vec3
            if hi - lo == 1:
                p = self.pk_v[lo]
            else:
                var k = Self._seg(self.pk_f, lo, hi, f)
                var a = (f - Real(self.pk_f[k])) / Real(self.pk_f[k + 1] - self.pk_f[k])
                p = self.pk_v[k] + (self.pk_v[k + 1] - self.pk_v[k]) * a
            var rlo = self.rk_lo[b]
            var rhi = self.rk_lo[b + 1]
            var q: Quat
            if rhi - rlo == 1:
                q = self.rk_q[rlo]
            else:
                var k = Self._seg(self.rk_f, rlo, rhi, f)
                var a = (f - Real(self.rk_f[k])) / Real(self.rk_f[k + 1] - self.rk_f[k])
                q = slerp(self.rk_q[k], self.rk_q[k + 1], a)
            out_pos[3 * b] = p[0]
            out_pos[3 * b + 1] = p[1]
            out_pos[3 * b + 2] = p[2]
            out_rot[4 * b] = q.x
            out_rot[4 * b + 1] = q.y
            out_rot[4 * b + 2] = q.z
            out_rot[4 * b + 3] = q.w


def _pos_ok(clip: AnimClip, b: Int, a: Int, j: Int, tol: Real) -> Bool:
    """Frames strictly between key a and candidate j within `tol` of the
    line from a to j."""
    var pa = clip.key_pos(a, b)
    var pj = clip.key_pos(j, b)
    for m in range(a + 1, j):
        var u = Real(m - a) / Real(j - a)
        if length(pa + (pj - pa) * u - clip.key_pos(m, b)) > tol:
            return False
    return True


def _rot_ok(clip: AnimClip, b: Int, a: Int, j: Int, tol: Real) -> Bool:
    var qa = clip.key_rot(a, b)
    var qj = clip.key_rot(j, b)
    for m in range(a + 1, j):
        var u = Real(m - a) / Real(j - a)
        if _angle(slerp(qa, qj, u), clip.key_rot(m, b)) > tol:
            return False
    return True


def _next_key(clip: AnimClip, b: Int, a: Int, tol: Real, rot: Bool) -> Int:
    """Furthest frame j > a such that every frame between a and j is within
    `tol` of the interpolation from a to j."""
    var j = a + 1
    while j + 1 < clip.frames:
        var ok = _rot_ok(clip, b, a, j + 1, tol) if rot else _pos_ok(clip, b, a, j + 1, tol)
        if not ok:
            return j
        j += 1
    return j


def reduce_clip(clip: AnimClip, pos_tol: Real, rot_tol: Real) raises -> ReducedClip:
    """Key-reduced copy of `clip` (module docstring)."""
    if not (pos_tol >= 0) or not (rot_tol >= 0):
        raise Error("reduce_clip: tolerances must be >= 0")
    var out = ReducedClip(clip.bones, clip.frames, clip.fps, clip.loop)
    var n = clip.frames
    for b in range(clip.bones):
        out.pk_lo.append(len(out.pk_f))
        out.rk_lo.append(len(out.rk_f))
        if n == 0:
            continue
        out.pk_f.append(0)
        out.pk_v.append(clip.key_pos(0, b))
        var a = 0
        while a < n - 1:
            a = _next_key(clip, b, a, pos_tol, False)
            out.pk_f.append(a)
            out.pk_v.append(clip.key_pos(a, b))
        out.rk_f.append(0)
        out.rk_q.append(clip.key_rot(0, b))
        a = 0
        while a < n - 1:
            a = _next_key(clip, b, a, rot_tol, True)
            out.rk_f.append(a)
            out.rk_q.append(clip.key_rot(a, b))
    out.pk_lo.append(len(out.pk_f))
    out.rk_lo.append(len(out.rk_f))
    return out^


def clip_bytes(clip: AnimClip) -> Int:
    return (len(clip.pos) + len(clip.rot)) * size_of[Real]()
