"""Free-rotation integrator seam: how to advance a tumbling rigid body.

The torque-free Euler equations `ω̇ = I⁻¹(−ω × Iω)` (principal body frame) are
the classic stress test for integrators — the Dzhanibekov / tennis-racket
tumble is chaotic about the intermediate axis, and cheap integrators leak
energy. `SpinIntegrator` is the swap seam; the pose always advances by the
closed-form motor exponential (`galie.exp_screw3`), what varies is the ω
update:

  * `EulerSpin`    — semi-implicit forward Euler (matches `ScrewBody6.step`).
  * `Rk2Spin`      — explicit midpoint (RK2): O(dt²) local energy error.
  * `MidpointSpin` — IMPLICIT midpoint via fixed-point iteration: symplectic
    flavor, near-conserves energy and momentum over long runs. First step
    toward a true Lie-group variational integrator (ROADMAP 1.3 / LGVCI).

Gates: `tests/test_integrator6.mojo` (cross parity + conservation ordering),
`benchmarks/bench_rigid6.mojo` (cost + drift tables).
"""

from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from geometry.galie import exp_screw3
from .screw import screw_velocity
from .rigid6 import Inertia3


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _torque_free(wb: Vec3, inertia: Inertia3) -> Vec3:
    """ω̇ = I⁻¹(−ω × Iω) in the principal body frame."""
    return inertia.apply_inv(-_cross(wb, inertia.apply(wb)))


def _advance(pose: Motor3, wb: Vec3, dt: Real) -> Motor3:
    """Rotate the pose by the body rate ω over dt (closed-form motor exp)."""
    return (
        pose * exp_screw3(screw_velocity(wb, Vec3(0, 0, 0)).scaled(dt))
    ).normalized()


trait SpinIntegrator(Movable, ImplicitlyDeletable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]: ...


struct EulerSpin(SpinIntegrator, Movable, ImplicitlyDeletable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var w2 = wb + _torque_free(wb, inertia) * dt
        return (_advance(pose, w2, dt), w2)


struct Rk2Spin(SpinIntegrator, Movable, ImplicitlyDeletable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var wm = wb + _torque_free(wb, inertia) * (dt * 0.5)
        var w2 = wb + _torque_free(wm, inertia) * dt
        return (_advance(pose, wm, dt), w2)


struct MidpointSpin(SpinIntegrator, Movable, ImplicitlyDeletable):
    """Implicit midpoint `ω½ = ω + f(ω½)·dt/2` by fixed-point iteration
    (converges fast for dt·|ω| ≪ 1), then `ω' = 2ω½ − ω`."""

    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var wh = wb
        for _ in range(4):
            wh = wb + _torque_free(wh, inertia) * (dt * 0.5)
        var w2 = wh * 2 - wb
        return (_advance(pose, wh, dt), w2)


def run_spin[I: SpinIntegrator](
    var pose: Motor3, var wb: Vec3, inertia: Inertia3, dt: Real, steps: Int
) -> Tuple[Motor3, Vec3]:
    for _ in range(steps):
        var r = I.step(pose, wb, inertia, dt)
        pose = r[0]
        wb = r[1]
    return (pose, wb)


def spin_energy(wb: Vec3, inertia: Inertia3) -> Real:
    var l = inertia.apply(wb)
    return (wb[0] * l[0] + wb[1] * l[1] + wb[2] * l[2]) * 0.5


def spin_momentum_world(pose: Motor3, wb: Vec3, inertia: Inertia3) -> Vec3:
    """World-frame angular momentum (exactly conserved by the true flow)."""
    return pose.to_quat_translation()[0].rotate(inertia.apply(wb))
