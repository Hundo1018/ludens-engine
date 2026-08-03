"""Conformal geometric algebra (CGA) geometry over Cl(4,1) — `CGA3`.

Promoted from `experiments/exp_cga_meet.mojo` after its meet decisions matched
euclidean geometry 4/4. Points lift onto the null cone
(`up(p) = p + ½|p|²n∞ + n₀`); spheres are grade-1 vectors
(`S = up(c) − ½r²n∞`), and incidence is algebra:

  up(a)·up(b) = −½|a−b|²          (distance is an inner product)
  P·S = 0 / >0 / <0               (on / inside / outside a sphere)
  (S₁∧S₂)² < 0                    (dual pencil: real intersection circle)

so a sphere-sphere test needs no case analysis — squared distance and overlap
both fall out of scalar products. `sphere_dist_sq` inverts
S₁·S₂ = ½(r₁² + r₂² − d²).
"""

from .vec import Real, Vec3
from .multivector import CGA3

# basis: e1,e2,e3 euclidean (+1); e4 (+1), e5 (-1) — the conformal pair
comptime _E4 = 1 << 3
comptime _E5 = 1 << 4


def n_inf() -> CGA3:
    """The point at infinity: n∞ = e4 + e5 (null: n∞² = 0)."""
    return CGA3.basis(_E4) + CGA3.basis(_E5)


def n_o() -> CGA3:
    """The origin: n₀ = (e5 − e4)/2 (null; n∞·n₀ = −1)."""
    return (CGA3.basis(_E5) - CGA3.basis(_E4)).scaled(0.5)


def up(p: Vec3) -> CGA3:
    """Conformal lift onto the null cone: P = p + ½|p|² n∞ + n₀."""
    var v = CGA3.basis(1, p[0]) + CGA3.basis(2, p[1]) + CGA3.basis(4, p[2])
    var w = Real(0.5) * (p[0] * p[0] + p[1] * p[1] + p[2] * p[2])
    return v + n_inf().scaled(w) + n_o()


def sphere_dual(center: Vec3, radius: Real) -> CGA3:
    """Dual sphere (grade 1): S = up(center) − ½r² n∞."""
    return up(center) - n_inf().scaled(0.5 * radius * radius)


@always_inline
def inner(a: CGA3, b: CGA3) -> Real:
    """Scalar inner product <a b>₀."""
    return (a * b).scalar_part()


def sphere_dist_sq(s1: CGA3, s2: CGA3, r1: Real, r2: Real) -> Real:
    """Squared center distance recovered from the algebra:
    d² = r₁² + r₂² − 2(S₁·S₂)."""
    return r1 * r1 + r2 * r2 - 2 * inner(s1, s2)


def spheres_intersect(s1: CGA3, s2: CGA3) -> Bool:
    """Dual-pencil test: (S₁∧S₂)² < 0 ⟺ a real intersection circle exists
    (≈0 tangent, >0 disjoint — sign is opposite the direct form)."""
    var c = s1.wedge(s2)
    return (c * c).scalar_part() < 0


@fieldwise_init
struct Plane3(Copyable, ImplicitlyCopyable, Movable):
    """An infinite plane `x·normal = d` (unit normal expected)."""

    var normal: Vec3
    var d: Real


def plane_dual(pl: Plane3) -> CGA3:
    """Dual plane (grade 1): π = n + d·n∞. For unit n, `up(p)·π` is the signed
    distance of p to the plane (n∞·π = 0, so sphere centers work directly:
    S·π = c·n − d regardless of radius)."""
    var v = CGA3.basis(1, pl.normal[0]) + CGA3.basis(2, pl.normal[1]) + CGA3.basis(
        4, pl.normal[2]
    )
    return v + n_inf().scaled(pl.d)


def down(P: CGA3) -> Vec3:
    """Invert `up`: normalize the conformal point (P·n∞ = −1) and read e1..e3."""
    var w = -inner(P, n_inf())
    var inv = 1.0 / w if abs(w) > 1e-12 else Real(0)
    return Vec3(P.c[1] * inv, P.c[2] * inv, P.c[4] * inv)


def reflect_point(pl: Plane3, p: Vec3) -> Vec3:
    """Mirror p in the plane by the versor sandwich `π P π` (one formula — no
    project-then-double case analysis)."""
    var pi = plane_dual(pl)
    return down(pi * up(p) * pi)


def invert_point(center: Vec3, radius: Real, p: Vec3) -> Vec3:
    """Spherical inversion `p ↦ c + r²(p−c)/|p−c|²`, as the versor sandwich
    `S P S` with S the DUAL SPHERE.

    This is the same expression as `reflect_point` with a different grade-1
    object substituted: reflecting in a plane and inverting in a sphere are one
    operation in this algebra, distinguished only by which dual vector you hand
    it. `down`'s normalisation by `P·n∞` is what makes it work — the sandwich
    does not return a unit-weight null point, and dividing by the weight IS the
    `1/|p−c|²` of the classical formula.

    This is also the one transform in the engine with no 4x4-matrix
    counterpart: inversion is conformal but not affine, so it cannot be
    expressed as a linear map on homogeneous coordinates at all. Parity against
    the closed form is in `test_cga_inversion`.
    """
    return invert_point_with(sphere_dual(center, radius), p)


def invert_point_with(s: CGA3, p: Vec3) -> Vec3:
    """`invert_point` with the dual sphere already built — the versor is fixed
    for a given inverting sphere, so a loop over many points should hoist its
    construction out. Benchmarks must use this form or they measure setup."""
    return down(s * up(p) * s)


def dilator(scale: Real) -> CGA3:
    """Uniform-scaling versor about the origin: `D = exp(½λ·n₀∧n∞)` with
    λ = ln(scale), expanded in closed form because `(n₀∧n∞)² = +1`, so the
    exponential is hyperbolic rather than trigonometric:
    `D = cosh(λ/2) + sinh(λ/2)·(n₀∧n∞)`."""
    from std.math import log, cosh, sinh

    var lam = Real(log(Float64(scale)))
    var e = n_o().wedge(n_inf())
    return CGA3.scalar(Real(cosh(Float64(lam) * 0.5))) + e.scaled(
        Real(sinh(Float64(lam) * 0.5))
    )


def dilator_reverse(scale: Real) -> CGA3:
    """Reverse of `dilator(scale)`: reversing flips a bivector's sign."""
    from std.math import log, cosh, sinh

    var lam = Real(log(Float64(scale)))
    var e = n_o().wedge(n_inf())
    return CGA3.scalar(Real(cosh(Float64(lam) * 0.5))) - e.scaled(
        Real(sinh(Float64(lam) * 0.5))
    )


def dilate_point_with(d: CGA3, drev: CGA3, p: Vec3) -> Vec3:
    """Dilator sandwich `D P D̃` with the versor pair already built. As with
    `invert_point_with`, the versor is fixed for a given scale, so loops hoist
    it; building it per point would price `log`/`cosh`/`sinh`, not the
    transform."""
    return down(d * up(p) * drev)


def dilate_point(scale: Real, p: Vec3) -> Vec3:
    """Uniform scale about the origin via the dilator sandwich `D P D̃`.

    The point of carrying scale as a VERSOR rather than a matrix factor is that
    it composes with rotations, translations and inversions in one product —
    the conformal group is closed under it. `bench_ga` prices that uniformity
    against the matrix path, which wins on raw scaling."""
    return dilate_point_with(dilator(scale), dilator_reverse(scale), p)
