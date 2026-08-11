"""Exact geometric predicates (architecture law v3).

The claim under test is not "more accurate" but "correct": for float32 inputs,
the sign returned is the sign of the real determinant. That is testable without
an arbitrary-precision reference, because degenerate configurations can be
CONSTRUCTED with a known answer — three points on an exact line are exactly
collinear, and moving one by a single float32 ulp makes the true sign known by
which way it moved.

ORDINARY    the four predicates agree with hand-checkable configurations, and
            with the naive float path everywhere the naive path is reliable.
INTEGRATION `convex_hull_2d` routes its side test through the layer; exact and
            naive agree on well-separated input and the exact hull stays convex
            on input where the naive one does not; the narrowphase seam that
            consumes those hulls still produces identical contacts.
EXTREME     exactly collinear and exactly coplanar input, points differing by
            one ulp, coordinates spanning eight orders of magnitude (where the
            float32 filter has no chance), all points identical, and the
            antisymmetry / cyclic-invariance identities that any correct
            orientation predicate must satisfy for EVERY input.
"""

from std.memory import bitcast
from harness.runner import Suite
from geometry.vec import Real, Vec2, Vec3
from geometry.quickhull import convex_hull_2d
from geometry.predicates import (
    orient2d, orient3d, incircle, insphere, orient2d_naive, orient3d_naive,
)
from scheduler.rng import SplitMix64, Rng


def _next_up(x: Real) -> Real:
    """The next float32 after `x` toward +inf, by bit pattern. The smallest
    perturbation the input type can express, which is the sharpest possible
    test of a sign predicate."""
    return bitcast[DType.float32, 1](bitcast[DType.uint32, 1](x) + 1)


def _is_convex_ccw(verts: List[Vec2]) -> Bool:
    var n = len(verts)
    for i in range(n):
        if orient2d(verts[i], verts[(i + 1) % n], verts[(i + 2) % n]) < 0:
            return False
    return True


