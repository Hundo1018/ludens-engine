# tier: component
"""Support-mapping convex shapes and the shared GJK / EPA (ROADMAP 17.52).

  1. Ordinary: an ellipsoid's support point lies on its surface and the
     surface normal there is parallel to the query direction (500 random
     directions); a cylinder's support point is the rim point.
  2. Integration:
     - distance from a point to an r = 1 cylinder, between two rim vertices of
       the 16-gon hull (11.25 deg): exact through `SupportCylinder`, off by
       r (1 - cos(pi/16)) = 0.0192 through the hull -- the approximation
       error the trait removes;
     - `support_distance` on `ConvexPoly` clouds matches the list
       `convex_distance` (200 random pairs, 1e-5);
     - `epa3` on two overlapping spheres given as `SupportCapsule` (hl 0)
       and as equal-axis `SupportEllipsoid`: depth r1 + r2 - d within 1e-3.
  3. Extreme: a 1000:1 ellipsoid's support stays on its surface; a zero
     direction returns a surface point, not NaN.
"""

from std.math import sqrt, cos, sin, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.gjk import ConvexPoly
from geometry.gjk_distance import convex_distance, support_distance
from geometry.epa import epa3
from geometry.support import SupportEllipsoid, SupportCylinder, SupportCapsule, SupportBox

comptime X = Vec3(1, 0, 0, 0)
comptime Y = Vec3(0, 1, 0, 0)
comptime Z = Vec3(0, 0, 1, 0)


struct _Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.s >> 11) & 0xFFFFFFFF) / 4294967296.0) * 2 - 1


def _dir(mut r: _Rng) -> Vec3:
    while True:
        var v = Vec3(r.next(), r.next(), r.next(), 0)
        var l2 = dot(v, v)
        if l2 > 0.01 and l2 <= 1:
            return v / sqrt(l2)


