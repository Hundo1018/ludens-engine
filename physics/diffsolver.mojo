"""Differentiable, batchable rigid contact solver -- the differentiable subset
of `ContactScene6` (ROADMAP 17.20) and its many-worlds layout (17.18).

`ContactScene6` is written in concrete `Vec3`/`Real`, over a `Body6` trait
whose every method returns those; threading a coefficient ring through it
would mean re-typing the body representations, the collider set and every
narrowphase routine. This module instead re-states the SAME per-frame
algorithm -- speculative contact collection with the warm-start cache rule,
then per substep: gravity, warm start, soft (Box2D v3 / Solver2D) normal +
Coulomb friction sweeps, pose integration, a bias-free relax sweep -- for the
subset of scenes made of dynamic SPHERES and static PLANES, over any
`SolverField` scalar `F`:

  * `RealF`                 one world, the production arithmetic;
  * `DualReal`, `DualBatch` forward-mode gradient (1 or 4 directions);
  * `RevReal`               reverse mode (whole gradient in one sweep);
  * `BatchReal[W]`          W worlds stepped together, one per SIMD lane.

Differentiable subset boundary (stated here per testing law v3 §1):
  - shapes: dynamic spheres (isotropic inertia 2/5 m r^2), static planes;
  - constraints: contacts with Coulomb friction; no joints, no restitution
    pass (e = 0), no sleep, no CCD, no soft bodies;
  - orientation integrates to first order (q += h/2 w q, renormalised) where
    `QuatBody6` uses the exact axis-angle exponential -- the two agree to
    O(h^2) per substep, and orientation only enters through the rotating
    contact anchors;
  - a plane stands in for the top face of a static box: contact point, depth
    and speculative margin are the ones `sphere_box_manifold` produces for a
    sphere centre above the face, so a scene of spheres on a large static box
    in `ContactScene6` is the parity partner (`tests/test_diffsolver.mojo`).

Every branch of the solve is written branch-free with `SolverField.positive`
(1 where > 0, else 0, zero derivative): a contact's presence, the
speculative-vs-soft bias choice, the accumulated-impulse clamp and the
friction cone. So the derivative convention at a contact switch is the
subgradient that treats the switch as frozen -- the same "one contact
schedule" caveat `physics/diffrigid.mojo` measures -- and lanes of a batch
that take different branches still run the same instruction stream.
Every pair is carried every frame with an activity indicator `on`; an
inactive pair's impulses are multiplied by 0 and its accumulators reset,
which is exactly `ContactScene6`'s cache rule (a pair absent last frame
starts from zero).
"""

from std.math import sqrt
from max.algorithm import parallelize
from geometry.vec import Real, Vec3
from geometry.field import SolverField, RealF, BatchReal
from collision.collider_set import SPEC_BASE


# ------------------------------------------------------------- 3-vectors


@fieldwise_init
struct V3[F: SolverField](Copyable, ImplicitlyCopyable, Movable):
    var x: Self.F
    var y: Self.F
    var z: Self.F

    @staticmethod
    def zero() -> Self:
        return Self(Self.F.zero(), Self.F.zero(), Self.F.zero())

    @staticmethod
    def const(v: Vec3) -> Self:
        return Self(Self.F.const(v[0]), Self.F.const(v[1]), Self.F.const(v[2]))

    def __add__(self, o: Self) -> Self:
        return Self(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: Self) -> Self:
        return Self(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s: Self.F) -> Self:
        return Self(self.x * s, self.y * s, self.z * s)

    def dot(self, o: Self) -> Self.F:
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o: Self) -> Self:
        return Self(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )


def relu[F: SolverField](x: F) -> F:
    """Branch-free max(x, 0)."""
    return x * x.positive()


def clamp_sym[F: SolverField](x: F, cap: F) -> F:
    """Clamp `x` to [-cap, cap] (cap >= 0), branch-free."""
    return x - relu(x - cap) + relu(F.zero() - cap - x)


