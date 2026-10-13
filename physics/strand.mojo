"""Hair / fur strands: Follow-The-Leader with bending (ROADMAP 17.57).

A strand is a chain of particles hanging from a root that rides on a bone.
`Rope` (17.41) solves its chain with XPBD distance constraints and has no
bending stiffness; a strand needs the opposite trade: segment length exact
every step (hair does not stretch visibly) at O(n) cost, plus a stiffness
that keeps a ponytail or a whisker in shape. Müller et al. 2012 ("Fast
Simulation of Inextensible Hair and Fur") gives the first: after
integration, place each particle at distance L from its predecessor, root to
tip, and correct the velocity with the next particle's displacement
(`ftl_damping`, 0.9 in the paper) so the sequential pass does not inject
energy.

Per step, for each strand (strands are independent, so the loop order does
not matter and the result is deterministic):
  1. root particle = bone pose * local root offset (kinematic);
  2. v += (gravity + drag (wind - v)) dt, predicted p = x + v dt;
  3. root to tip: bending pulls p_i toward p_{i-1} + L * d_{i-1}, with
     d_{i-1} the previous segment's direction (the bone's rest direction for
     the first segment), by `bend` in [0, 1]; then FTL places p_i at
     distance L from p_{i-1}; then p_i is pushed out of the sphere and
     capsule colliders (strand radius added);
  4. v_i = (p_i - x_i) / dt - ftl_damping * (FTL shift of i+1) / dt.

Bending is a straight-rest model (curly rest shapes are later 17.57 work),
and `bend = 0` gives a free chain. A collision push can lengthen the segment
it moves; `max_stretch` reports the worst segment for tests.
"""

from geometry.vec import Real, Vec3, length, normalize, dot
from geometry.quat import Quat
from .rigid6 import Pose6
from .fields import WindGrid


@fieldwise_init
struct StrandSphere(Copyable, ImplicitlyCopyable, Movable):
    var center: Vec3
    var radius: Real


@fieldwise_init
struct StrandCapsule(Copyable, ImplicitlyCopyable, Movable):
    var a: Vec3
    var b: Vec3
    var radius: Real


