"""Conformal versors that the matrix path cannot express: spherical inversion
and the uniform-scale dilator.

Inversion is the interesting one. It is conformal but NOT affine, so no 4x4
matrix on homogeneous coordinates can represent it — unlike rotation,
translation and scale, which the engine already handles with `compose_trs4`.
That makes it the one place where the conformal algebra offers a capability
rather than an alternative spelling, so it is worth a parity gate against the
closed form `c + r²(p−c)/|p−c|²`.

The structural properties checked below are the reason to believe the versor
implementation rather than just the arithmetic: inversion is an involution,
it fixes the sphere it inverts in pointwise, and it exchanges inside for
outside. The dilator is checked for the composition law that motivates it —
`D(a)·D(b) = D(ab)` — since composability is the whole argument for carrying
scale as a versor instead of a matrix factor.
"""

from std.math import sqrt
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, length, normalize
from geometry.cga import (
    Plane3, invert_point, dilate_point, reflect_point, up, down, sphere_dual,
    rotor, translator, dilator, apply_versor,
)
from geometry.quat import Quat, compose_trs4
from geometry.mat import Mat4, transform_point4


def _analytic_inv(c: Vec3, r: Real, p: Vec3) -> Vec3:
    var d = p - c
    var d2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
    return c + d * (r * r / d2)