def main() raises:
    var s = Suite("support3")
    var rng = _Rng(7)

    # ---- ellipsoid support: on the surface, normal parallel to d ----------
    var rad = Vec3(1.5, 0.5, 0.8, 0)
    var c = Vec3(0.3, -0.2, 1.0, 0)
    var e = SupportEllipsoid(c, X, Y, Z, rad)
    var worst_on = Real(0)
    var worst_par = Real(0)
    for _ in range(500):
        var d = _dir(rng)
        var p = e.support_point(d) - c
        var f = (p[0] / rad[0]) ** 2 + (p[1] / rad[1]) ** 2 + (p[2] / rad[2]) ** 2
        worst_on = max(worst_on, abs(f - 1))
        var g = Vec3(p[0] / (rad[0] * rad[0]), p[1] / (rad[1] * rad[1]), p[2] / (rad[2] * rad[2]), 0)
        var gn = g / sqrt(dot(g, g))
        worst_par = max(worst_par, 1 - dot(gn, d))
    print("  ellipsoid support, 500 directions: worst |f - 1|", worst_on, " worst 1 - n.d", worst_par)
    s.check(worst_on < 1e-5, "ellipsoid support point on the surface")
    s.check(worst_par < 1e-5, "surface normal at the support point parallel to the direction")

    var cy = SupportCylinder(Vec3(0, 0, 0, 0), Y, 1, 0.5)
    var rim = cy.support_point(Vec3(1, 1, 0, 0))
    s.check(abs(rim[0] - 1) < 1e-6 and abs(rim[1] - 0.5) < 1e-6, "cylinder support along (1, 1, 0) is the rim point (1, 0.5, 0)")

    # ---- cylinder: analytic vs 16-gon hull ---------------------------------
    var hull = ConvexPoly[3]()
    for k in range(16):
        var a = Real(2) * pi * Real(k) / 16
        hull.add(Vec3(cos(a), -0.5, sin(a), 0))
        hull.add(Vec3(cos(a), 0.5, sin(a), 0))
    var mid = Real(pi / 16)
    var q = Vec3(3 * cos(mid), 0, 3 * sin(mid), 0)
    var qp = SupportCapsule(q, Y, 0, 0)
    var d_exact = support_distance(qp, 0, cy, 0).dist
    var d_hull = support_distance(qp, 0, hull, 0).dist
    print("  point 3 from the axis, 11.25 deg: SupportCylinder", d_exact, " 16-gon hull", d_hull, " r(1 - cos(pi/16))", 1 - cos(mid))
    s.check(abs(d_exact - 2) < 1e-5, "analytic cylinder: distance r exactly (2)")
    s.check(abs((d_hull - d_exact) - (1 - cos(mid))) < 1e-4, "16-gon hull is off by r (1 - cos(pi/16))")

    # ---- clouds: support_distance == convex_distance ------------------------
    var worst = Real(0)
    for _ in range(200):
        var la = List[Vec3]()
        var lb = List[Vec3]()
        var pa = ConvexPoly[3]()
        var pb = ConvexPoly[3]()
        var off = _dir(rng) * Real(2.5)
        for _ in range(8):
            var v = Vec3(rng.next(), rng.next(), rng.next(), 0)
            la.append(v)
            pa.add(v)
            var w = Vec3(rng.next(), rng.next(), rng.next(), 0) + off
            lb.append(w)
            pb.add(w)
        var r1 = convex_distance(la, 0.1, lb, 0.2)
        var r2 = support_distance(pa, 0.1, pb, 0.2)
        if not r1.overlap:
            worst = max(worst, abs(r1.dist - r2.dist))
    print("  200 random cloud pairs: worst |convex_distance - support_distance|", worst)
    s.check(worst < 1e-5, "support_distance on clouds matches convex_distance (1e-5)")

    # ---- EPA on analytic shapes --------------------------------------------
    var sa = SupportCapsule(Vec3(0, 0, 0, 0), Y, 0.7, 0)
    var sb = SupportCapsule(Vec3(1.0, 0.2, 0, 0), Y, 0.5, 0)
    var w1 = epa3(sa, sb)
    var want = Real(1.2) - sqrt(Real(1.04))
    var ea = SupportEllipsoid(Vec3(0, 0, 0, 0), X, Y, Z, Vec3(0.7, 0.7, 0.7, 0))
    var eb = SupportEllipsoid(Vec3(1.0, 0.2, 0, 0), X, Y, Z, Vec3(0.5, 0.5, 0.5, 0))
    var w2 = epa3(ea, eb)
    print("  overlapping spheres: EPA depth (capsule hl 0)", w1.depth, " (equal-axis ellipsoids)", w2.depth, " analytic", want)
    s.check(abs(w1.depth - want) < 1e-3 and abs(w2.depth - want) < 1e-3, "epa3 on round shapes: depth r1 + r2 - d (1e-3)")
    s.check(w2.normal[0] > 0.97, "epa3 normal from a to b")
    var bx = SupportBox(Vec3(0, -0.5, 0, 0), X, Y, Z, Vec3(5, 0.5, 5, 0))
    var eg = SupportEllipsoid(Vec3(0, 0.45, 0, 0), X, Y, Z, Vec3(1.0, 0.5, 0.7, 0))
    var w3 = epa3(eg, bx)
    print("  ellipsoid (b 0.5) at y 0.45 on a box top: depth", w3.depth, " normal y", w3.normal[1])
    s.check(abs(w3.depth - 0.05) < 1e-3 and w3.normal[1] < -0.999, "ellipsoid on a box: depth 0.05, normal down")

    # ---- extremes -----------------------------------------------------------
    var thin = SupportEllipsoid(Vec3(0, 0, 0, 0), X, Y, Z, Vec3(1000, 1, 1, 0))
    var worst_thin = Real(0)
    for _ in range(100):
        var p = thin.support_point(_dir(rng))
        var f = (Float64(p[0]) / 1000) ** 2 + Float64(p[1]) ** 2 + Float64(p[2]) ** 2
        worst_thin = max(worst_thin, Real(abs(f - 1)))
    s.check(worst_thin < 1e-4, "1000:1 ellipsoid: support on the surface")
    var z = e.support_point(Vec3(0, 0, 0, 0))
    s.check(z[0] == z[0] and abs(z[0] - c[0] - rad[0]) < 1e-6, "zero direction: a surface point, not NaN")
    s.finish()
