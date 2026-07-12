"""Six-DOF rigid-body dynamics: quat+inertia-tensor baseline vs motor/screw.

Two parity-equivalent representations of the same physics (Newton-Euler with
gyroscopic term), compared BY ACTION on points, never by coefficients:

  * `QuatBody6` — the classical path: world-frame ω, inertia rotated
    `I_w = R I_b Rᵀ`, quaternion advanced by the axis-angle exponential.
  * `ScrewBody6` — the GA path: pose is a `Motor3`, velocity is a body-frame
    twist bivector (`Screw3`, half-angle factors folded as in
    `physics/screw.mojo`). The Euler equations run in the principal body frame
    (Lie–Poisson form: `I ω̇ = τ_b − ω × I ω`, `v̇_b = f_b/m − ω × v_b`), and
    the pose advances by the closed-form motor exponential — rotation and
    translation in one uniform screw, no quaternion drift.

Forques and impulses: `step(dt, force, torque)` takes world-frame force/torque
("forque" split into components at the seam boundary); `apply_impulse(j, at)`
converts a world impulse at a world point into velocity deltas through the
inverse inertia — on the screw side that is exactly `ΔV = I⁻¹[r_b × j_b]`
packed back into the twist bivector.

Both bodies share `Inertia3` (mass + principal diagonal). Parity gates live in
`tests/test_rigid6.mojo`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import Screw3, exp_screw3
from .screw import screw_velocity


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


@fieldwise_init
struct Inertia3(Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    """Mass plus principal (body-frame diagonal) rotational inertia."""

    var mass: Real
    var ix: Real
    var iy: Real
    var iz: Real

    @staticmethod
    def box(mass: Real, hx: Real, hy: Real, hz: Real) -> Self:
        # Solid box, half-extents h: I = (m/3)(h_j² + h_k²) per axis.
        var k = mass / 3
        return Self(
            mass,
            k * (hy * hy + hz * hz),
            k * (hx * hx + hz * hz),
            k * (hx * hx + hy * hy),
        )

    @staticmethod
    def sphere(mass: Real, r: Real) -> Self:
        var i = 0.4 * mass * r * r
        return Self(mass, i, i, i)

    def apply(self, w: Vec3) -> Vec3:
        """Body-frame angular momentum L = I ω."""
        return Vec3(w[0] * self.ix, w[1] * self.iy, w[2] * self.iz)

    def apply_inv(self, l: Vec3) -> Vec3:
        return Vec3(l[0] / self.ix, l[1] / self.iy, l[2] / self.iz)


trait Body6(Copyable, Movable, ImplicitlyDeletable):
    """What a 6-DOF contact solver needs from a body, representation-agnostic:
    world-point velocities, impulse response, and the normal-direction
    effective-mass term `n·((I⁻¹(r×n))×r)`. Both representations conform, so
    the solver seam is swappable and parity-testable."""

    def inv_mass(self) -> Real: ...
    def position(self) -> Vec3: ...
    def velocity_at(self, at: Vec3) -> Vec3: ...
    def apply_impulse(mut self, j: Vec3, at: Vec3): ...
    def angular_factor(self, r: Vec3, n: Vec3) -> Real: ...
    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3): ...
    def integrate_pose(mut self, dt: Real): ...
    def act(self, p: Vec3) -> Vec3: ...
    def to_local(self, p: Vec3) -> Vec3: ...
    def omega_world(self) -> Vec3: ...
    def apply_angular_impulse(mut self, l: Vec3): ...
    def angular_only_factor(self, n: Vec3) -> Real: ...
    def linear_velocity(self) -> Vec3: ...
    def halt(mut self): ...


@fieldwise_init
struct QuatBody6(
    Body6, Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable
):
    """Classical 6-DOF body: world-frame linear + angular velocity."""

    var pos: Vec3
    var q: Quat
    var vel: Vec3
    var omega: Vec3  # world frame
    var inertia: Inertia3

    @staticmethod
    def at_rest(pos: Vec3, inertia: Inertia3) -> Self:
        return Self(pos, Quat.identity(), Vec3(0, 0, 0), Vec3(0, 0, 0), inertia)

    def angular_momentum(self) -> Vec3:
        """World-frame L = R I_b Rᵀ ω (conserved when torque-free)."""
        return self.q.rotate(self.inertia.apply(self.q.conjugate().rotate(self.omega)))

    def kinetic_energy(self) -> Real:
        var wb = self.q.conjugate().rotate(self.omega)
        var lb = self.inertia.apply(wb)
        var rot = (wb[0] * lb[0] + wb[1] * lb[1] + wb[2] * lb[2]) * 0.5
        var v2 = self.vel[0] * self.vel[0] + self.vel[1] * self.vel[1] + self.vel[2] * self.vel[2]
        return rot + self.inertia.mass * v2 * 0.5

    def apply_impulse(mut self, j: Vec3, at: Vec3):
        self.vel = self.vel + j / self.inertia.mass
        var dl = _cross(at - self.pos, j)  # world angular impulse
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(dl))
        self.omega = self.omega + self.q.rotate(dwb)

    def inv_mass(self) -> Real:
        return 1 / self.inertia.mass

    def position(self) -> Vec3:
        return self.pos

    def velocity_at(self, at: Vec3) -> Vec3:
        return self.vel + _cross(self.omega, at - self.pos)

    def angular_factor(self, r: Vec3, n: Vec3) -> Real:
        var u = self.q.rotate(
            self.inertia.apply_inv(self.q.conjugate().rotate(_cross(r, n)))
        )
        return dot(n, _cross(u, r))

    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3):
        # Euler equations in the world frame: ω̇ = I_w⁻¹(τ − ω × I_w ω).
        var gyro = torque - _cross(self.omega, self.angular_momentum())
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(gyro))
        self.omega = self.omega + self.q.rotate(dwb) * dt
        self.vel = self.vel + force * (dt / self.inertia.mass)

    def integrate_pose(mut self, dt: Real):
        self.pos = self.pos + self.vel * dt
        # Exact rotation exponential for the step's (now constant) world ω.
        var wlen = sqrt(
            self.omega[0] * self.omega[0]
            + self.omega[1] * self.omega[1]
            + self.omega[2] * self.omega[2]
        )
        if wlen > Real(1e-12):
            var axis = self.omega / wlen
            self.q = (Quat.from_axis_angle(axis, wlen * dt) * self.q).normalized()

    def step(mut self, dt: Real, force: Vec3, torque: Vec3):
        self.integrate_force(dt, force, torque)
        self.integrate_pose(dt)

    def act(self, p: Vec3) -> Vec3:
        """Body-frame point -> world (compare representations BY ACTION)."""
        return self.q.rotate(p) + self.pos

    def to_local(self, p: Vec3) -> Vec3:
        return self.q.conjugate().rotate(p - self.pos)

    def omega_world(self) -> Vec3:
        return self.omega

    def apply_angular_impulse(mut self, l: Vec3):
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(l))
        self.omega = self.omega + self.q.rotate(dwb)

    def angular_only_factor(self, n: Vec3) -> Real:
        var u = self.q.rotate(
            self.inertia.apply_inv(self.q.conjugate().rotate(n))
        )
        return dot(n, u)

    def linear_velocity(self) -> Vec3:
        return self.vel

    def halt(mut self):
        self.vel = Vec3(0, 0, 0)
        self.omega = Vec3(0, 0, 0)


@fieldwise_init
struct ScrewBody6(
    Body6, Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable
):
    """GA 6-DOF body: `Motor3` pose + body-frame twist bivector velocity."""

    var pose: Motor3
    var vel: Screw3  # body twist, half factors folded (see screw_velocity)
    var inertia: Inertia3

    @staticmethod
    def at_rest(pos: Vec3, inertia: Inertia3) -> Self:
        return Self(Motor3.from_translation(pos), Screw3.zero(), inertia)

    def omega_body(self) -> Vec3:
        """Unpack ω from the twist (inverse of `screw_velocity`)."""
        return Vec3(-2 * self.vel.b23, 2 * self.vel.b13, -2 * self.vel.b12)

    def vel_body(self) -> Vec3:
        return Vec3(2 * self.vel.b10, 2 * self.vel.b20, 2 * self.vel.b30)

    def _rotation(self) -> Quat:
        return self.pose.to_quat_translation()[0]

    def position(self) -> Vec3:
        return self.pose.apply_point(Vec3(0, 0, 0))

    def angular_momentum(self) -> Vec3:
        """World-frame L (conserved when torque-free) — for gates only."""
        return self._rotation().rotate(self.inertia.apply(self.omega_body()))

    def kinetic_energy(self) -> Real:
        var wb = self.omega_body()
        var lb = self.inertia.apply(wb)
        var vb = self.vel_body()
        var v2 = vb[0] * vb[0] + vb[1] * vb[1] + vb[2] * vb[2]
        return (wb[0] * lb[0] + wb[1] * lb[1] + wb[2] * lb[2]) * 0.5 + (
            self.inertia.mass * v2 * 0.5
        )

    def apply_impulse(mut self, j: Vec3, at: Vec3):
        """World impulse at a world point -> twist delta via I⁻¹ (screw form)."""
        var q = self._rotation()
        var jb = q.conjugate().rotate(j)
        var rb = q.conjugate().rotate(at - self.position())
        var wb = self.omega_body() + self.inertia.apply_inv(_cross(rb, jb))
        var vb = self.vel_body() + jb / self.inertia.mass
        self.vel = screw_velocity(wb, vb)

    def inv_mass(self) -> Real:
        return 1 / self.inertia.mass

    def velocity_at(self, at: Vec3) -> Vec3:
        var q = self._rotation()
        var rb = q.conjugate().rotate(at - self.position())
        return q.rotate(self.vel_body() + _cross(self.omega_body(), rb))

    def angular_factor(self, r: Vec3, n: Vec3) -> Real:
        var q = self._rotation()
        var rb = q.conjugate().rotate(r)
        var nb = q.conjugate().rotate(n)
        var u = self.inertia.apply_inv(_cross(rb, nb))
        return dot(nb, _cross(u, rb))

    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3):
        # Lie–Poisson Euler equations in the principal body frame.
        var q = self._rotation()
        var wb = self.omega_body()
        var vb = self.vel_body()
        var tb = q.conjugate().rotate(torque)
        var fb = q.conjugate().rotate(force)
        var gyro = tb - _cross(wb, self.inertia.apply(wb))
        wb = wb + self.inertia.apply_inv(gyro) * dt
        # Body-frame transport of the linear velocity: v̇_b = f_b/m − ω × v_b.
        vb = vb + (fb / self.inertia.mass - _cross(wb, vb)) * dt
        self.vel = screw_velocity(wb, vb)

    def integrate_pose(mut self, dt: Real):
        # One uniform screw per step: closed-form motor exponential.
        self.pose = (self.pose * exp_screw3(self.vel.scaled(dt))).normalized()

    def step(mut self, dt: Real, force: Vec3, torque: Vec3):
        self.integrate_force(dt, force, torque)
        self.integrate_pose(dt)

    def act(self, p: Vec3) -> Vec3:
        return self.pose.apply_point(p)

    def to_local(self, p: Vec3) -> Vec3:
        return self.pose.reverse().apply_point(p)

    def omega_world(self) -> Vec3:
        return self._rotation().rotate(self.omega_body())

    def apply_angular_impulse(mut self, l: Vec3):
        var q = self._rotation()
        var wb = self.omega_body() + self.inertia.apply_inv(
            q.conjugate().rotate(l)
        )
        self.vel = screw_velocity(wb, self.vel_body())

    def angular_only_factor(self, n: Vec3) -> Real:
        var q = self._rotation()
        var nb = q.conjugate().rotate(n)
        return dot(nb, self.inertia.apply_inv(nb))

    def linear_velocity(self) -> Vec3:
        return self._rotation().rotate(self.vel_body())

    def halt(mut self):
        self.vel = Screw3.zero()
