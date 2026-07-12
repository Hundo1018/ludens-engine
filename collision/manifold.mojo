"""Contact manifolds: multi-point contact geometry for angular dynamics.

`Contact[dim]` (narrowphase.mojo) answers hit/normal/depth — enough for linear
response but not for torque: rotational dynamics needs to know WHERE the bodies
touch. `ContactManifold[dim]` carries up to four contact points (positions plus
per-point depths) sharing one normal, and `summary()` collapses back to a
`Contact` so parity against the single-point path stays checkable.

`ManifoldNarrowPhase` is the swap seam, mirroring `NarrowPhase` (per-proxy
registry, `test_manifold(a, b)`). First implementation:

  * `AABBManifoldNarrowPhase[dim]` — for axis-aligned boxes the contact patch
    is the overlap region's slab on the min-penetration axis: its corners over
    the other axes, at the slab centre on the contact axis. 2 points in 2D,
    4 points in 3D; every point carries the same axis overlap as depth.
  * `SATManifoldNarrowPhase` — 2D convex polygons: SAT axis + reference/
    incident edge clipping (`geometry/clip.mojo`), 1-2 points with per-point
    depths (2 for face-face, 1 for corner-face).
  * `OBBManifoldNarrowPhase` — 2D oriented boxes: the analytic 4-axis OBB test
    for the axis, then the same clipping over `to_polygon()`.
  * `GjkManifoldNarrowPhase` — 3D convex shapes: GJK + witness-tracking EPA
    (`geometry/epa.mojo`), one contact point at the witness midpoint.
  * `box_box_manifold` — ROTATED 3D boxes: 15-axis SAT (6 faces + 9 edge
    crosses, faces preferred within 5% to avoid axis flip jitter), then
    reference-face / incident-face quad clipping for face contacts (up to 4
    deepest points, per-point depth) or closest-point-of-edges for edge-edge.
    This is what gives tilted boxes their restoring torque — an axis-aligned
    manifold cannot (see ROADMAP 2.1 diagnosis).
"""

from std.math import sqrt
from geometry.vec import WorldType, Real, Vec2, Vec3, dot
from geometry.aabb import AABB
from geometry.shape import Polygon
from geometry.sat import SATResult, sat_collide
from geometry.obb import OBB, obb_collide
from geometry.clip import best_edge, clip_manifold
from geometry.gjk import ConvexPoly
from geometry.epa import epa_witness3
from .narrowphase import Contact


