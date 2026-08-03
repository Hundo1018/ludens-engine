"""Point-to-circle (point-to-arc) distance: CGA carriers vs the closed form.

The critique this closes asked for point-to-arc distance "via CGA". The check
is parity against the euclidean closed form over random configurations,
including the two degenerate cases that separate a correct derivation from one
that happens to work in general position: a point exactly on the circle's axis
(the in-plane offset vanishes, so the closest point is not unique) and a point
exactly on the circle (distance zero, where a subtraction of similar
magnitudes can go negative under the square root).
"""

from std.math import sqrt, cos, sin
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, normalize, length
from geometry.cga import Circle3, point_circle_dist, point_circle_dist_cga


def main() raises:
    var s = Suite("cga_circle")
    var rng = SplitMix64.seeded(41)

    var c = Circle3.make(
        Vec3(0.5, -0.25, 1.0), normalize(Vec3(0.3, 1.0, -0.2)), 2.0
    )

    # 1. random points
    var worst = Real(0)
    for _ in range(400):
        var p = Vec3(
            Real(rng.next_f32()) * 12 - 6,
            Real(rng.next_f32()) * 12 - 6,
            Real(rng.next_f32()) * 12 - 6,
        )
        var e = abs(point_circle_dist_cga(c, p) - point_circle_dist(c, p))
        if e > worst:
            worst = e
    print("  worst random-point error:", worst)
    s.check(worst < 1e-2, "CGA point-circle distance == closed form")

    # 2. on the axis: in-plane offset is zero, closest point not unique
    var axis_ok = True
    for k in range(10):
        var t = Real(k) - 5
        var p = c.center + c.normal * t
        var want = sqrt(t * t + c.radius * c.radius)
        if abs(point_circle_dist_cga(c, p) - want) > 1e-2:
            axis_ok = False
    s.check(axis_ok, "points on the axis: distance = sqrt(h^2 + r^2)")

    # 3. exactly on the circle: distance must be ~0, not NaN or negative
    var on_ok = True
    for k in range(12):
        var ang = Real(k) * 0.5236
        var u = normalize(
            (Vec3(1.0, 0.0, 0.0) - c.normal * (c.normal[0]))
        )
        var v = Vec3(
            c.normal[1] * u[2] - c.normal[2] * u[1],
            c.normal[2] * u[0] - c.normal[0] * u[2],
            c.normal[0] * u[1] - c.normal[1] * u[0],
        )
        var p = c.center + (u * Real(cos(Float64(ang))) + v * Real(sin(Float64(ang)))) * c.radius
        var d = point_circle_dist_cga(c, p)
        if not (d >= 0) or d > 1e-2:
            on_ok = False
    s.check(on_ok, "points on the circle: distance ~= 0 and non-negative")

    # 4. centre of the circle: distance must be exactly the radius
    var dc = point_circle_dist_cga(c, c.center)
    s.check(abs(dc - c.radius) < 1e-2, "circle centre: distance = radius")

    s.finish()
