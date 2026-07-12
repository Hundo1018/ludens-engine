"""Reference/incident-edge contact clipping for 2D convex polygons.

SAT answers hit/normal/depth; this recovers WHERE the contact is (Box2D/dyn4j
style). Given the SAT contact normal `n` (a -> b): each polygon contributes its
"best" edge — the edge touching the farthest vertex along the search direction
and most perpendicular to it. The more-perpendicular of the two becomes the
reference edge, the other the incident edge. The incident edge is clipped by
the reference edge's two end planes (Sutherland–Hodgman, two passes), then only
points behind the reference face are kept; each survivor's distance behind that
face is its per-point penetration depth. Convex overlap yields 1–2 points
(2 for face-face, 1 for corner-face).
"""

from .vec import WorldType, Real, Vec2, dot, normalize
from .shape import Polygon


@fieldwise_init
struct ClipEdge(Copyable, ImplicitlyCopyable, Movable):
    var maxv: Vec2  # farthest vertex along the search direction
    var p1: Vec2
    var p2: Vec2

    def edge_dir(self) -> Vec2:
        return normalize(self.p2 - self.p1)


def best_edge(p: Polygon, n: Vec2) -> ClipEdge:
    """The polygon edge containing the farthest vertex along `n` that is most
    perpendicular to `n` (of the two edges meeting at that vertex)."""
    var count = len(p.verts)
    var best = 0
    var best_d = dot(p.verts[0], n)
    for i in range(1, count):
        var d = dot(p.verts[i], n)
        if d > best_d:
            best_d = d
            best = i
    var v = p.verts[best]
    var v_prev = p.verts[(best + count - 1) % count]
    var v_next = p.verts[(best + 1) % count]
    var l = normalize(v - v_next)
    var r = normalize(v - v_prev)
    if dot(r, n) <= dot(l, n):
        return ClipEdge(v, v_prev, v)
    return ClipEdge(v, v, v_next)


def _clip(p1: Vec2, p2: Vec2, axis: Vec2, offset: Real, mut kept: List[Vec2]):
    """Keep the part of segment p1-p2 with dot(axis, p) >= offset."""
    var d1 = dot(axis, p1) - offset
    var d2 = dot(axis, p2) - offset
    if d1 >= 0:
        kept.append(p1)
    if d2 >= 0:
        kept.append(p2)
    if d1 * d2 < 0:
        var t = d1 / (d1 - d2)
        kept.append(p1 + (p2 - p1) * t)


def clip_manifold(
    a: Polygon,
    b: Polygon,
    normal: Vec2,
    mut pts: List[Vec2],
    mut depths: List[Real],
) -> Bool:
    """Contact points for overlapping convex polygons; `normal` is the SAT
    contact normal a -> b. Appends 1-2 points with per-point depths. Returns
    False when clipping degenerates (caller falls back to a support point)."""
    var e1 = best_edge(a, normal)
    var e2 = best_edge(b, -normal)
    var refe = e1
    var ince = e2
    var flip = False
    if abs(dot(e2.edge_dir(), normal)) < abs(dot(e1.edge_dir(), normal)):
        refe = e2
        ince = e1
        flip = True
    var rv = refe.edge_dir()
    # Two side-plane clips against the reference edge's endpoints.
    var stage1 = List[Vec2]()
    _clip(ince.p1, ince.p2, rv, dot(rv, refe.p1), stage1)
    if len(stage1) < 2:
        return False
    var stage2 = List[Vec2]()
    _clip(stage1[0], stage1[1], -rv, -dot(rv, refe.p2), stage2)
    if len(stage2) < 2:
        return False
    # Keep points behind the reference face; distance behind = depth.
    var refn = -normal if flip else normal
    var off = dot(refn, refe.maxv)
    for i in range(len(stage2)):
        var sep = dot(refn, stage2[i]) - off
        if sep <= Real(1e-6):
            pts.append(stage2[i])
            depths.append(-sep)
    return len(pts) > 0
