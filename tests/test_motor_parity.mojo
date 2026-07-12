"""Motor / Lie / DualQuat parity (G2): three representations of SE(3)/SE(2) —
PGA motors, quaternion+translation, matrices — must move points identically,
and the Lie layer (exp/log/geodesic) must round-trip and reduce to slerp for
pure rotations. Motors are compared BY ACTION on points (M and -M are the same
rigid motion, so coefficient comparison would be too strict)."""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec2, Vec3, normalize
from geometry.quat import Quat, slerp, compose_trs4
from geometry.mat import transform_point4, transform_point3, compose_trs3
from geometry.motor import Motor2, Motor3
from geometry.galie import (
    Screw3, exp_screw3, log_motor3, geodesic3,
    Screw2, exp_screw2, log_motor2, geodesic2,
)
from geometry.dualquat import DualQuat


def _v3(mut rng: SplitMix64, lo: Real = -2, hi: Real = 2) -> Vec3:
    var d = hi - lo
    return Vec3(
        lo + d * Real(rng.next_f32()),
        lo + d * Real(rng.next_f32()),
        lo + d * Real(rng.next_f32()),
    )


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def _near2(mut s: Suite, a: Vec2, b: Vec2, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)


def main() raises:
    var s = Suite("motor_parity")
    var rng = SplitMix64.seeded(7)

    for _ in range(6):
        var axis = normalize(_v3(rng) + Vec3(0.1, 0.2, 0.3))  # avoid zero
        var angle = Real(rng.next_f32()) * 3.0 - 1.5
        var q = Quat.from_axis_angle(axis, angle)
        var t = _v3(rng)
        var p = _v3(rng)

        # --- rotor alone vs quaternion ---
        var mr = Motor3.from_quat(q)
        _near3(s, mr.apply_point(p), q.rotate(p), "rotor == quat")

        # --- translator alone ---
        var mt = Motor3.from_translation(t)
        _near3(s, mt.apply_point(p), p + t, "translator == +t")

        # --- full motor vs quat+t vs matrix ---
        var m = Motor3.from_quat_translation(q, t)
        var want = q.rotate(p) + t
        _near3(s, m.apply_point(p), want, "motor == quat+t")
        var mat = compose_trs4(t, q, Vec3(1, 1, 1))
        _near3(s, m.apply_point(p), transform_point4(mat, p), "motor == mat4")

        # --- composition is a homomorphism onto point action ---
        var q2 = Quat.from_axis_angle(
            normalize(_v3(rng) + Vec3(0.3, 0.1, 0.2)), Real(rng.next_f32())
        )
        var m2 = Motor3.from_quat_translation(q2, _v3(rng))
        _near3(
            s, (m * m2).apply_point(p), m.apply_point(m2.apply_point(p)),
            "compose == nested apply",
        )

        # --- Lie: exp(log(M)) acts like M ---
        var back = exp_screw3(log_motor3(m))
        _near3(s, back.apply_point(p), m.apply_point(p), "exp(log(M)) == M")

        # --- geodesic endpoints ---
        _near3(s, geodesic3(m, m2, 0).apply_point(p), m.apply_point(p), "geo t=0")
        _near3(s, geodesic3(m, m2, 1).apply_point(p), m2.apply_point(p), "geo t=1")

        # --- pure rotation geodesic == slerp ---
        var ma = Motor3.from_quat(q)
        var mb = Motor3.from_quat(q2)
        var mid = geodesic3(ma, mb, 0.5)
        var qs = slerp(q, q2, 0.5)
        _near3(s, mid.apply_point(p), qs.rotate(p), "geodesic == slerp (rot)")

        # --- dual quaternion: same action + isomorphism round-trip ---
        var dq = DualQuat.from_quat_translation(q, t)
        _near3(s, dq.transform_point(p), want, "dq == quat+t")
        _near3(s, dq.to_motor().apply_point(p), want, "dq.to_motor == motor")
        var rt = DualQuat.from_motor(m)
        _near3(s, rt.transform_point(p), want, "from_motor(M) acts like M")
        var dq2 = DualQuat.from_quat_translation(q2, Vec3(0.3, -0.2, 0.5))
        _near3(
            s, (dq * dq2).transform_point(p),
            (dq.to_motor() * dq2.to_motor()).apply_point(p),
            "dq product == motor product",
        )

    # --- screw sanity: geodesic of a pure translation is linear in t ---
    var half = geodesic3(
        Motor3.identity(), Motor3.from_translation(Vec3(2, 0, 0)), 0.5
    )
    _near3(s, half.apply_point(Vec3(0, 0, 0)), Vec3(1, 0, 0), "half translation")

    # ---------------- 2D ----------------
    for _ in range(6):
        var ang = Real(rng.next_f32()) * 3.0 - 1.5
        var t2 = Vec2(Real(rng.next_f32()) * 2 - 1, Real(rng.next_f32()) * 2 - 1)
        var p2 = Vec2(Real(rng.next_f32()) * 2 - 1, Real(rng.next_f32()) * 2 - 1)

        var w2 = Motor2.from_angle_translation(ang, t2)
        var mat3 = compose_trs3(t2, ang, Vec2(1, 1))
        _near2(s, w2.apply_point(p2), transform_point3(mat3, p2), "motor2 == mat3")

        var back2 = exp_screw2(log_motor2(w2))
        _near2(s, back2.apply_point(p2), w2.apply_point(p2), "exp(log(M2)) == M2")

        var w2b = Motor2.from_angle_translation(ang * 0.5, Vec2(0.5, -0.3))
        _near2(s, geodesic2(w2, w2b, 0).apply_point(p2), w2.apply_point(p2), "geo2 t=0")
        _near2(s, geodesic2(w2, w2b, 1).apply_point(p2), w2b.apply_point(p2), "geo2 t=1")

    s.finish()