def length[F: SolverField](v: V3[F]) -> F:
    return v.dot(v).root()


def tangent_basis_f[F: SolverField](n: V3[F]) -> Tuple[V3[F], V3[F]]:
    """`geometry.vec.tangent_basis` branch-free: seed (0,1,0) when |n.x| >
    0.9 else (1,0,0), then t1 = seed x n normalised, t2 = n x t1."""
    var s = (n.x * n.x - F.const(0.81)).positive()
    var one = F.const(1)
    var seed = V3[F](one - s, s, F.zero())
    var t1 = seed.cross(n)
    var l2 = t1.dot(t1)
    var floor = F.const(1e-12)
    l2 = l2 + relu(floor - l2)
    t1 = t1 * l2.root().recip()
    return (t1, n.cross(t1))


# ------------------------------------------------------------ quaternion


@fieldwise_init
struct QF[F: SolverField](Copyable, ImplicitlyCopyable, Movable):
    var x: Self.F
    var y: Self.F
    var z: Self.F
    var w: Self.F

    @staticmethod
    def identity() -> Self:
        return Self(Self.F.zero(), Self.F.zero(), Self.F.zero(), Self.F.const(1))

    def conjugate(self) -> Self:
        var z = Self.F.zero()
        return Self(z - self.x, z - self.y, z - self.z, self.w)

    def rotate(self, v: V3[Self.F]) -> V3[Self.F]:
        """Same formula as `geometry.quat.Quat.rotate`."""
        var qv = V3[Self.F](self.x, self.y, self.z)
        var t = qv.cross(v) * Self.F.const(2)
        return v + t * self.w + qv.cross(t)

    def integrate(self, w: V3[Self.F], h: Self.F) -> Self:
        """First-order exponential: q + (h/2)·(w,0)·q, renormalised."""
        var hh = h * Self.F.const(0.5)
        var dx = (w.x * self.w + w.y * self.z - w.z * self.y) * hh
        var dy = (w.y * self.w + w.z * self.x - w.x * self.z) * hh
        var dz = (w.z * self.w + w.x * self.y - w.y * self.x) * hh
        var dw = (Self.F.zero() - w.x * self.x - w.y * self.y - w.z * self.z) * hh
        var q = Self(self.x + dx, self.y + dy, self.z + dz, self.w + dw)
        var inv = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).root().recip()
        return Self(q.x * inv, q.y * inv, q.z * inv, q.w * inv)


# ---------------------------------------------------------------- bodies


@fieldwise_init
struct DiffSphere[F: SolverField](Copyable, ImplicitlyCopyable, Movable):
    var pos: V3[Self.F]
    var vel: V3[Self.F]
    var omega: V3[Self.F]
    var q: QF[Self.F]
    var mass: Self.F
    var radius: Self.F

    def inv_mass(self) -> Self.F:
        return self.mass.recip()

    def inv_inertia(self) -> Self.F:
        # solid sphere: I = 2/5 m r^2
        return (Self.F.const(0.4) * self.mass * self.radius * self.radius).recip()

    def velocity_at(self, p: V3[Self.F]) -> V3[Self.F]:
        return self.vel + self.omega.cross(p - self.pos)

    def factor(self, r: V3[Self.F], n: V3[Self.F]) -> Self.F:
        """Effective inverse mass inv_mass + n·((I⁻¹ (r×n)) × r) --
        `Body6.inv_mass() + angular_factor(r, n)` for an isotropic body."""
        var u = r.cross(n) * self.inv_inertia()
        return self.inv_mass() + n.dot(u.cross(r))

    def apply_impulse(mut self, j: V3[Self.F], at: V3[Self.F]):
        self.vel = self.vel + j * self.inv_mass()
        self.omega = self.omega + (at - self.pos).cross(j) * self.inv_inertia()

    def act(self, local: V3[Self.F]) -> V3[Self.F]:
        return self.q.rotate(local) + self.pos

    def to_local(self, p: V3[Self.F]) -> V3[Self.F]:
        return self.q.conjugate().rotate(p - self.pos)


