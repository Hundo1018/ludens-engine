"""Narrowphase: the exact contact test run on each broadphase candidate pair.

`NarrowPhase` is the swap point. Each implementation owns a per-proxy registry of
its shape kind (populate it with `add(...)`, which returns the proxy id) and
answers `test(a, b) -> Contact`. Swap implementations by instantiating
`CollisionPipeline` with a different narrowphase type.

  * `AABBNarrowPhase[dim]` — box overlap with minimum-translation penetration.
  * `CircleNarrowPhase`    — 2D circles (reuses `Circle.isintersect`).
  * `SATNarrowPhase`       — 2D convex polygons (separating axis theorem).
  * `GJKNarrowPhase[dim]`  — convex shapes in 2D/3D (boolean GJK).
  * `CgaSphereNarrowPhase` — 3D spheres via conformal geometric algebra.
"""

from std.math import sqrt
from geometry.vec import WorldType, Real, Vec2, Vec3, distance_sq, length, normalize
from geometry.aabb import AABB
from geometry.shape import Circle, Polygon, Sphere
from geometry.quickhull import convex_hull_2d
from geometry.multivector import CGA3
from geometry.cga import sphere_dual, sphere_dist_sq, plane_dual, inner, Plane3
from geometry.sat import sat_collide
from geometry.gjk import ConvexPoly
from geometry.epa import gjk_collide
from geometry.obb import OBB, obb_collide
from geometry.sdf import SdfShape, sdf_collide


