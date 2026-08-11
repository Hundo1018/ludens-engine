"""Quickhull, and the seam that makes it reachable.

The hull itself is checked structurally (convex, CCW, covers its input). The
INTEGRATION block below is the part architecture law v3 asks for: until
`add_cloud` existed, nothing outside this file called `convex_hull_2d`, so a
correct hull was a capability the engine did not actually have. The gate is
that a cloud registered through the narrowphase collides identically to the
same shape registered as an already-correct polygon.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec2
from geometry.shape import Polygon
from geometry.quickhull import convex_hull_2d
from geometry.pip import point_in_polygon
from collision.narrowphase import SATNarrowPhase
from collision.manifold import SATManifoldNarrowPhase


def _is_convex_ccw(verts: List[Vec2]) -> Bool:
    """All consecutive turns are left turns (cross >= 0) for a convex CCW poly."""
    var n = len(verts)
    for i in range(n):
        var a = verts[i]
        var b = verts[(i + 1) % n]
        var c = verts[(i + 2) % n]
        var cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        if cross < -1e-4:
            return False
    return True


def main() raises:
    var s = Suite("quickhull")

    # A square's worth of points plus interior noise -> 4-vertex hull.
    var pts = List[Vec2]()
    pts.append(Vec2(0, 0))
    pts.append(Vec2(2, 0))
    pts.append(Vec2(2, 2))
    pts.append(Vec2(0, 2))
    pts.append(Vec2(1, 1))  # interior
    pts.append(Vec2(0.5, 0.5))  # interior
    pts.append(Vec2(1.5, 1.0))  # interior

    var hull = convex_hull_2d(pts)
    s.eqi(len(hull), 4, "square hull has 4 vertices")
    s.check(_is_convex_ccw(hull.verts), "hull is convex CCW")

    # Every input point lies inside or on the hull.
    for i in range(len(pts)):
        var p = pts[i]
        # nudge interior test: points strictly inside must be inside; corners on boundary
        var inside_or_corner = point_in_polygon(p, hull) or _on_any_vertex(
            p, hull.verts
        )
        s.check(inside_or_corner, "input point covered by hull")

    # Triangle with interior points -> 3-vertex hull.
    var tri = List[Vec2]()
    tri.append(Vec2(0, 0))
    tri.append(Vec2(4, 0))
    tri.append(Vec2(0, 4))
    tri.append(Vec2(1, 1))  # interior
    var th = convex_hull_2d(tri)
    s.eqi(len(th), 3, "triangle hull has 3 vertices")
    s.check(_is_convex_ccw(th.verts), "triangle hull convex CCW")

    # ---- INTEGRATION: the cloud seam into the 2D narrowphase ----
    # Two overlapping unit boxes. One pair is registered as polygons, the other
    # as clouds of the same corners plus interior noise. Both the boolean test
    # and the clipped manifold must agree exactly — the cloud path may not be a
    # different shape, only a different way of spelling the same one.
    var noisy_a = List[Vec2]()
    noisy_a.append(Vec2(-1, -1))
    noisy_a.append(Vec2(1, -1))
    noisy_a.append(Vec2(1, 1))
    noisy_a.append(Vec2(-1, 1))
    noisy_a.append(Vec2(0, 0))
    noisy_a.append(Vec2(0.4, -0.2))
    var noisy_b = List[Vec2]()
    for i in range(len(noisy_a)):
        noisy_b.append(noisy_a[i] + Vec2(1.5, 0))

    var bp = SATNarrowPhase()
    _ = bp.add(Polygon.box(0, 0, 1, 1))
    _ = bp.add(Polygon.box(1.5, 0, 1, 1))
    var bc = SATNarrowPhase()
    _ = bc.add_cloud(noisy_a)
    _ = bc.add_cloud(noisy_b)
    var cp = bp.test(0, 1)
    var cc = bc.test(0, 1)
    s.check(cp.hit and cc.hit, "both spellings collide")
    s.check(
        abs(Float64(cp.depth - cc.depth)) < 1e-5,
        "cloud-registered shape has the same penetration depth",
    )
    s.check(
        abs(Float64(cp.normal[0] - cc.normal[0]))
        + abs(Float64(cp.normal[1] - cc.normal[1])) < 1e-5,
        "cloud-registered shape has the same normal",
    )

    var mp = SATManifoldNarrowPhase()
    _ = mp.add(Polygon.box(0, 0, 1, 1))
    _ = mp.add(Polygon.box(1.5, 0, 1, 1))
    var mc = SATManifoldNarrowPhase()
    _ = mc.add_cloud(noisy_a)
    _ = mc.add_cloud(noisy_b)
    var m1 = mp.test_manifold(0, 1)
    var m2 = mc.test_manifold(0, 1)
    print("  manifold points — polygon", m1.count, " cloud", m2.count)
    s.eqi(m2.count, m1.count, "cloud path yields the same contact count")
    var worst = Real(0)
    for k in range(m1.count):
        var d = abs(m1.depths[k] - m2.depths[k])
        if d > worst:
            worst = d
    s.check(Float64(worst) < 1e-5, "cloud path yields the same per-point depths")

    # EXTREME: a cloud that is a single repeated point must not crash the seam.
    var degen = List[Vec2]()
    for _ in range(4):
        degen.append(Vec2(3, 3))
    var bd = SATNarrowPhase()
    _ = bd.add_cloud(degen)
    _ = bd.add(Polygon.box(0, 0, 1, 1))
    s.check(not bd.test(0, 1).hit, "a degenerate cloud far away still misses")

    s.finish()


def _on_any_vertex(p: Vec2, verts: List[Vec2]) -> Bool:
    for i in range(len(verts)):
        var d = p - verts[i]
        if d[0] * d[0] + d[1] * d[1] < 1e-9:
            return True
    return False
