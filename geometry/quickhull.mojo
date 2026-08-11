"""Quickhull convex hull in 2D.

Given a cloud of 2D points, `convex_hull_2d` returns the convex hull as a
`Polygon` in CCW order — the input shape that SAT/GJK assume. The classic
quickhull divide-and-conquer: split the cloud by the line through the leftmost
and rightmost points, then recursively keep the farthest outside point and
subdivide. Collinear interior points are dropped (strict `> 0` side tests).

2D `List[Vec2]` is realloc-safe in this nightly (only width-3 SIMD lists
corrupt), so the hull is built directly as `List[Vec2]`.
"""

from .vec import WorldType, Real, Vec2
from .shape import Polygon
from .predicates import orient2d, orient2d_naive


def _cross(o: Vec2, a: Vec2, b: Vec2) -> Real:
    """Signed area x2 of triangle (o, a, b); >0 if b is left of o->a... here
    used as the left test of point relative to directed line o->a."""
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _side(a: Vec2, b: Vec2, c: Vec2, exact: Bool) -> Int:
    """Which side of a->b the point c is on. This is the ONLY place the
    algorithm makes a decision, and it is a sign question, so it goes through
    the predicate layer. `_cross` survives below purely as a distance-like
    magnitude for picking the farthest point, where being off by an ulp costs
    nothing — a slightly wrong choice of pivot still yields the right hull."""
    if exact:
        return orient2d(a, b, c)
    return orient2d_naive(a, b, c)


def _hull_side(
    points: List[Vec2], a: Vec2, b: Vec2, mut hull: List[Vec2], exact: Bool
) raises:
    """Append hull vertices strictly between `a` and `b` (exclusive), in order,
    for the points lying to the left of the directed line a->b."""
    if len(points) == 0:
        return
    # Farthest point from the line a->b (largest positive cross == leftmost).
    var idx = -1
    var best = Real(0)
    for i in range(len(points)):
        var d = _cross(a, b, points[i])
        if d > best:
            best = d
            idx = i
    if idx == -1:
        return
    var c = points[idx]
    var left_ac = List[Vec2]()
    var left_cb = List[Vec2]()
    for i in range(len(points)):
        if _side(a, c, points[i], exact) > 0:
            left_ac.append(points[i])
        elif _side(c, b, points[i], exact) > 0:
            left_cb.append(points[i])
    _hull_side(left_ac, a, c, hull, exact)
    hull.append(c)
    _hull_side(left_cb, c, b, hull, exact)


def _signed_area(verts: List[Vec2]) -> Real:
    var area = Real(0)
    var n = len(verts)
    for i in range(n):
        var p0 = verts[i]
        var p1 = verts[(i + 1) % n]
        area += p0[0] * p1[1] - p1[0] * p0[1]
    return area


def convex_hull_2d(points: List[Vec2], exact: Bool = True) raises -> Polygon:
    """The convex hull of a 2D point cloud, CCW.

    `exact=False` selects the naive float32 sign test the algorithm used
    before `geometry/predicates.mojo` existed. It is kept as a seam variant so
    the two can be compared on the same input: on well-separated points they
    agree exactly, and on nearly-collinear points the naive one produces hulls
    that are not convex (`test_predicates`)."""
    var n = len(points)
    if n < 3:
        # Degenerate: return the points as-is.
        var v = List[Vec2]()
        for i in range(n):
            v.append(points[i])
        return Polygon(v^)

    # Leftmost (min x, then min y) and rightmost (max x, then max y).
    var a = points[0]
    var b = points[0]
    for i in range(1, n):
        var p = points[i]
        if p[0] < a[0] or (p[0] == a[0] and p[1] < a[1]):
            a = p
        if p[0] > b[0] or (p[0] == b[0] and p[1] > b[1]):
            b = p

    var upper = List[Vec2]()  # left of a->b
    var lower = List[Vec2]()  # left of b->a (right of a->b)
    for i in range(n):
        var s = _side(a, b, points[i], exact)
        if s > 0:
            upper.append(points[i])
        elif s < 0:
            lower.append(points[i])

    var hull = List[Vec2]()
    hull.append(a)
    _hull_side(upper, a, b, hull, exact)
    hull.append(b)
    _hull_side(lower, b, a, hull, exact)

    # Enforce CCW orientation (Polygon's contract).
    if _signed_area(hull) < 0:
        var rev = List[Vec2]()
        for i in range(len(hull)):
            rev.append(hull[len(hull) - 1 - i])
        return Polygon(rev^)
    return Polygon(hull^)
