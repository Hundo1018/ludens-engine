"""Categorical law tests (R4): the algebraic laws behind the engine's seams,
stated and checked as laws rather than ad-hoc parity.

  1. SE(3) as a group — motors form a monoid with inverses: associativity,
     identity, inverse (checked BY ACTION; M and -M are the same motion).
  2. Representation functors — `to_mat4` and `DualQuat.from_motor` preserve
     composition: F(m1·m2) = F(m1)·F(m2). Together with `test_motor_parity`
     (same action pointwise) this makes Motor/DualQuat/Mat4 naturally
     isomorphic representations of SE(3).
  3. Naturality of the representation change — transform-then-convert equals
     convert-then-transform (the commuting square).

`docs/CATEGORY.md` maps the rest of the engine's seams (StorageBackend,
BroadPhase, Scheduler, ...) onto the same picture; the existing parity suites
(`test_backend_parity`, `test_transform`, `test_scheduler_parity`) are its
naturality squares."""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, normalize
from geometry.quat import Quat
from geometry.mat import Mat4, transform_point4
from geometry.motor import Motor3
from geometry.dualquat import DualQuat


def _rand_motor(mut rng: SplitMix64) -> Motor3:
    var axis = normalize(
        Vec3(
            Real(rng.next_f32()) + 0.1,
            Real(rng.next_f32()) + 0.2,
            Real(rng.next_f32()) + 0.3,
        )
    )
    var q = Quat.from_axis_angle(axis, Real(rng.next_f32()) * 3 - 1.5)
    var t = Vec3(
        Real(rng.next_f32()) * 2 - 1,
        Real(rng.next_f32()) * 2 - 1,
        Real(rng.next_f32()) * 2 - 1,
    )
    return Motor3.from_quat_translation(q, t)


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("laws")
    var rng = SplitMix64.seeded(23)
    var p = Vec3(0.4, -0.8, 0.6)

    for _ in range(5):
        var m1 = _rand_motor(rng)
        var m2 = _rand_motor(rng)
        var m3 = _rand_motor(rng)

        # --- group laws (monoid + inverse), by action ---
        _near3(
            s, ((m1 * m2) * m3).apply_point(p), (m1 * (m2 * m3)).apply_point(p),
            "associativity",
        )
        _near3(
            s, (Motor3.identity() * m1).apply_point(p), m1.apply_point(p),
            "left identity",
        )
        _near3(
            s, (m1 * Motor3.identity()).apply_point(p), m1.apply_point(p),
            "right identity",
        )
        _near3(
            s, (m1 * m1.reverse()).apply_point(p), p, "inverse (M·rev(M) = 1)"
        )

        # --- functor law: to_mat4 preserves composition ---
        var lhs = (m1 * m2).to_mat4()
        var rhs = m1.to_mat4() * m2.to_mat4()
        _near3(
            s, transform_point4(lhs, p), transform_point4(rhs, p),
            "to_mat4 functorial",
        )

        # --- functor law: DualQuat.from_motor preserves composition ---
        _near3(
            s,
            DualQuat.from_motor(m1 * m2).transform_point(p),
            (DualQuat.from_motor(m1) * DualQuat.from_motor(m2)).transform_point(p),
            "from_motor functorial",
        )

        # --- naturality square: convert∘act == act∘convert ---
        _near3(
            s,
            DualQuat.from_motor(m1).transform_point(p),
            m1.apply_point(p),
            "naturality (motor→dq)",
        )
        _near3(
            s,
            transform_point4(m1.to_mat4(), p),
            m1.apply_point(p),
            "naturality (motor→mat4)",
        )

    s.finish()