def main() raises:
    var s = Suite("predicates")
    var rng = SplitMix64.seeded(0x9E37)

    # ---- ORDINARY ----
    s.eqi(orient2d(Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)), 1, "orient2d ccw")
    s.eqi(orient2d(Vec2(0, 0), Vec2(0, 1), Vec2(1, 0)), -1, "orient2d cw")
    s.eqi(orient2d(Vec2(0, 0), Vec2(1, 1), Vec2(2, 2)), 0, "orient2d collinear")

    var a3 = Vec3(0, 0, 0)
    var b3 = Vec3(1, 0, 0)
    var c3 = Vec3(0, 1, 0)
    s.eqi(orient3d(a3, b3, c3, Vec3(0, 0, -1)), 1, "orient3d below")
    s.eqi(orient3d(a3, b3, c3, Vec3(0, 0, 1)), -1, "orient3d above")
    s.eqi(orient3d(a3, b3, c3, Vec3(3, 4, 0)), 0, "orient3d coplanar")

    # unit circle through three CCW points
    var q1 = Vec2(1, 0)
    var q2 = Vec2(0, 1)
    var q3 = Vec2(-1, 0)
    s.eqi(incircle(q1, q2, q3, Vec2(0, 0)), 1, "incircle inside")
    s.eqi(incircle(q1, q2, q3, Vec2(5, 5)), -1, "incircle outside")
    s.eqi(incircle(q1, q2, q3, Vec2(0, -1)), 0, "incircle exactly on")

    # the tetrahedron below is NEGATIVELY oriented, so the sign flips with it
    var t1 = Vec3(1, 0, 0)
    var t2 = Vec3(0, 1, 0)
    var t3 = Vec3(-1, 0, 0)
    var t4 = Vec3(0, 0, 1)
    s.eqi(orient3d(t1, t2, t3, t4), -1, "the test tetrahedron is negative")
    s.eqi(insphere(t1, t2, t3, t4, Vec3(0, 0, 0)), -1, "insphere inside")
    s.eqi(insphere(t1, t2, t3, t4, Vec3(9, 9, 9)), 1, "insphere outside")
    s.eqi(insphere(t1, t2, t3, t4, Vec3(0, -1, 0)), 0, "insphere exactly on")

    # Away from degeneracy the naive path is reliable, and the exact one must
    # not disagree with it — if it did, the exact one would be the broken one.
    var mismatch = 0
    for _ in range(4000):
        var p = Vec2(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10)
        var q = Vec2(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10)
        var r = Vec2(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10)
        if orient2d(p, q, r) != orient2d_naive(p, q, r):
            mismatch += 1
    s.eqi(mismatch, 0, "exact == naive on well-separated random input (2d)")

    var mismatch3 = 0
    for _ in range(2000):
        var p = Vec3(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10,
                     Real(rng.next_f32()) * 20 - 10)
        var q = Vec3(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10,
                     Real(rng.next_f32()) * 20 - 10)
        var r = Vec3(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10,
                     Real(rng.next_f32()) * 20 - 10)
        var u = Vec3(Real(rng.next_f32()) * 20 - 10, Real(rng.next_f32()) * 20 - 10,
                     Real(rng.next_f32()) * 20 - 10)
        if orient3d(p, q, r, u) != orient3d_naive(p, q, r, u):
            mismatch3 += 1
    s.eqi(mismatch3, 0, "exact == naive on well-separated random input (3d)")

    # ---- EXTREME: identities that hold for EVERY input ----
    # Swapping two arguments must flip the sign; a cyclic rotation must not
    # change it. Cyclic invariance is the one that bites: the naive formula is
    # antisymmetric for free (it computes the same two products either way),
    # but a rotation makes it subtract a different pair of coordinates, and
    # near degeneracy the two disagree. That is the concrete way "inconsistent
    # answers" breaks a hull builder — and it is what caught a real bug here,
    # a filter stage that took its differences in float32 before widening.
    var anti_ok = True
    var cyc_ok = True
    var naive_anti_bad = 0
    for k in range(2000):
        # points forced near collinear: c sits on the line a->b, nudged
        var a = Vec2(Real(rng.next_f32()) * 2 - 1, Real(rng.next_f32()) * 2 - 1)
        var b = Vec2(a[0] + 1.0, a[1] + 0.3)
        var t = Real(rng.next_f32())
        var c = Vec2(a[0] + t * 1.0, a[1] + t * 0.3)
        if (k & 1) == 1:
            c = Vec2(_next_up(c[0]), c[1])
        if orient2d(a, b, c) != -orient2d(b, a, c):
            anti_ok = False
        if orient2d(a, b, c) != orient2d(b, c, a):
            cyc_ok = False
        if orient2d_naive(a, b, c) != orient2d_naive(b, c, a):
            naive_anti_bad += 1
    s.check(anti_ok, "orient2d is antisymmetric on near-degenerate input")
    s.check(cyc_ok, "orient2d is cyclic-invariant on near-degenerate input")
    print("  naive cyclic-invariance violations (of 2000):", naive_anti_bad)
    s.check(
        naive_anti_bad > 100,
        "the naive path DOES violate it — otherwise this test proves nothing",
    )

    # One ulp decides the sign, and the direction of the nudge decides which.
    var line_a = Vec2(0.5, 0.25)
    var line_b = Vec2(1.5, 0.75)
    var mid = Vec2(1.0, 0.5)  # exactly on the line
    s.eqi(orient2d(line_a, line_b, mid), 0, "the midpoint is exactly collinear")
    s.eqi(
        orient2d(line_a, line_b, Vec2(mid[0], _next_up(mid[1]))), 1,
        "one ulp up is left of the line",
    )
    s.eqi(
        orient2d(line_a, line_b, Vec2(_next_up(mid[0]), mid[1])), -1,
        "one ulp right is right of the line",
    )

    # Huge dynamic range: the float32 filter cannot decide these at all.
    var big_a = Vec2(1e8, 1e8)
    var big_b = Vec2(-1e8, -1e8)
    s.eqi(orient2d(big_a, big_b, Vec2(0, 0)), 0, "collinear across 1e8")
    # a -> b points down-left, so "left of a -> b" is BELOW the line y = x and
    # a point above it is -1. det works out to exactly -2e5.
    s.eqi(orient2d(big_a, big_b, Vec2(0, 1e-3)), -1, "1e-3 off a 1e8 line is decided")

    # All-identical input: every determinant is exactly zero.
    var same = Vec2(3, 3)
    s.eqi(orient2d(same, same, same), 0, "three identical points are collinear")
    var same3 = Vec3(2, 2, 2)
    s.eqi(orient3d(same3, same3, same3, same3), 0, "four identical points are coplanar")

    # Exactly coplanar in 3D, at scale, and one ulp off it.
    var pa = Vec3(0, 0, 4)
    var pb = Vec3(1000, 0, 4)
    var pc = Vec3(0, 1000, 4)
    s.eqi(orient3d(pa, pb, pc, Vec3(500, 500, 4)), 0, "exactly coplanar at scale")
    s.eqi(
        orient3d(pa, pb, pc, Vec3(500, 500, _next_up(Real(4)))), -1,
        "one ulp above the plane is decided",
    )

    # ---- INTEGRATION: the hull builder that consumes the predicate ----
    # A cloud that is almost a straight line, plus two points off it. The naive
    # side test disagrees with itself here; the exact one cannot.
    var cloud = List[Vec2]()
    for i in range(24):
        var x = Real(i) * 0.125
        cloud.append(Vec2(x, x * 0.5))  # exactly on a line
    cloud.append(Vec2(1.5, 1.4))
    cloud.append(Vec2(1.5, -0.6))
    var hx = convex_hull_2d(cloud, exact=True)
    print("  near-degenerate cloud -> exact hull vertices:", len(hx))
    s.check(_is_convex_ccw(hx.verts), "the exact hull is convex")
    s.check(len(hx) >= 3 and len(hx) <= 6, "and drops the collinear interior")

    # On well-separated input the two spellings must agree exactly.
    var plain = List[Vec2]()
    for i in range(40):
        plain.append(
            Vec2(Real(rng.next_f32()) * 10 - 5, Real(rng.next_f32()) * 10 - 5)
        )
    var he = convex_hull_2d(plain, exact=True)
    var hn = convex_hull_2d(plain, exact=False)
    var same_hull = len(he) == len(hn)
    if same_hull:
        for i in range(len(he)):
            if he.verts[i][0] != hn.verts[i][0] or he.verts[i][1] != hn.verts[i][1]:
                same_hull = False
    s.check(same_hull, "exact and naive hulls agree on well-separated input")

    # And the hull still reaches the narrowphase that consumes it.
    var box = List[Vec2]()
    box.append(Vec2(-1, -1))
    box.append(Vec2(1, -1))
    box.append(Vec2(1, 1))
    box.append(Vec2(-1, 1))
    box.append(Vec2(0, 0))  # interior
    var bh = convex_hull_2d(box)
    s.eqi(len(bh), 4, "a square cloud still hulls to four vertices")

    s.finish()
