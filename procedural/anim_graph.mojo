"""Animation graph nodes on top of `procedural.anim` (ROADMAP 17.6).

`procedural.anim` samples clips and cross-fades two of them. A character
needs more than a fade: a speed-driven blend of idle/walk/run whose cycles
stay in step, an eight-way strafe set picked by a 2-D direction, an aiming
upper body layered over whatever the legs do, additive poses (breathing,
flinch), root motion handed to the character controller instead of sliding
the mesh, poses moved between skeletons of different proportions, and --
optionally -- motion matching. Every node here is a function of poses, so
they compose in any order the caller writes.

  `Pose`            flat translation + quaternion per bone (the `anim` layout)
  `BlendSpace1D`    piecewise-linear weights on a sorted parameter axis;
                    every clip sampled at the SAME normalised phase, so a
                    walk (1.0 s) and a run (0.6 s) put their feet down
                    together while blending
  `BlendSpace2D`    freeform cartesian gradient band (Johansen 2009): at a
                    sample point its clip has weight exactly 1, others 0
  `layer`           per-bone mask x alpha, e.g. aim only the spine chain
  `make_additive` / `apply_additive`
                    delta = pose * ref^-1 as a PGA motor quotient; scaled
                    along the motor geodesic, so half a 90-degree additive is
                    exactly 45 degrees, not a linear-blend approximation
  `root_motion` / `strip_root`
                    the root's displacement between two clip times,
                    accumulated across loop wraps, for the controller
  `Skeleton` / `retarget`
                    rotations copied, translations rescaled by bone length
  `MotionDB`        brute-force nearest-frame search over pose features

Blend nodes skip zero-weight inputs outright and return a copy of an input
with weight one, so every node reduces EXACTLY to a single clip at its
boundary weights (the seam parity) and a NaN clip that is weighted out
cannot leak into the result.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import geodesic3
from .anim import AnimClip, blend_bone, BLEND_DLB


struct Pose(Copyable, Movable):
    var bones: Int
    var pos: List[Real]  # 3 per bone
    var rot: List[Real]  # 4 per bone (x, y, z, w)

    def __init__(out self, bones: Int):
        """Identity pose."""
        self.bones = bones
        self.pos = List[Real](length=3 * bones, fill=0)
        self.rot = List[Real](length=4 * bones, fill=0)
        for b in range(bones):
            self.rot[4 * b + 3] = 1

    def p(self, b: Int) -> Vec3:
        return Vec3(self.pos[3 * b], self.pos[3 * b + 1], self.pos[3 * b + 2], 0)

    def q(self, b: Int) -> Quat:
        return Quat(self.rot[4 * b], self.rot[4 * b + 1], self.rot[4 * b + 2], self.rot[4 * b + 3])

    def set(mut self, b: Int, p: Vec3, q: Quat):
        self.pos[3 * b] = p[0]
        self.pos[3 * b + 1] = p[1]
        self.pos[3 * b + 2] = p[2]
        self.rot[4 * b] = q.x
        self.rot[4 * b + 1] = q.y
        self.rot[4 * b + 2] = q.z
        self.rot[4 * b + 3] = q.w

    def motor(self, b: Int) -> Motor3:
        return Motor3.from_quat_translation(self.q(b), self.p(b))

    def set_motor(mut self, b: Int, m: Motor3):
        var qt = m.to_quat_translation()
        self.set(b, qt[1], qt[0])


def sample_phase(clip: AnimClip, phase: Real) -> Pose:
    """The clip at normalised time `phase` in [0, 1] (its whole length)."""
    var out = Pose(clip.bones)
    clip.sample(phase * clip.duration(), out.pos, out.rot)
    return out^


def blend(a: Pose, b: Pose, w: Real, mode: Int = BLEND_DLB) -> Pose:
    """`w` = weight of `b`. Boundary weights return a copy of an input."""
    if w <= 0:
        return a.copy()
    if w >= 1:
        return b.copy()
    var out = Pose(a.bones)
    for i in range(a.bones):
        var r = blend_bone(a.p(i), a.q(i), b.p(i), b.q(i), w, mode)
        out.set(i, r[0], r[1])
    return out^


def blend_n(poses: List[Pose], weights: List[Real], mode: Int = BLEND_DLB) -> Pose:
    """N-way blend as a running pairwise blend: pose k enters with weight
    w_k / (w_0 + ... + w_k). Zero weights are skipped, so a single non-zero
    weight returns that pose exactly."""
    var acc = Pose(poses[0].bones if len(poses) > 0 else 0)
    var total = Real(0)
    for k in range(len(poses)):
        var w = weights[k]
        if w <= 0:
            continue
        if total == 0:
            acc = poses[k].copy()
        else:
            acc = blend(acc, poses[k], w / (total + w), mode)
        total += w
    return acc^


# ------------------------------------------------------------ blend spaces


struct BlendSpace1D(Copyable, Movable):
    var params: List[Real]  # ascending
    var clips: List[Int]

    def __init__(out self):
        self.params = List[Real]()
        self.clips = List[Int]()

    def add(mut self, param: Real, clip: Int):
        var i = 0
        while i < len(self.params) and self.params[i] < param:
            i += 1
        self.params.insert(i, param)
        self.clips.insert(i, clip)

    def weights(self, x: Real) -> List[Real]:
        """Piecewise-linear, clamped at the ends; sums to 1 (or all 0 when
        the space is empty)."""
        var n = len(self.params)
        var w = List[Real](length=n, fill=0)
        if n == 0:
            return w^
        if x <= self.params[0]:
            w[0] = 1
            return w^
        if x >= self.params[n - 1]:
            w[n - 1] = 1
            return w^
        for i in range(n - 1):
            var a = self.params[i]
            var b = self.params[i + 1]
            if x >= a and x <= b:
                var t = (x - a) / (b - a) if b > a else Real(0)
                w[i] = 1 - t
                w[i + 1] = t
                break
        return w^

    def evaluate(self, clips: List[AnimClip], x: Real, phase: Real, mode: Int = BLEND_DLB) -> Pose:
        """Every clip at the same normalised `phase`, blended by `weights(x)`."""
        if len(self.clips) == 0:
            return Pose(clips[0].bones if len(clips) > 0 else 0)
        var w = self.weights(x)
        var poses = List[Pose]()
        for i in range(len(self.clips)):
            if w[i] > 0:
                poses.append(sample_phase(clips[self.clips[i]], phase))
            else:
                poses.append(Pose(clips[self.clips[i]].bones))
        return blend_n(poses, w, mode)


struct BlendSpace2D(Copyable, Movable):
    var xs: List[Real]
    var ys: List[Real]
    var clips: List[Int]

    def __init__(out self):
        self.xs = List[Real]()
        self.ys = List[Real]()
        self.clips = List[Int]()

    def add(mut self, x: Real, y: Real, clip: Int):
        self.xs.append(x)
        self.ys.append(y)
        self.clips.append(clip)

    def weights(self, x: Real, y: Real) -> List[Real]:
        """Gradient band: w_i = min over j of clamp(1 - (p - p_i)·(p_j - p_i)
        / |p_j - p_i|^2, 0, 1), normalised. If every weight is 0 (only
        possible for duplicated sample points) the nearest sample wins."""
        var n = len(self.xs)
        var w = List[Real](length=n, fill=0)
        var sum = Real(0)
        for i in range(n):
            var wi = Real(1)
            for j in range(n):
                if j == i:
                    continue
                var ex = self.xs[j] - self.xs[i]
                var ey = self.ys[j] - self.ys[i]
                var l2 = ex * ex + ey * ey
                if l2 <= 0:
                    continue
                var h = 1 - ((x - self.xs[i]) * ex + (y - self.ys[i]) * ey) / l2
                if h < wi:
                    wi = h
            if wi < 0:
                wi = 0
            w[i] = wi
            sum += wi
        if sum > 0:
            for i in range(n):
                w[i] = w[i] / sum
        elif n > 0:
            var best = 0
            var bd = Real(1e30)
            for i in range(n):
                var d = (x - self.xs[i]) * (x - self.xs[i]) + (y - self.ys[i]) * (y - self.ys[i])
                if d < bd:
                    bd = d
                    best = i
            w[best] = 1
        return w^

    def evaluate(self, clips: List[AnimClip], x: Real, y: Real, phase: Real, mode: Int = BLEND_DLB) -> Pose:
        if len(self.clips) == 0:
            return Pose(clips[0].bones if len(clips) > 0 else 0)
        var w = self.weights(x, y)
        var poses = List[Pose]()
        for i in range(len(self.clips)):
            if w[i] > 0:
                poses.append(sample_phase(clips[self.clips[i]], phase))
            else:
                poses.append(Pose(clips[self.clips[i]].bones))
        return blend_n(poses, w, mode)


# ------------------------------------------------------- layers, additive


def layer(base: Pose, over: Pose, mask: List[Real], alpha: Real, mode: Int = BLEND_DLB) -> Pose:
    """Per-bone override: bone b takes weight alpha * mask[b] of `over`."""
    var out = base.copy()
    for b in range(base.bones):
        var w = alpha * mask[b]
        if w <= 0:
            continue
        if w >= 1:
            out.set(b, over.p(b), over.q(b))
            continue
        var r = blend_bone(base.p(b), base.q(b), over.p(b), over.q(b), w, mode)
        out.set(b, r[0], r[1])
    return out^


def make_additive(pose: Pose, reference: Pose) -> Pose:
    """Per-bone delta motor D = M_pose * ~M_ref (the quotient that turns
    `reference` into `pose`)."""
    var out = Pose(pose.bones)
    for b in range(pose.bones):
        out.set_motor(b, (pose.motor(b) * reference.motor(b).reverse()).normalized())
    return out^


def apply_additive(base: Pose, delta: Pose, weight: Real) -> Pose:
    """M = D^weight * M_base, D^weight taken along the motor geodesic from
    the identity. Weight 0 returns `base`; weight 1 applies D exactly."""
    if weight == 0:
        return base.copy()
    var out = Pose(base.bones)
    for b in range(base.bones):
        var d = delta.motor(b)
        if weight != 1:
            d = geodesic3(Motor3.identity(), d, weight)
        out.set_motor(b, (d * base.motor(b)).normalized())
    return out^


# ------------------------------------------------------------ root motion


def root_motion(clip: AnimClip, root: Int, t0: Real, t1: Real) -> Vec3:
    """Displacement of bone `root` from clip time `t0` to `t1` (t1 >= t0),
    accumulated across loop wraps: whole cycles add the clip's end-to-start
    displacement once each."""
    var a = Pose(clip.bones)
    var b = Pose(clip.bones)
    clip.sample(t0, a.pos, a.rot)
    clip.sample(t1, b.pos, b.rot)
    var d = b.p(root) - a.p(root)
    var dur = clip.duration()
    if clip.loop and dur > 0:
        var cycles = Int(t1 / dur) - Int(t0 / dur)
        if cycles != 0:
            # one full cycle's displacement: last key minus first
            var ends = clip.key_pos(clip.frames - 1, root) - clip.key_pos(0, root)
            d = d + ends * Real(cycles)
    return d


def strip_root(mut pose: Pose, root: Int, keep_vertical: Bool = True):
    """Zero the root's horizontal translation: the controller carries the
    character, the mesh must not slide on top of that."""
    var p = pose.p(root)
    pose.set(root, Vec3(0, p[1] if keep_vertical else 0, 0, 0), pose.q(root))


# --------------------------------------------------------------- retarget


struct Skeleton(Copyable, Movable):
    var parent: List[Int]
    var rest: Pose  # local bind offsets (translations define bone lengths)

    def __init__(out self, var parent: List[Int], var rest: Pose):
        self.parent = parent^
        self.rest = rest^

    def length(self, b: Int) -> Real:
        var p = self.rest.p(b)
        return sqrt(dot(p, p))


def retarget(src_pose: Pose, src: Skeleton, dst: Skeleton) -> Pose:
    """Copy local rotations; rescale each local translation by the target's
    bone length over the source's (the root by the ratio of root heights),
    so a pose made for a short skeleton keeps its shape on a long one."""
    var out = Pose(src_pose.bones)
    for b in range(src_pose.bones):
        var ls = src.length(b)
        var ld = dst.length(b)
        var p: Vec3
        if ls > 1e-9:
            p = src_pose.p(b) * (ld / ls)
        else:
            p = dst.rest.p(b)
        out.set(b, p, src_pose.q(b))
    return out^


# --------------------------------------------------------- motion matching


struct MotionDB(Movable):
    """Frames of a set of clips as feature vectors: root velocity (x, z) and
    the positions of the chosen bones. `query` is a brute-force nearest
    neighbour -- the reference the accelerated searches are measured against."""

    var dim: Int
    var feats: List[Real]
    var clip_of: List[Int]
    var time_of: List[Real]

    def __init__(out self):
        self.dim = 0
        self.feats = List[Real]()
        self.clip_of = List[Int]()
        self.time_of = List[Real]()

    @staticmethod
    def feature(clip: AnimClip, root: Int, bones: List[Int], t: Real) -> List[Real]:
        var h = Real(1) / clip.fps
        var v = root_motion(clip, root, t, t + h) * (1 / h)
        var p = Pose(clip.bones)
        clip.sample(t, p.pos, p.rot)
        var f = List[Real]()
        f.append(v[0])
        f.append(v[2])
        for k in range(len(bones)):
            var q = p.p(bones[k]) - p.p(root)
            f.append(q[0])
            f.append(q[1])
            f.append(q[2])
        return f^

    def add_clip(mut self, clips: List[AnimClip], c: Int, root: Int, bones: List[Int]):
        ref clip = clips[c]
        for fr in range(clip.frames):
            var t = Real(fr) / clip.fps
            var f = Self.feature(clip, root, bones, t)
            self.dim = len(f)
            for k in range(len(f)):
                self.feats.append(f[k])
            self.clip_of.append(c)
            self.time_of.append(t)

    def query(self, f: List[Real]) -> Int:
        """Index of the nearest stored frame (squared distance)."""
        var best = -1
        var bd = Real(1e30)
        var n = len(self.clip_of)
        for i in range(n):
            var d = Real(0)
            for k in range(self.dim):
                var e = self.feats[i * self.dim + k] - f[k]
                d += e * e
            if d < bd:
                bd = d
                best = i
        return best