struct StrandSet(Movable):
    var x: List[Vec3]
    var v: List[Vec3]
    var start: List[Int]  # first particle of each strand
    var count: List[Int]  # particles per strand (>= 1)
    var seg: List[Real]  # rest segment length per strand
    var bone: List[Int]
    var root_local: List[Vec3]  # root in the bone frame
    var dir_local: List[Vec3]  # rest direction in the bone frame (unit)
    var bend: Real
    var drag: Real
    var ftl_damping: Real
    var radius: Real  # strand radius for collision
    var spheres: List[StrandSphere]
    var capsules: List[StrandCapsule]
    var _shift: List[Vec3]  # scratch: FTL displacement per particle

    def __init__(out self, bend: Real = 0.2, drag: Real = 0.5, ftl_damping: Real = 0.9, radius: Real = 0.002):
        self.x = List[Vec3]()
        self.v = List[Vec3]()
        self.start = List[Int]()
        self.count = List[Int]()
        self.seg = List[Real]()
        self.bone = List[Int]()
        self.root_local = List[Vec3]()
        self.dir_local = List[Vec3]()
        self.bend = bend
        self.drag = drag
        self.ftl_damping = ftl_damping
        self.radius = radius
        self.spheres = List[StrandSphere]()
        self.capsules = List[StrandCapsule]()
        self._shift = List[Vec3]()

    def add(mut self, bone: Int, pose: Pose6, root_local: Vec3, dir_local: Vec3, particles: Int, seg_len: Real) raises -> Int:
        """A strand of `particles` (>= 1) at rest along `dir_local`, rooted at
        `root_local` on bone `bone` whose current pose is `pose`."""
        if particles < 1 or seg_len < 0:
            raise Error("StrandSet.add: need >= 1 particle and a segment length >= 0")
        var d = normalize(dir_local)
        self.start.append(len(self.x))
        self.count.append(particles)
        self.seg.append(seg_len)
        self.bone.append(bone)
        self.root_local.append(root_local)
        self.dir_local.append(d)
        var r = pose.pos + pose.rot.rotate(root_local)
        var dw = pose.rot.rotate(d)
        for k in range(particles):
            self.x.append(r + dw * (Real(k) * seg_len))
            self.v.append(Vec3(0, 0, 0, 0))
            self._shift.append(Vec3(0, 0, 0, 0))
        return len(self.start) - 1

    def strands(self) -> Int:
        return len(self.start)

    def tip(self, s: Int) -> Vec3:
        return self.x[self.start[s] + self.count[s] - 1]

    def _push_out(self, p: Vec3) -> Vec3:
        var q = p
        for ref sp in self.spheres:
            var d = q - sp.center
            var l = length(d)
            var rr = sp.radius + self.radius
            if l < rr and l > 1e-12:
                q = sp.center + d * (rr / l)
        for ref c in self.capsules:
            var ab = c.b - c.a
            var den = dot(ab, ab)
            var t = dot(q - c.a, ab) / den if den > 0 else Real(0)
            t = min(max(t, Real(0)), Real(1))
            var cp = c.a + ab * t
            var d = q - cp
            var l = length(d)
            var rr = c.radius + self.radius
            if l < rr and l > 1e-12:
                q = cp + d * (rr / l)
        return q

    def step(mut self, dt: Real, gravity: Vec3, bones: List[Pose6], wind: Vec3 = Vec3(0, 0, 0, 0)):
        for s in range(len(self.start)):
            self._step_strand(s, dt, gravity, bones, wind)

    def step_wind(mut self, dt: Real, gravity: Vec3, bones: List[Pose6], grid: WindGrid):
        """As `step`, with the wind sampled per particle from a `WindGrid`."""
        for s in range(len(self.start)):
            var p = self.x[self.start[s]]
            self._step_strand(s, dt, gravity, bones, grid.sample(p))

    def _step_strand(mut self, s: Int, dt: Real, gravity: Vec3, bones: List[Pose6], wind: Vec3):
        var o = self.start[s]
        var n = self.count[s]
        var pose = bones[self.bone[s]]
        var root = pose.pos + pose.rot.rotate(self.root_local[s])
        var rdir = pose.rot.rotate(self.dir_local[s])
        var l = self.seg[s]
        var inv_dt = 1 / dt
        self.v[o] = (root - self.x[o]) * inv_dt
        self.x[o] = root
        self._shift[o] = Vec3(0, 0, 0, 0)
        var prev = root
        var prev_dir = rdir
        for k in range(1, n):
            var i = o + k
            var vi = self.v[i] + (gravity + (wind - self.v[i]) * self.drag) * dt
            var p = self.x[i] + vi * dt
            if self.bend > 0:
                p = p + (prev + prev_dir * l - p) * self.bend
            var d = p - prev
            var dl = length(d)
            var dirk = d * (1 / dl) if dl > 1e-12 else prev_dir
            var q = prev + dirk * l
            q = self._push_out(q)
            self._shift[i] = q - p
            self.v[i] = (q - self.x[i]) * inv_dt
            self.x[i] = q
            var seg_dir = q - prev
            var sl = length(seg_dir)
            prev_dir = seg_dir * (1 / sl) if sl > 1e-12 else prev_dir
            prev = q
        # Müller 2012: subtract the next particle's FTL shift
        for k in range(1, n - 1):
            var i = o + k
            self.v[i] = self.v[i] - self._shift[i + 1] * (self.ftl_damping * inv_dt)

    def max_stretch(self) -> Real:
        """Worst |segment length / rest - 1| over all strands."""
        var w = Real(0)
        for s in range(len(self.start)):
            if self.seg[s] <= 0:
                continue
            for k in range(1, self.count[s]):
                var i = self.start[s] + k
                w = max(w, abs(length(self.x[i] - self.x[i - 1]) / self.seg[s] - 1))
        return w

    def teleport(mut self, s: Int, delta: Vec3):
        """Move a whole strand rigidly (velocity kept): pair with a bone
        teleport so the strand does not read the jump as velocity."""
        for k in range(self.count[s]):
            self.x[self.start[s] + k] = self.x[self.start[s] + k] + delta