def main() raises:
    var s = Suite("cga_inversion")
    var rng = SplitMix64.seeded(23)

    var c = Vec3(1.0, 0.5, -0.5)
    var r = Real(2.0)

    # 1. parity vs the closed form over random points
    var worst = Real(0)
    for _ in range(200):
        var p = Vec3(
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
        )
        if length(p - c) < 0.15:  # skip near the pole, where the map blows up
            continue
        var e = length(invert_point(c, r, p) - _analytic_inv(c, r, p))
        if e > worst:
            worst = e
    print("  worst inversion error:", worst)
    s.check(worst < 1e-3, "versor inversion == closed form")

    # 2. involution: inverting twice returns the point
    var worst2 = Real(0)
    for _ in range(100):
        var p = Vec3(
            Real(rng.next_f32()) * 6 - 3,
            Real(rng.next_f32()) * 6 - 3,
            Real(rng.next_f32()) * 6 - 3,
        )
        if length(p - c) < 0.3:
            continue
        var back = invert_point(c, r, invert_point(c, r, p))
        var e = length(back - p)
        if e > worst2:
            worst2 = e
    print("  worst involution error:", worst2)
    s.check(worst2 < 1e-2, "inversion is an involution")

    # 3. the inverting sphere is fixed pointwise
    var worst3 = Real(0)
    for _ in range(60):
        var d = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        var n = length(d)
        if n < 1e-3:
            continue
        var on = c + d * (r / n)  # exactly on the sphere
        var e = length(invert_point(c, r, on) - on)
        if e > worst3:
            worst3 = e
    print("  worst fixed-point error:", worst3)
    s.check(worst3 < 1e-3, "points on the sphere are fixed")

    # 4. inside <-> outside exchange
    var swapped = True
    for k in range(20):
        var d = Vec3(Real(k + 1) * 0.13, Real(k) * 0.07 - 0.5, 0.2)
        var n = length(d)
        if n < 1e-3:
            continue
        var inside = c + d * (r * 0.4 / n)
        var outside = invert_point(c, r, inside)
        if length(inside - c) >= r or length(outside - c) <= r:
            swapped = False
    s.check(swapped, "inside maps outside")

    # 5. dilator: scales about the origin
    var worstd = Real(0)
    for _ in range(100):
        var p = Vec3(
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
        )
        var k = Real(rng.next_f32()) * 3 + 0.25
        var e = length(dilate_point(k, p) - p * k)
        if e > worstd:
            worstd = e
    print("  worst dilation error:", worstd)
    s.check(worstd < 1e-3, "dilator == uniform scale about the origin")

    # 6. composition law D(a)D(b) = D(ab) — the reason to carry scale as a
    #    versor at all
    var worstc = Real(0)
    for _ in range(60):
        var p = Vec3(
            Real(rng.next_f32()) * 3 - 1.5,
            Real(rng.next_f32()) * 3 - 1.5,
            Real(rng.next_f32()) * 3 - 1.5,
        )
        var a = Real(rng.next_f32()) * 2 + 0.3
        var b = Real(rng.next_f32()) * 2 + 0.3
        var two_step = dilate_point(b, dilate_point(a, p))
        var one_step = dilate_point(a * b, p)
        var e = length(two_step - one_step)
        if e > worstc:
            worstc = e
    print("  worst composition error:", worstc)
    s.check(worstc < 1e-2, "D(a) then D(b) == D(a*b)")

    # 7. the same sandwich, a different grade-1 object: reflection still works
    #    (guards against a change to `down`/`up` breaking the shared path)
    var pl = Plane3(Vec3(0, 1, 0), 1.0)
    var refl = reflect_point(pl, Vec3(2, 3, -1))
    s.check(
        abs(Float64(refl[0] - 2)) < 1e-4
        and abs(Float64(refl[1] + 1)) < 1e-4
        and abs(Float64(refl[2] + 1)) < 1e-4,
        "plane reflection still exact through the shared sandwich",
    )

    # ---- 8. a MIXED chain folds into one versor ----
    #      rotate, translate, scale and INVERT composed into a single operator
    #      must equal applying them one at a time. This is the property the
    #      capability benchmark rests on: if the fold were wrong, the benchmark
    #      would be timing a cheaper computation than the reference.
    var R1 = rotor(normalize(Vec3(0.2, 1.0, -0.4)), Real(0.7))
    var T1 = translator(Vec3(0.5, -0.8, 0.3))
    var D1 = dilator(1.4)
    var S1 = sphere_dual(Vec3(0.1, 0.2, -0.1), 1.3)
    var R2 = rotor(normalize(Vec3(1.0, -0.3, 0.6)), Real(-1.1))
    var T2 = translator(Vec3(-0.2, 0.4, 0.9))
    # applied in order R1, T1, D1, S1, R2, T2 -> versor product is reversed
    var V = T2 * R2 * S1 * D1 * T1 * R1

    var worst_chain = Real(0)
    for _ in range(200):
        var p = Vec3(
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
        )
        var seq = apply_versor(R1, p)
        seq = apply_versor(T1, seq)
        seq = apply_versor(D1, seq)
        seq = apply_versor(S1, seq)
        seq = apply_versor(R2, seq)
        seq = apply_versor(T2, seq)
        var folded = apply_versor(V, p)
        var e = length(folded - seq)
        if e > worst_chain:
            worst_chain = e
    print("  worst mixed-chain fold error:", worst_chain)
    s.check(worst_chain < 1e-2, "a rotate/translate/scale/INVERT chain folds into one versor")

    # ---- 9. the inversion is what a matrix chain cannot absorb ----
    #      Without the inversion the same chain IS expressible with matrices;
    #      with it, the matrix path must break and fall back to a closed form.
    #      Matrices are applied ONE AT A TIME in the same order as the versors,
    #      which sidesteps any question about composition order or TRS
    #      convention and isolates the claim being made.
    var Vaff = T2 * R2 * D1 * T1 * R1
    var q1 = Quat.from_axis_angle(normalize(Vec3(0.2, 1.0, -0.4)), Real(0.7))
    var q2 = Quat.from_axis_angle(normalize(Vec3(1.0, -0.3, 0.6)), Real(-1.1))
    var m_r1 = compose_trs4(Vec3(0, 0, 0), q1, Vec3(1, 1, 1))
    var m_t1 = compose_trs4(Vec3(0.5, -0.8, 0.3), Quat.identity(), Vec3(1, 1, 1))
    var m_d1 = compose_trs4(Vec3(0, 0, 0), Quat.identity(), Vec3(1.4, 1.4, 1.4))
    var m_r2 = compose_trs4(Vec3(0, 0, 0), q2, Vec3(1, 1, 1))
    var m_t2 = compose_trs4(Vec3(-0.2, 0.4, 0.9), Quat.identity(), Vec3(1, 1, 1))

    var worst_aff = Real(0)
    for _ in range(200):
        var p = Vec3(
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
        )
        var mp = transform_point4(m_r1, p)
        mp = transform_point4(m_t1, mp)
        mp = transform_point4(m_d1, mp)
        mp = transform_point4(m_r2, mp)
        mp = transform_point4(m_t2, mp)
        var e = length(apply_versor(Vaff, p) - mp)
        if e > worst_aff:
            worst_aff = e
    print("  worst affine-chain versor-vs-mat4 error:", worst_aff)
    s.check(
        worst_aff < 1e-2,
        "without the inversion, one folded versor == the matrix sequence",
    )

    s.finish()