struct ContactManifold[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    comptime MAX: Int = 4
    var hit: Bool
    var normal: SIMD[WorldType, Self.dim]  # points from a -> b
    var count: Int
    var points: InlineArray[SIMD[WorldType, Self.dim], Self.MAX]
    var depths: InlineArray[Real, Self.MAX]

    def __init__(out self):
        self.hit = False
        self.normal = SIMD[WorldType, Self.dim](0)
        self.count = 0
        self.points = InlineArray[SIMD[WorldType, Self.dim], Self.MAX](
            fill=SIMD[WorldType, Self.dim](0)
        )
        self.depths = InlineArray[Real, Self.MAX](fill=0)

    @staticmethod
    def miss() -> Self:
        return Self()

    @staticmethod
    def hit_along(normal: SIMD[WorldType, Self.dim]) -> Self:
        var m = Self()
        m.hit = True
        m.normal = normal
        return m

    def add(mut self, p: SIMD[WorldType, Self.dim], depth: Real):
        if self.count < Self.MAX:
            self.points[self.count] = p
            self.depths[self.count] = depth
            self.count += 1

    def max_depth(self) -> Real:
        var d = Real(0)
        for i in range(self.count):
            if self.depths[i] > d:
                d = self.depths[i]
        return d

    def summary(self) -> Contact[Self.dim]:
        """Collapse to the single-point contract (parity bridge)."""
        return Contact[Self.dim](self.hit, self.normal, self.max_depth())


trait ManifoldNarrowPhase(Movable, ImplicitlyDeletable):
    comptime dim: Int
    def test_manifold(self, a: Int, b: Int) -> ContactManifold[Self.dim]: ...


struct AABBManifoldNarrowPhase[D: Int](ManifoldNarrowPhase):
    comptime dim: Int = Self.D
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.boxes = List[AABB[Self.D]]()

    def add(mut self, box: AABB[Self.D]) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[Self.D]:
        var ba = self.boxes[a]
        var bb = self.boxes[b]
        # Min-penetration axis, same rule as AABBNarrowPhase.test.
        var lo = SIMD[WorldType, Self.D](0)
        var hi = SIMD[WorldType, Self.D](0)
        var best_depth = Real(1.0e30)
        var best_axis = 0
        comptime for k in range(Self.D):
            var l = max(ba.min[k], bb.min[k])
            var h = min(ba.max[k], bb.max[k])
            if h - l <= 0:
                return ContactManifold[Self.D].miss()
            lo[k] = l
            hi[k] = h
            if h - l < best_depth:
                best_depth = h - l
                best_axis = k
        var n = SIMD[WorldType, Self.D](0)
        var dir = bb.center()[best_axis] - ba.center()[best_axis]
        n[best_axis] = 1 if dir >= 0 else -1
        var m = ContactManifold[Self.D].hit_along(n)
        # Contact patch = the overlap slab's corners over the non-contact axes,
        # at the slab centre on the contact axis (2 points in 2D, 4 in 3D).
        var mid = (lo[best_axis] + hi[best_axis]) * Real(0.5)
        for mask in range(1 << (Self.D - 1)):
            var p = SIMD[WorldType, Self.D](0)
            var bit = 0
            comptime for k in range(Self.D):
                if k == best_axis:
                    p[k] = mid
                else:
                    p[k] = hi[k] if ((mask >> bit) & 1) == 1 else lo[k]
                    bit += 1
            m.add(p, best_depth)
        return m


def _clipped_manifold(pa: Polygon, pb: Polygon, r: SATResult) -> ContactManifold[2]:
    """Manifold from an already-computed SAT result via edge clipping."""
    if not r.hit:
        return ContactManifold[2].miss()
    var m = ContactManifold[2].hit_along(r.normal)
    var pts = List[Vec2]()
    var ds = List[Real]()
    if clip_manifold(pa, pb, r.normal, pts, ds):
        for i in range(len(pts)):
            m.add(pts[i], ds[i])
    else:
        # Degenerate clip (barely touching): incident support point, SAT depth.
        m.add(best_edge(pb, -r.normal).maxv, r.depth)
    return m


struct SATManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 2
    var polys: List[Polygon]

    def __init__(out self):
        self.polys = List[Polygon]()

    def add(mut self, var p: Polygon) -> Int:
        self.polys.append(p^)
        return len(self.polys) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[2]:
        return _clipped_manifold(
            self.polys[a], self.polys[b], sat_collide(self.polys[a], self.polys[b])
        )


struct OBBManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 2
    var boxes: List[OBB]

    def __init__(out self):
        self.boxes = List[OBB]()

    def add(mut self, box: OBB) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[2]:
        # Analytic 4-axis test for the normal, polygon clipping for the points.
        return _clipped_manifold(
            self.boxes[a].to_polygon(),
            self.boxes[b].to_polygon(),
            obb_collide(self.boxes[a], self.boxes[b]),
        )


struct GjkManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 3
    var shapes: List[ConvexPoly[3]]

    def __init__(out self):
        self.shapes = List[ConvexPoly[3]]()

    def add(mut self, var s: ConvexPoly[3]) -> Int:
        self.shapes.append(s^)
        return len(self.shapes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[3]:
        var w = epa_witness3(self.shapes[a], self.shapes[b])
        if not w.hit:
            return ContactManifold[3].miss()
        var m = ContactManifold[3].hit_along(w.normal)
        m.add((w.point_a + w.point_b) * Real(0.5), w.depth)
        return m


# --- rotated 3D box-box manifold (SAT + face clipping) -----------------------


def _cross3v(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


comptime Axes3 = InlineArray[Vec3, 3]


def _proj_radius(ax: Axes3, h: Vec3, l: Vec3) -> Real:
    """Half-width of an oriented box projected onto unit axis `l`."""
    return (
        h[0] * abs(dot(ax[0], l))
        + h[1] * abs(dot(ax[1], l))
        + h[2] * abs(dot(ax[2], l))
    )


def _face_verts(c: Vec3, ax: Axes3, h: Vec3, j: Int, sign: Real) -> InlineArray[Vec3, 4]:
    """The 4 corners of face `j` (normal ax[j]*sign) of an oriented box."""
    var u = (j + 1) % 3
    var v = (j + 2) % 3
    var fc = c + ax[j] * (h[j] * sign)
    var eu = ax[u] * h[u]
    var ev = ax[v] * h[v]
    var out = InlineArray[Vec3, 4](fill=fc)
    out[0] = fc + eu + ev
    out[1] = fc - eu + ev
    out[2] = fc - eu - ev
    out[3] = fc + eu - ev
    return out


def _clip_poly_plane(
    pts: InlineArray[Vec3, 8],
    n_in: Int,
    axis: Vec3,
    offset: Real,
) -> Tuple[InlineArray[Vec3, 8], Int]:
    """Keep the part of the polygon with dot(axis, p) <= offset."""
    var out = InlineArray[Vec3, 8](fill=Vec3(0, 0, 0))
    var n_out = 0
    for i in range(n_in):
        var p0 = pts[i]
        var p1 = pts[(i + 1) % n_in]
        var d0 = dot(axis, p0) - offset
        var d1 = dot(axis, p1) - offset
        if d0 <= 0:
            if n_out < 8:
                out[n_out] = p0
                n_out += 1
        if d0 * d1 < 0:
            var t = d0 / (d0 - d1)
            if n_out < 8:
                out[n_out] = p0 + (p1 - p0) * t
                n_out += 1
    return (out, n_out)


def _face_manifold(
    rc: Vec3,
    rax: Axes3,
    rh: Vec3,
    ic: Vec3,
    iax: Axes3,
    ih: Vec3,
    j: Int,
    sign: Real,
    n_out: Vec3,
) -> ContactManifold[3]:
    """Clip the incident box's most anti-parallel face against reference face
    `j` of the reference box; `n_out` is the manifold normal (a -> b)."""
    var nf = rax[j] * sign  # reference face outward normal (toward incident)
    # incident face: axis of the incident box most anti-parallel to nf
    var best_k = 0
    var best_d = Real(1e30)
    var best_sign = Real(1)
    for k in range(3):
        var d = dot(iax[k], nf)
        if d < best_d:
            best_d = d
            best_k = k
            best_sign = 1
        if -d < best_d:
            best_d = -d
            best_k = k
            best_sign = -1
    var quad4 = _face_verts(ic, iax, ih, best_k, best_sign)
    var pts = InlineArray[Vec3, 8](fill=Vec3(0, 0, 0))
    for i in range(4):
        pts[i] = quad4[i]
    var count = 4
    # clip against the reference face's 4 side planes
    var u = (j + 1) % 3
    var v = (j + 2) % 3
    var r = _clip_poly_plane(pts, count, rax[u], dot(rax[u], rc) + rh[u])
    pts = r[0]
    count = r[1]
    r = _clip_poly_plane(pts, count, -rax[u], -(dot(rax[u], rc) - rh[u]))
    pts = r[0]
    count = r[1]
    r = _clip_poly_plane(pts, count, rax[v], dot(rax[v], rc) + rh[v])
    pts = r[0]
    count = r[1]
    r = _clip_poly_plane(pts, count, -rax[v], -(dot(rax[v], rc) - rh[v]))
    pts = r[0]
    count = r[1]
    if count == 0:
        return ContactManifold[3].miss()
    # keep points behind the reference face; depth = distance behind
    var face_off = dot(nf, rc + rax[j] * (rh[j] * sign))
    var m = ContactManifold[3].hit_along(n_out)
    # collect up to the 4 deepest
    var depths = InlineArray[Real, 8](fill=-1)
    for i in range(count):
        depths[i] = face_off - dot(nf, pts[i])  # >0 means behind the face
    for _ in range(4):
        var bi = -1
        var bd = Real(1e-6)
        for i in range(count):
            if depths[i] > bd:
                bd = depths[i]
                bi = i
        if bi < 0:
            break
        m.add(pts[bi], depths[bi])
        depths[bi] = -1
    if m.count == 0:
        return ContactManifold[3].miss()
    return m


def box_box_manifold(
    ca: Vec3,
    axa: Axes3,
    ha: Vec3,
    cb: Vec3,
    axb: Axes3,
    hb: Vec3,
) -> ContactManifold[3]:
    """Contact manifold between two ORIENTED 3D boxes (world-frame axes)."""
    var t = cb - ca
    var best_overlap = Real(1e30)
    var best_axis = Vec3(0, 0, 0)
    var best_is_a = True
    var best_j = 0
    # 6 face axes (preferred), then 9 edge-cross axes with a 5% penalty.
    for j in range(3):
        var l = axa[j]
        var overlap = _proj_radius(axa, ha, l) + _proj_radius(axb, hb, l) - abs(
            dot(t, l)
        )
        if overlap < 0:
            return ContactManifold[3].miss()
        if overlap < best_overlap:
            best_overlap = overlap
            best_axis = l
            best_is_a = True
            best_j = j
    for j in range(3):
        var l = axb[j]
        var overlap = _proj_radius(axa, ha, l) + _proj_radius(axb, hb, l) - abs(
            dot(t, l)
        )
        if overlap < 0:
            return ContactManifold[3].miss()
        if overlap < best_overlap:
            best_overlap = overlap
            best_axis = l
            best_is_a = False
            best_j = j
    var best_edge_axis = Vec3(0, 0, 0)
    var best_edge_overlap = Real(1e30)
    for ja in range(3):
        for jb in range(3):
            var l = _cross3v(axa[ja], axb[jb])
            var ll = dot(l, l)
            if ll < Real(1e-10):
                continue  # near-parallel edges: face axes cover this
            l = l / sqrt(ll)
            var overlap = _proj_radius(axa, ha, l) + _proj_radius(
                axb, hb, l
            ) - abs(dot(t, l))
            if overlap < 0:
                return ContactManifold[3].miss()
            if overlap < best_edge_overlap:
                best_edge_overlap = overlap
                best_edge_axis = l
    if best_edge_overlap < best_overlap * Real(0.95):
        # Edge-edge contact: single point midway between the closest edges.
        var n = best_edge_axis
        if dot(t, n) < 0:
            n = -n
        # supporting corners along +-n, then closest points of the two edges
        var pa = ca
        for j in range(3):
            var d = dot(axa[j], n)
            pa = pa + axa[j] * (ha[j] * (Real(1) if d > 0 else Real(-1)))
        var pb = cb
        for j in range(3):
            var d = dot(axb[j], n)
            pb = pb + axb[j] * (hb[j] * (Real(-1) if d > 0 else Real(1)))
        var m = ContactManifold[3].hit_along(n)
        m.add((pa + pb) * Real(0.5), best_edge_overlap)
        return m
    # Face contact: clip incident against reference.
    if best_is_a:
        var sign = Real(1) if dot(t, best_axis) >= 0 else Real(-1)
        var n = best_axis * sign  # a -> b
        return _face_manifold(ca, axa, ha, cb, axb, hb, best_j, sign, n)
    else:
        # reference face on B; its outward normal points toward A (= -n).
        var sign = Real(1) if dot(-t, best_axis) >= 0 else Real(-1)
        var n = best_axis * (-sign)  # a -> b
        return _face_manifold(cb, axb, hb, ca, axa, ha, best_j, sign, n)
