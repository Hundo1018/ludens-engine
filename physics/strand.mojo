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

The shift used in 4 is measured from the inertial prediction x + v dt, not
from the predicted p that already holds gravity, drag and bending. Müller's
form (from p) has a nonzero fixed point at rest: a hanging chain's FTL
shift is the gravity drop g dt^2 every step, so v settles at
ftl_damping / (1 - ftl_damping) g dt along the chain (0.73 m/s at 0.9,
1/120 s) and a bent strand on a still head never stops (measured: 2 m/s
after 10 s). From x + v dt the fixed point is v = 0 (17.57, test_strand).
That bias was also most of the scheme's dissipation (FTL alone injects
energy: with ftl_damping 0 a free chain reaches 10 m/s), so a fifth pass
damps each particle's velocity relative to its predecessor at
`inner_damping` per second (default 20, about critical for 16 x 5 cm;
rigid motion and rest are untouched):
  5. root to tip: v_i -= (v_i - v_{i-1}) min(inner_damping dt, 1).

Bending pulls toward the rest shape: straight along `dir_local` for `add`;
`add_curl` gives a strand a curled rest shape (17.57), each segment turned
by a fixed angle about an axis fixed in the bone frame. Its bending target
is the segment's rest direction carried by the minimal rotation that takes
the previous segment's rest direction onto its current direction (no twist
is tracked: a planar curl keeps its plane only through the bone). Curled
strands step through `_step_shaped`; straight ones keep `_step_strand`
untouched. `bend = 0` gives a free chain. A collision push can lengthen the segment
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
    var shaped: List[Bool]  # per strand: rest shape from rest_dir (add_curl)
    var rest_dir: List[Vec3]  # per particle: rest direction of the segment ending there (bone frame)
    var bend: Real
    var drag: Real
    var ftl_damping: Real
    var inner_damping: Real  # 1/s: velocity relative to the predecessor decays at this rate
    var radius: Real  # strand radius for collision
    var spheres: List[StrandSphere]
    var capsules: List[StrandCapsule]
    var _shift: List[Vec3]  # scratch: FTL displacement per particle

    def __init__(out self, bend: Real = 0.2, drag: Real = 0.5, ftl_damping: Real = 0.9, radius: Real = 0.002, inner_damping: Real = 20.0):
        self.x = List[Vec3]()
        self.v = List[Vec3]()
        self.start = List[Int]()
        self.count = List[Int]()
        self.seg = List[Real]()
        self.bone = List[Int]()
        self.root_local = List[Vec3]()
        self.dir_local = List[Vec3]()
        self.shaped = List[Bool]()
        self.rest_dir = List[Vec3]()
        self.bend = bend
        self.drag = drag
        self.ftl_damping = ftl_damping
        self.inner_damping = inner_damping
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
        self.shaped.append(False)
        var r = pose.pos + pose.rot.rotate(root_local)
        var dw = pose.rot.rotate(d)
        for k in range(particles):
            self.x.append(r + dw * (Real(k) * seg_len))
            self.v.append(Vec3(0, 0, 0, 0))
            self._shift.append(Vec3(0, 0, 0, 0))
            self.rest_dir.append(d)
        return len(self.start) - 1

    def add_curl(
        mut self, bone: Int, pose: Pose6, root_local: Vec3, dir_local: Vec3, axis_local: Vec3,
        angle: Real, particles: Int, seg_len: Real,
    ) raises -> Int:
        """A strand whose rest shape curls: segment k's rest direction is
        `dir_local` turned by k * `angle` (radians) about `axis_local` (bone
        frame). Placed at rest; `angle = 0` is `add`'s straight strand."""
        var s = self.add(bone, pose, root_local, dir_local, particles, seg_len)
        var o = self.start[s]
        var d = self.dir_local[s]
        var ax = normalize(axis_local)
        var q = Quat.from_axis_angle(ax, angle)
        var r = pose.pos + pose.rot.rotate(root_local)
        var p = r
        var dk = d
        for k in range(1, particles):
            if k > 1:
                dk = q.rotate(dk)
            self.rest_dir[o + k] = dk
            p = p + pose.rot.rotate(dk) * seg_len
            self.x[o + k] = p
        self.shaped[s] = angle != 0
        return s

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
            if self.shaped[s]:
                self._step_shaped(s, dt, gravity, bones, wind)
            else:
                self._step_strand(s, dt, gravity, bones, wind)

    def step_wind(mut self, dt: Real, gravity: Vec3, bones: List[Pose6], grid: WindGrid):
        """As `step`, with the wind sampled per particle from a `WindGrid`."""
        for s in range(len(self.start)):
            var p = self.x[self.start[s]]
            if self.shaped[s]:
                self._step_shaped(s, dt, gravity, bones, grid.sample(p))
            else:
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
            var p0 = self.x[i] + self.v[i] * dt  # inertial prediction
            var vi = self.v[i] + (gravity + (wind - self.v[i]) * self.drag) * dt
            var p = self.x[i] + vi * dt
            if self.bend > 0:
                p = p + (prev + prev_dir * l - p) * self.bend
            var d = p - prev
            var dl = length(d)
            var dirk = d * (1 / dl) if dl > 1e-12 else prev_dir
            var q = prev + dirk * l
            q = self._push_out(q)
            self._shift[i] = q - p0
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
        # internal damping: relative velocity to the predecessor, root to tip
        # (rigid motion and rest are untouched)
        var kd = min(self.inner_damping * dt, Real(1))
        if kd > 0:
            for k in range(1, n):
                var i = o + k
                self.v[i] = self.v[i] - (self.v[i] - self.v[i - 1]) * kd

    def _step_shaped(mut self, s: Int, dt: Real, gravity: Vec3, bones: List[Pose6], wind: Vec3):
        """`_step_strand` with the curled rest shape as the bending target
        (module note)."""
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
            var p0 = self.x[i] + self.v[i] * dt  # inertial prediction
            var vi = self.v[i] + (gravity + (wind - self.v[i]) * self.drag) * dt
            var p = self.x[i] + vi * dt
            if self.bend > 0:
                # rest direction of this segment, carried by the minimal
                # rotation from the previous segment's rest direction (in
                # the world) onto its current direction prev_dir
                var a = pose.rot.rotate(self.rest_dir[i - 1] if k > 1 else self.dir_local[s])
                var w = pose.rot.rotate(self.rest_dir[i])
                var c = dot(a, prev_dir)
                var u = Vec3(a[1] * prev_dir[2] - a[2] * prev_dir[1], a[2] * prev_dir[0] - a[0] * prev_dir[2], a[0] * prev_dir[1] - a[1] * prev_dir[0], 0)
                var uw = Vec3(u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0], 0)
                var target = w * c + uw + u * (dot(u, w) / (1 + c)) if c > -0.999 else w
                p = p + (prev + target * l - p) * self.bend
            var d = p - prev
            var dl = length(d)
            var dirk = d * (1 / dl) if dl > 1e-12 else prev_dir
            var q = prev + dirk * l
            q = self._push_out(q)
            self._shift[i] = q - p0
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
        # internal damping: relative velocity to the predecessor, root to tip
        # (rigid motion and rest are untouched)
        var kd = min(self.inner_damping * dt, Real(1))
        if kd > 0:
            for k in range(1, n):
                var i = o + k
                self.v[i] = self.v[i] - (self.v[i] - self.v[i - 1]) * kd

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
