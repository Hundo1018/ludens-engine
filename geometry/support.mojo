"""Analytic convex shapes by support mapping (ROADMAP 17.52).

Each struct implements `geometry.gjk.Support3`, so `geometry.epa.epa3` and
`geometry.gjk_distance.support_distance` run on it exactly -- a cylinder is
a cylinder, not a 16-gon prism, and an ellipsoid needs no vertices at all.
Point clouds (`ConvexPoly[3]`) implement the same trait, so a mixed pair
(ellipsoid vs hull) goes through the same GJK / EPA.

Frames: `c` is the centre, `ax0 / ax1 / ax2` an orthonormal world frame
(the body's axes); dimensions are along those axes.

Support functions (d a world direction, d_k = d . ax_k):
  * ellipsoid, radii (a, b, c): s = sum_k ax_k r_k^2 d_k / sqrt(sum r_k^2 d_k^2)
    -- the sphere's support pushed through the scaling;
  * cylinder, axis ax1, radius r, half length h:
    s = ax1 h sign(d_1) + r (d - ax1 d_1) / |d - ax1 d_1|;
  * capsule: segment end along sign(d_1), plus r d / |d|;
  * box, half extents (x, y, z): s = sum_k ax_k h_k sign(d_k).
Ties (a zero component) pick the + side, so the result is deterministic.
"""

from std.math import sqrt
from .vec import Real, Vec3, dot
from .gjk import Support3


@always_inline
def _sgn(x: Real) -> Real:
    return Real(1) if x >= 0 else Real(-1)


@fieldwise_init
struct SupportEllipsoid(Copyable, ImplicitlyCopyable, Movable, Support3):
    var c: Vec3
    var ax0: Vec3
    var ax1: Vec3
    var ax2: Vec3
    var radii: Vec3

    def support_point(self, d: Vec3) -> Vec3:
        var r = self.radii
        var e0 = r[0] * r[0] * dot(d, self.ax0)
        var e1 = r[1] * r[1] * dot(d, self.ax1)
        var e2 = r[2] * r[2] * dot(d, self.ax2)
        # |R d| with R = diag(r): sqrt(sum r_k^2 d_k^2) = sqrt(sum e_k d_k)
        var q = e0 * dot(d, self.ax0) + e1 * dot(d, self.ax1) + e2 * dot(d, self.ax2)
        if q <= Real(1e-30):
            return self.c + self.ax0 * r[0]
        var inv = 1 / sqrt(q)
        return self.c + (self.ax0 * e0 + self.ax1 * e1 + self.ax2 * e2) * inv

    def center_point(self) -> Vec3:
        return self.c

    def extent(self, n: Vec3) -> Real:
        """Support function value h(n) - n . c: how far the surface reaches
        along unit `n` from the centre."""
        return dot(self.support_point(n) - self.c, n)


@fieldwise_init
struct SupportCylinder(Copyable, ImplicitlyCopyable, Movable, Support3):
    """Axis `axis` (unit), radius `r`, half length `hl`."""

    var c: Vec3
    var axis: Vec3
    var r: Real
    var hl: Real

    def support_point(self, d: Vec3) -> Vec3:
        var da = dot(d, self.axis)
        var rad = d - self.axis * da
        var rl = sqrt(dot(rad, rad))
        var p = self.c + self.axis * (self.hl * _sgn(da))
        if rl > Real(1e-12):
            p = p + rad * (self.r / rl)
        return p

    def center_point(self) -> Vec3:
        return self.c


@fieldwise_init
struct SupportCapsule(Copyable, ImplicitlyCopyable, Movable, Support3):
    """Segment `c +- axis hl` grown by `r`."""

    var c: Vec3
    var axis: Vec3
    var r: Real
    var hl: Real

    def support_point(self, d: Vec3) -> Vec3:
        var p = self.c + self.axis * (self.hl * _sgn(dot(d, self.axis)))
        var dl = sqrt(dot(d, d))
        if dl > Real(1e-12):
            p = p + d * (self.r / dl)
        return p

    def center_point(self) -> Vec3:
        return self.c


@fieldwise_init
struct SupportBox(Copyable, ImplicitlyCopyable, Movable, Support3):
    var c: Vec3
    var ax0: Vec3
    var ax1: Vec3
    var ax2: Vec3
    var half: Vec3

    def support_point(self, d: Vec3) -> Vec3:
        return (
            self.c
            + self.ax0 * (self.half[0] * _sgn(dot(d, self.ax0)))
            + self.ax1 * (self.half[1] * _sgn(dot(d, self.ax1)))
            + self.ax2 * (self.half[2] * _sgn(dot(d, self.ax2)))
        )

    def center_point(self) -> Vec3:
        return self.c