@fieldwise_init
struct DiffPlane(Copyable, ImplicitlyCopyable, Movable):
    """Static half-space {x : n·x <= offset}; `n` (unit) points out of the
    solid. Stands in for a static box's top face (module docstring)."""

    var n: Vec3
    var offset: Real


@fieldwise_init
struct DiffContact[F: SolverField](Copyable, ImplicitlyCopyable, Movable):
    """One candidate pair, carried every frame. `b >= 0` is a sphere index;
    `b < 0` is plane `-b - 1`. Normal points a -> b."""

    var a: Int
    var b: Int
    var n: V3[Self.F]
    var t1: V3[Self.F]
    var t2: V3[Self.F]
    var ra: V3[Self.F]  # anchor, a's body frame
    var rb: V3[Self.F]  # anchor, b's body frame (world point for a plane)
    var depth: Self.F
    var on: Self.F  # 1 = in contact (incl. speculative margin), 0 = absent
    var acc: Self.F
    var acc_t1: Self.F
    var acc_t2: Self.F


# ----------------------------------------------------------------- world


struct SphereWorld[F: SolverField](Movable):
    """Spheres + planes under gravity, stepped with the `ContactScene6`
    soft-step contact solve (module docstring has the subset boundary)."""

    var bodies: List[DiffSphere[Self.F]]
    var planes: List[DiffPlane]
    var contacts: List[DiffContact[Self.F]]
    var gravity: V3[Self.F]
    var mu: Self.F
    var substeps: Int
    var iters: Int
    var hertz: Real
    var zeta: Real

    def __init__(out self):
        self.bodies = List[DiffSphere[Self.F]]()
        self.planes = List[DiffPlane]()
        self.contacts = List[DiffContact[Self.F]]()
        self.gravity = V3[Self.F].const(Vec3(0, -9.8, 0, 0))
        self.mu = Self.F.const(0.5)
        self.substeps = 4
        self.iters = 4
        self.hertz = 30
        self.zeta = 10

    def add_sphere(
        mut self, pos: V3[Self.F], vel: V3[Self.F], radius: Self.F, mass: Self.F
    ) -> Int:
        self.bodies.append(
            DiffSphere[Self.F](
                pos, vel, V3[Self.F].zero(), QF[Self.F].identity(), mass, radius
            )
        )
        self._rebuild_pairs()
        return len(self.bodies) - 1

    def add_plane(mut self, n: Vec3, offset: Real) -> Int:
        self.planes.append(DiffPlane(n, offset))
        self._rebuild_pairs()
        return len(self.planes) - 1

    def _blank(self, a: Int, b: Int) -> DiffContact[Self.F]:
        var z = V3[Self.F].zero()
        var f0 = Self.F.zero()
        return DiffContact[Self.F](a, b, z, z, z, z, z, f0, f0, f0, f0, f0)

    def _rebuild_pairs(mut self):
        """Every candidate pair in `ContactScene6`'s visiting order for a
        scene whose static ground is body 0: sphere-vs-plane for each sphere,
        then sphere pairs (i, j), i < j."""
        self.contacts = List[DiffContact[Self.F]]()
        for i in range(len(self.bodies)):
            for k in range(len(self.planes)):
                self.contacts.append(self._blank(i, -k - 1))
        for i in range(len(self.bodies)):
            for j in range(i + 1, len(self.bodies)):
                self.contacts.append(self._blank(i, j))

    # ------------------------------------------------------------ collect

    def _collect(mut self, dt: Real):
        """Per-frame geometry: normal, depth, anchors, tangents, and the
        presence indicator `on` (depth > -speculative margin, the margin
        `collision.contact_gen.speculative_margin` uses with spec_dt = dt).
        Accumulators survive only for pairs present -- `acc *= on`."""
        var half = Self.F.const(0.5)
        var dtf = Self.F.const(dt)
        for c in range(len(self.contacts)):
            var ct = self.contacts[c]
            ref A = self.bodies[ct.a]
            var n: V3[Self.F]
            var depth: Self.F
            var point: V3[Self.F]
            var margin: Self.F
            if ct.b < 0:
                var pl = self.planes[-ct.b - 1]
                var np = V3[Self.F].const(pl.n)
                margin = Self.F.const(SPEC_BASE) + length(A.vel) * dtf
                var dist = np.dot(A.pos) - Self.F.const(pl.offset)
                depth = A.radius - dist
                n = V3[Self.F].zero() - np
                # closest point on the margin/2-inflated face (sphere_box)
                point = A.pos - np * (dist - margin * half)
                ct.rb = point
            else:
                ref Bb = self.bodies[ct.b]
                margin = (
                    Self.F.const(SPEC_BASE) + (length(A.vel) + length(Bb.vel)) * dtf
                )
                var d = Bb.pos - A.pos
                var d2 = d.dot(d)
                var floor = Self.F.const(1e-12)
                var dist = (d2 + relu(floor - d2)).root()
                n = d * dist.recip()
                var ra_i = A.radius + margin * half
                var rsum = A.radius + Bb.radius + margin
                depth = A.radius + Bb.radius - dist
                point = A.pos + n * (ra_i - (rsum - dist) * half)
                ct.rb = Bb.to_local(point)
            ct.n = n
            var tb = tangent_basis_f(n)
            ct.t1 = tb[0]
            ct.t2 = tb[1]
            ct.ra = A.to_local(point)
            ct.depth = depth
            ct.on = (depth + margin).positive()
            ct.acc = ct.acc * ct.on
            ct.acc_t1 = ct.acc_t1 * ct.on
            ct.acc_t2 = ct.acc_t2 * ct.on
            self.contacts[c] = ct

    # -------------------------------------------------------------- solve

    def _anchor_b(self, ct: DiffContact[Self.F]) -> V3[Self.F]:
        if ct.b < 0:
            return ct.rb
        return self.bodies[ct.b].act(ct.rb)

    def _vel_b(self, ct: DiffContact[Self.F], p: V3[Self.F]) -> V3[Self.F]:
        if ct.b < 0:
            return V3[Self.F].zero()
        return self.bodies[ct.b].velocity_at(p)

    def _k_b(self, ct: DiffContact[Self.F], p: V3[Self.F], d: V3[Self.F]) -> Self.F:
        if ct.b < 0:
            return Self.F.zero()
        ref B = self.bodies[ct.b]
        return B.factor(p - B.pos, d)

    def _push(mut self, ct: DiffContact[Self.F], j: V3[Self.F], pa: V3[Self.F], pb: V3[Self.F]):
        self.bodies[ct.a].apply_impulse(V3[Self.F].zero() - j, pa)
        if ct.b >= 0:
            self.bodies[ct.b].apply_impulse(j, pb)

    def _warm_start(mut self):
        for c in range(len(self.contacts)):
            var ct = self.contacts[c]
            var j = ct.n * ct.acc + ct.t1 * ct.acc_t1 + ct.t2 * ct.acc_t2
            var pa = self.bodies[ct.a].act(ct.ra)
            var pb = self._anchor_b(ct)
            self._push(ct, j, pa, pb)

    def _solve_contact(
        mut self,
        c: Int,
        h: Self.F,
        bias_rate: Self.F,
        mass_scale: Self.F,
        impulse_scale: Self.F,
        use_bias: Self.F,  # 1 or 0
    ):
        """`physics.contact6.solve_contact`, one point, branch-free."""
        var ct = self.contacts[c]
        var one = Self.F.const(1)
        var zero = Self.F.zero()
        var n = ct.n
        var pwa = self.bodies[ct.a].act(ct.ra)
        var pwb = self._anchor_b(ct)
        var d = ct.depth - (pwb - pwa).dot(n)
        var va = self.bodies[ct.a].velocity_at(pwa)
        var ka = self.bodies[ct.a].factor(pwa - self.bodies[ct.a].pos, n)
        var vb = self._vel_b(ct, pwb)
        var kb = self._k_b(ct, pwb, n)
        var denom = ka + kb
        var vn = (vb - va).dot(n)
        # d < 0: speculative (bias = -d/h, ms = 1, isc = 0); else soft if
        # use_bias (bias = max(-rate·d, -4), ms, isc) else rigid relax.
        var spec = (zero - d).positive()
        var soft = (one - spec) * use_bias
        var bias = spec * (zero - d) * h.recip() + soft * (
            relu(Self.F.const(4) - bias_rate * d) - Self.F.const(4)
        )
        var ms = one + soft * (mass_scale - one)
        var isc = soft * impulse_scale
        var raw = zero - ms * (vn + bias) * denom.recip() - isc * ct.acc
        var new_acc = ct.acc + ct.on * (relu(ct.acc + raw) - ct.acc)
        var dl = new_acc - ct.acc
        ct.acc = new_acc
        self._push(ct, n * dl, pwa, pwb)
        # Coulomb friction, tangent impulses clamped to mu·lambda_n
        var cap = self.mu * ct.acc
        for ti in range(2):
            var t = ct.t1 if ti == 0 else ct.t2
            var vat = self.bodies[ct.a].velocity_at(pwa)
            var kat = self.bodies[ct.a].factor(pwa - self.bodies[ct.a].pos, t)
            var vbt = self._vel_b(ct, pwb)
            var kbt = self._k_b(ct, pwb, t)
            var vt = (vbt - vat).dot(t)
            var acc_t = ct.acc_t1 if ti == 0 else ct.acc_t2
            var new_t = clamp_sym(acc_t - vt * (kat + kbt).recip(), cap)
            new_t = acc_t + ct.on * (new_t - acc_t)
            var dtl = new_t - acc_t
            if ti == 0:
                ct.acc_t1 = new_t
            else:
                ct.acc_t2 = new_t
            self._push(ct, t * dtl, pwa, pwb)
        self.contacts[c] = ct

    def step(mut self, dt: Real):
        """One frame: collect, then `substeps` soft substeps (the serial,
        uncoloured `ContactScene6.step` order)."""
        var hr = dt / Real(self.substeps)
        var omega = Real(6.283185307179586) * self.hertz
        var cc = hr * omega * (2 * self.zeta + hr * omega)
        var h = Self.F.const(hr)
        var bias_rate = Self.F.const(omega / (2 * self.zeta + hr * omega))
        var mass_scale = Self.F.const(cc / (1 + cc))
        var impulse_scale = Self.F.const(1 / (1 + cc))
        var one = Self.F.const(1)
        var zero = Self.F.zero()
        self._collect(dt)
        for _ in range(self.substeps):
            for i in range(len(self.bodies)):
                self.bodies[i].vel = self.bodies[i].vel + self.gravity * h
            self._warm_start()
            for _ in range(self.iters):
                for c in range(len(self.contacts)):
                    self._solve_contact(c, h, bias_rate, mass_scale, impulse_scale, one)
            for i in range(len(self.bodies)):
                ref b = self.bodies[i]
                b.pos = b.pos + b.vel * h
                b.q = b.q.integrate(b.omega, h)
            for _ in range(2):
                for c in range(len(self.contacts)):
                    self._solve_contact(c, h, bias_rate, one, zero, zero)


def step_worlds_parallel[W: Int](
    mut worlds: List[SphereWorld[BatchReal[W]]], dt: Real, frames: Int, workers: Int = 0
):
    """Step independent batched worlds (each `W` lanes wide) on worker
    threads -- the outer env dimension over cores, the inner one over SIMD
    lanes (ROADMAP 17.18). Worlds share nothing, so the result is
    worker-count-invariant."""

    def work(k: Int) {mut worlds, imm dt, imm frames}:
        for _ in range(frames):
            worlds[k].step(dt)

    if workers > 0:
        parallelize(work, len(worlds), workers)
    else:
        parallelize(work, len(worlds))