@fieldwise_init
struct Contact[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var normal: SIMD[WorldType, Self.dim]  # points from a -> b
    var depth: Real

    @staticmethod
    def miss() -> Self:
        return Self(False, SIMD[WorldType, Self.dim](0), 0)


trait NarrowPhase(Movable, ImplicitlyDeletable):
    comptime dim: Int
    def test(self, a: Int, b: Int) -> Contact[Self.dim]: ...


struct AABBNarrowPhase[D: Int](NarrowPhase):
    comptime dim: Int = Self.D
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.boxes = List[AABB[Self.D]]()

    def add(mut self, box: AABB[Self.D]) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test(self, a: Int, b: Int) -> Contact[Self.D]:
        var ba = self.boxes[a]
        var bb = self.boxes[b]
        var best_depth = Real(1.0e30)
        var best_axis = 0
        comptime for k in range(Self.D):
            var lo = max(ba.min[k], bb.min[k])
            var hi = min(ba.max[k], bb.max[k])
            var overlap = hi - lo
            if overlap <= 0:
                return Contact[Self.D].miss()
            if overlap < best_depth:
                best_depth = overlap
                best_axis = k
        var n = SIMD[WorldType, Self.D](0)
        var dir = bb.center()[best_axis] - ba.center()[best_axis]
        n[best_axis] = 1 if dir >= 0 else -1
        return Contact[Self.D](True, n, best_depth)


struct CircleNarrowPhase(NarrowPhase):
    comptime dim: Int = 2
    var circles: List[Circle]

    def __init__(out self):
        self.circles = List[Circle]()

    def add(mut self, c: Circle) -> Int:
        self.circles.append(c)
        return len(self.circles) - 1

    def test(self, a: Int, b: Int) -> Contact[2]:
        var ca = self.circles[a]
        var cb = self.circles[b]
        var rsum = ca.radius + cb.radius
        if distance_sq(ca.center, cb.center) > rsum * rsum:
            return Contact[2].miss()
        var delta = cb.center - ca.center
        var dist = length(delta)
        var n = normalize(delta) if dist > 0 else Vec2(1, 0)
        return Contact[2](True, n, rsum - dist)


struct SATNarrowPhase(NarrowPhase):
    comptime dim: Int = 2
    var polys: List[Polygon]

    def __init__(out self):
        self.polys = List[Polygon]()

    def add(mut self, var p: Polygon) -> Int:
        self.polys.append(p^)
        return len(self.polys) - 1

    def add_cloud(mut self, points: List[Vec2]) raises -> Int:
        """Register a shape given as an unordered 2D point cloud.

        SAT needs a convex polygon in CCW order; a cloud is neither. This is
        the production entry point for `geometry/quickhull.mojo`, which
        discards interior and collinear points and returns exactly that. Without
        it a caller holding sampled or scanned points has no supported way in,
        and the hull code is unreachable — the case architecture law v3 names."""
        return self.add(convex_hull_2d(points))

    def test(self, a: Int, b: Int) -> Contact[2]:
        var r = sat_collide(self.polys[a], self.polys[b])
        return Contact[2](r.hit, r.normal, r.depth)


struct GJKNarrowPhase[D: Int](NarrowPhase):
    comptime dim: Int = Self.D
    var shapes: List[ConvexPoly[Self.D]]

    def __init__(out self):
        self.shapes = List[ConvexPoly[Self.D]]()

    def add(mut self, var s: ConvexPoly[Self.D]) -> Int:
        self.shapes.append(s^)
        return len(self.shapes) - 1

    def test(self, a: Int, b: Int) -> Contact[Self.D]:
        # GJK + EPA: hit plus penetration (depth/normal exact in 2D, zero in 3D).
        var r = gjk_collide[Self.D](self.shapes[a], self.shapes[b])
        return Contact[Self.D](r.hit, r.normal, r.depth)


struct OBBNarrowPhase(NarrowPhase):
    comptime dim: Int = 2
    var boxes: List[OBB]

    def __init__(out self):
        self.boxes = List[OBB]()

    def add(mut self, box: OBB) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test(self, a: Int, b: Int) -> Contact[2]:
        var r = obb_collide(self.boxes[a], self.boxes[b])
        return Contact[2](r.hit, r.normal, r.depth)


struct SDFNarrowPhase(NarrowPhase):
    comptime dim: Int = 2
    var shapes: List[SdfShape]

    def __init__(out self):
        self.shapes = List[SdfShape]()

    def add(mut self, shape: SdfShape) -> Int:
        self.shapes.append(shape)
        return len(self.shapes) - 1

    def test(self, a: Int, b: Int) -> Contact[2]:
        var r = sdf_collide(self.shapes[a], self.shapes[b])
        return Contact[2](r.hit, r.normal, r.depth)


struct CgaSphereNarrowPhase(NarrowPhase):
    """3D sphere-sphere via conformal geometric algebra (Cl(4,1)).

    Each sphere is registered as a dual-sphere vector `S = up(c) − ½r²n∞`; the
    squared center distance is then recovered PURELY from the algebra
    (`d² = r₁² + r₂² − 2·S₁·S₂` — one inner product, no coordinate case
    analysis), giving hit + penetration. Only the contact normal's direction
    needs the euclidean centers. Promoted from `experiments/exp_cga_meet.mojo`
    (see `geometry/cga.mojo`); parity vs the analytic path is asserted in
    `tests/test_cga_narrowphase.mojo`.

    Cost shape: ~4× the hand-written euclidean test (≈12 vs ≈3 ns/test — a
    dual sphere is a cached 32-float multivector vs 4 floats), which still
    vanishes under broadphase cost; choose it where the algebraic uniformity
    (same formalism for points/spheres/planes) is worth that margin.
    """

    comptime dim: Int = 3
    var spheres: List[Sphere]
    var duals: List[CGA3]  # cached dual-sphere vectors, parallel to `spheres`

    def __init__(out self):
        self.spheres = List[Sphere]()
        self.duals = List[CGA3]()

    def add(mut self, s: Sphere) -> Int:
        self.spheres.append(s)
        self.duals.append(sphere_dual(s.center, s.radius))
        return len(self.spheres) - 1

    def test(self, a: Int, b: Int) -> Contact[3]:
        var sa = self.spheres[a]
        var sb = self.spheres[b]
        var rsum = sa.radius + sb.radius
        var d_sq = sphere_dist_sq(self.duals[a], self.duals[b], sa.radius, sb.radius)
        if d_sq > rsum * rsum:
            return Contact[3].miss()
        var dist = sqrt(d_sq) if d_sq > 0 else Real(0)
        var delta = sb.center - sa.center
        var n = normalize(delta) if dist > 0 else Vec3(1, 0, 0)
        return Contact[3](True, n, rsum - dist)


struct CgaShapeNarrowPhase(NarrowPhase):
    """Heterogeneous 3D narrowphase over CGA: spheres AND infinite planes in one
    registry, every pairing answered by the same grade-1 inner products —
    sphere–sphere via `d² = r₁²+r₂²−2·S₁·S₂`, sphere–plane via `S·π = c·n − d`
    (the n∞ components annihilate, so a sphere's center-to-plane distance IS the
    scalar product of the two dual vectors). The ground-plane-plus-balls scene
    is the canonical use. Plane–plane reports a miss (unbounded contact).
    """

    comptime dim: Int = 3
    var kinds: List[Int]  # 0 = sphere, 1 = plane (parallel to both registries)
    var spheres: List[Sphere]
    var planes: List[Plane3]
    var duals: List[CGA3]  # dual vector per proxy (sphere or plane)
    var slot: List[Int]  # proxy -> index into its kind's registry

    def __init__(out self):
        self.kinds = List[Int]()
        self.spheres = List[Sphere]()
        self.planes = List[Plane3]()
        self.duals = List[CGA3]()
        self.slot = List[Int]()

    def add(mut self, s: Sphere) -> Int:
        self.kinds.append(0)
        self.slot.append(len(self.spheres))
        self.spheres.append(s)
        self.duals.append(sphere_dual(s.center, s.radius))
        return len(self.kinds) - 1

    def add_plane(mut self, p: Plane3) -> Int:
        self.kinds.append(1)
        self.slot.append(len(self.planes))
        self.planes.append(p)
        self.duals.append(plane_dual(p))
        return len(self.kinds) - 1

    def _sphere_plane(self, si: Int, pi: Int, flip: Bool) -> Contact[3]:
        """Contact between sphere proxy `si` and plane proxy `pi` (normal a→b)."""
        var sp = self.spheres[self.slot[si]]
        var pl = self.planes[self.slot[pi]]
        var dist = inner(self.duals[si], self.duals[pi])  # c·n − d, via algebra
        if abs(dist) > sp.radius:
            return Contact[3].miss()
        # normal points sphere -> plane surface; flip when the plane is `a`
        var toward = pl.normal * Real(-1 if dist >= 0 else 1)
        var n = toward * Real(-1 if flip else 1)
        return Contact[3](True, n, sp.radius - abs(dist))

    def test(self, a: Int, b: Int) -> Contact[3]:
        if self.kinds[a] == 0 and self.kinds[b] == 0:
            var sa = self.spheres[self.slot[a]]
            var sb = self.spheres[self.slot[b]]
            var rsum = sa.radius + sb.radius
            var d_sq = sphere_dist_sq(self.duals[a], self.duals[b], sa.radius, sb.radius)
            if d_sq > rsum * rsum:
                return Contact[3].miss()
            var dist = sqrt(d_sq) if d_sq > 0 else Real(0)
            var delta = sb.center - sa.center
            var n = normalize(delta) if dist > 0 else Vec3(1, 0, 0)
            return Contact[3](True, n, rsum - dist)
        if self.kinds[a] == 0 and self.kinds[b] == 1:
            return self._sphere_plane(a, b, False)
        if self.kinds[a] == 1 and self.kinds[b] == 0:
            return self._sphere_plane(b, a, True)
        return Contact[3].miss()  # plane-plane: unbounded, not a contact
