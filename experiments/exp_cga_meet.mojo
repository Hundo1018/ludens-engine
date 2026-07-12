"""Experiment G4 — conformal geometric algebra (CGA) intersection via `meet`.

Cl(4,1) is the same `Multivector` code at a third signature — the payoff of the
signature-generic core. Points lift onto the null cone
(`P = p + ½p²n∞ + n₀`), spheres are grade-1 vectors (`S = C − ½r²n∞`), and one
algebraic incidence test `P·S = 0` covers point-on-sphere, while the wedge of
two spheres decides their intersection — no case-by-case euclidean code.

Every algebraic answer is cross-checked against classic euclidean geometry
(distance vs radii), mirroring the engine's narrowphase parity discipline.

Run: pixi run mojo run -I build experiments/exp_cga_meet.mojo
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.multivector import CGA3  # Multivector[4, 1, 0]

# basis: e1,e2,e3 euclidean; e4 (+1), e5 (-1) — the conformal pair
comptime _E4 = 1 << 3
comptime _E5 = 1 << 4


def n_inf() -> CGA3:
    """The point at infinity: n∞ = e4 + e5 (null: n∞² = 0)."""
    var v = CGA3.basis(_E4)
    return v + CGA3.basis(_E5)


def n_o() -> CGA3:
    """The origin: n₀ = (e5 − e4)/2 (null, n∞·n₀ = −1)."""
    return (CGA3.basis(_E5) - CGA3.basis(_E4)).scaled(0.5)


def up(p: Vec3) -> CGA3:
    """Conformal lift: P = p + ½|p|² n∞ + n₀ (lands on the null cone)."""
    var v = CGA3.basis(1, p[0]) + CGA3.basis(2, p[1]) + CGA3.basis(4, p[2])
    var w = Real(0.5) * (p[0] * p[0] + p[1] * p[1] + p[2] * p[2])
    return v + n_inf().scaled(w) + n_o()


def sphere(center: Vec3, radius: Real) -> CGA3:
    """Dual sphere: S = up(center) − ½r² n∞ (grade 1!)."""
    return up(center) - n_inf().scaled(0.5 * radius * radius)


def inner(a: CGA3, b: CGA3) -> Real:
    """Scalar inner product <a b>₀."""
    return (a * b).scalar_part()


def main():
    print("== CGA Cl(4,1): one algebra, many incidence tests ==")

    # --- null cone: every lifted point squares to zero ---
    var P = up(Vec3(1.2, -0.7, 2.0))
    print("P² (null cone, expect 0):", inner(P, P))

    # --- point-on-sphere: P·S = 0 iff |p-c| = r ---
    var S = sphere(Vec3(0, 0, 0), 2.0)
    print("on-sphere P·S (expect 0):", inner(up(Vec3(2, 0, 0)), S))
    print("inside    P·S (expect >0):", inner(up(Vec3(1, 0, 0)), S))
    print("outside   P·S (expect <0):", inner(up(Vec3(3, 0, 0)), S))

    # --- two spheres: the wedge C = S1 ∧ S2 carries the intersection circle;
    #     its square's sign decides real / tangent / imaginary intersection ---
    print("== sphere-sphere meet vs euclidean check ==")
    var cases = [
        (Vec3(0, 0, 0), Real(1.5), Vec3(2, 0, 0), Real(1.0)),  # overlap
        (Vec3(0, 0, 0), Real(1.0), Vec3(3, 0, 0), Real(1.0)),  # separate
        (Vec3(0, 0, 0), Real(1.0), Vec3(2, 0, 0), Real(1.0)),  # tangent
        (Vec3(0.3, 1, -1), Real(2.0), Vec3(1, 1, 0), Real(1.2)),  # overlap 3D
    ]
    for k in range(len(cases)):
        var c1 = cases[k][0]
        var r1 = cases[k][1]
        var c2 = cases[k][2]
        var r2 = cases[k][3]
        var C = sphere(c1, r1).wedge(sphere(c2, r2))
        # dual-form pencil: C² < 0 → real circle; ≈0 → tangent; > 0 → disjoint
        # (sign flips vs the direct form — the wedge of DUAL spheres)
        var csq = (C * C).scalar_part()
        var d = sqrt(
            (c1[0] - c2[0]) ** 2 + (c1[1] - c2[1]) ** 2 + (c1[2] - c2[2]) ** 2
        )
        var euclid = "intersect" if (d < r1 + r2 and d > abs(r1 - r2)) else (
            "tangent" if abs(d - (r1 + r2)) < 1e-6 else "separate"
        )
        var alg = "intersect" if csq < -1e-5 else (
            "separate" if csq > 1e-5 else "tangent"
        )
        print(
            "  case", k, ": C² =", csq, "→", alg,
            "| euclidean:", euclid, "| agree:", alg == euclid,
        )
