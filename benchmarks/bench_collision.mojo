"""Collision benchmark: broadphase x scene, and narrowphase x scene cross matrices.

Two comparisons on randomly-generated box scenes:

  * Broadphase — feed the same N boxes to every acceleration structure
    (brute force / quadtree|octree / spatial hash / BVH) and time
    rebuild + candidate-pair generation. Run in 2D and 3D.
  * Narrowphase — take one scene's broadphase candidate pairs and run each exact
    test (AABB / circle / SAT / OBB / GJK+EPA / SDF) over them, timing per pair.
  * CGA rows — 3D sphere-sphere through the conformal-algebra narrowphase
    (`CgaSphereNarrowPhase`, parity in `test_cga_narrowphase`) vs the analytic
    euclidean test, pricing the GA-abstraction margin.

Each box becomes the equivalent shape per narrowphase (circle = bounding circle,
etc.), so hit counts vary slightly; the metric of interest is per-pair cost.
Run with: `mojo run -I build benchmarks/bench_collision.mojo`.
"""

from std.math import sqrt
from std.benchmark import keep
from geometry.vec import Vec2, Vec3, Real, distance_sq, length, normalize
from geometry.aabb import AABB, AABB2, AABB3
from geometry.shape import Circle, Polygon, Sphere
from geometry.gjk import ConvexPoly
from geometry.obb import OBB
from geometry.sdf import SdfShape
from collision.broadphase import BroadPhase, BruteForce, Pair, BoxProxy
from collision.bp_tree import QuadTreeBroadPhase, OctreeBroadPhase
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_bvh import BVHBroadPhase
from collision.narrowphase import (
    NarrowPhase,
    Contact,
    AABBNarrowPhase,
    CircleNarrowPhase,
    SATNarrowPhase,
    OBBNarrowPhase,
    GJKNarrowPhase,
    SDFNarrowPhase,
    CgaSphereNarrowPhase,
    CgaShapeNarrowPhase,
)
from geometry.cga import Plane3
from geometry.vec import dot
from harness.bench import BenchTable, now


struct Rng(Movable):
    """A tiny LCG so scenes are deterministic across backends."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_f(mut self) -> Real:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.state >> 16) % 1_000_000) / 1_000_000.0)


# --- scene generation --------------------------------------------------------


def scene2(n: Int, extent: Real, half: Real) -> List[BoxProxy[2]]:
    var rng = Rng(0x1234)
    var items = List[BoxProxy[2]]()
    for i in range(n):
        var cx = rng.next_f() * extent
        var cy = rng.next_f() * extent
        var lo = Vec2(cx - half, cy - half)
        var hi = Vec2(cx + half, cy + half)
        items.append(BoxProxy[2](i, AABB2(lo, hi)))
    return items^


def scene3(n: Int, extent: Real, half: Real) -> List[BoxProxy[3]]:
    var rng = Rng(0x1234)
    var items = List[BoxProxy[3]]()
    for i in range(n):
        var cx = rng.next_f() * extent
        var cy = rng.next_f() * extent
        var cz = rng.next_f() * extent
        var lo = Vec3(cx - half, cy - half, cz - half)
        var hi = Vec3(cx + half, cy + half, cz + half)
        items.append(BoxProxy[3](i, AABB3(lo, hi)))
    return items^


# --- broadphase --------------------------------------------------------------


def run_bp[
    BP: BroadPhase
](
    mut table: BenchTable,
    variant: String,
    mut bp: BP,
    items: List[BoxProxy[BP.dim]],
    n: Int,
) raises:
    var t0 = now()
    bp.rebuild(items)
    var prs = List[Pair]()
    bp.pairs(prs)
    var t1 = now()
    keep(len(prs))
    table.add(variant + " P=" + String(len(prs)), n, "rebuild+pairs", t1 - t0, n)


def bench_broadphase_2d(mut table: BenchTable, n: Int) raises:
    var extent = Real(Float64(n) ** 0.5) * 4.0  # keep density roughly constant
    var items = scene2(n, extent, 1.0)
    var bf = BruteForce[2]()
    run_bp(table, "2d brute", bf, items, n)
    var qt = QuadTreeBroadPhase(
        AABB2(Vec2(-1, -1), Vec2(extent + 1, extent + 1)), capacity=8, max_depth=8
    )
    run_bp(table, "2d quadtree", qt, items, n)
    var hg = SpatialHashBroadPhase[2](4.0)
    run_bp(table, "2d hashgrid", hg, items, n)
    var bvh = BVHBroadPhase[2]()
    run_bp(table, "2d bvh", bvh, items, n)


def bench_broadphase_3d(mut table: BenchTable, n: Int) raises:
    var extent = Real(Float64(n) ** (1.0 / 3.0)) * 4.0
    var items = scene3(n, extent, 1.0)
    var bf = BruteForce[3]()
    run_bp(table, "3d brute", bf, items, n)
    var oc = OctreeBroadPhase(
        AABB3(Vec3(-1, -1, -1), Vec3(extent + 1, extent + 1, extent + 1)),
        capacity=8,
        max_depth=8,
    )
    run_bp(table, "3d octree", oc, items, n)
    var hg = SpatialHashBroadPhase[3](4.0)
    run_bp(table, "3d hashgrid", hg, items, n)
    var bvh = BVHBroadPhase[3]()
    run_bp(table, "3d bvh", bvh, items, n)


# --- narrowphase -------------------------------------------------------------


def run_np[
    NP: NarrowPhase
](mut table: BenchTable, variant: String, np: NP, pairs: List[Pair], n: Int):
    var hits = 0
    var t0 = now()
    for k in range(len(pairs)):
        if np.test(pairs[k].a, pairs[k].b).hit:
            hits += 1
    keep(hits)
    var t1 = now()
    table.add(variant + " hits=" + String(hits), n, "narrow test", t1 - t0, len(pairs))


def bench_narrowphase(mut table: BenchTable, n: Int) raises:
    var extent = Real(Float64(n) ** 0.5) * 3.0
    var items = scene2(n, extent, 1.0)

    # Candidate pairs (shared by every narrowphase) from a brute-force broadphase.
    var bf = BruteForce[2]()
    bf.rebuild(items)
    var pairs = List[Pair]()
    bf.pairs(pairs)

    # Build each narrowphase with the equivalent shape per proxy (in proxy order).
    var npa = AABBNarrowPhase[2]()
    var npc = CircleNarrowPhase()
    var nps = SATNarrowPhase()
    var npo = OBBNarrowPhase()
    var npg = GJKNarrowPhase[2]()
    var npd = SDFNarrowPhase()
    for i in range(n):
        var b = items[i].box
        var c = b.center()
        var h = b.half_extents()
        _ = npa.add(b)
        _ = npc.add(Circle(c, h[0]))
        _ = nps.add(Polygon.box(c[0], c[1], h[0], h[1]))
        _ = npo.add(OBB(c, h, 0))
        var cp = ConvexPoly[2]()
        cp.add(Vec2(c[0] - h[0], c[1] - h[1]))
        cp.add(Vec2(c[0] + h[0], c[1] - h[1]))
        cp.add(Vec2(c[0] + h[0], c[1] + h[1]))
        cp.add(Vec2(c[0] - h[0], c[1] + h[1]))
        _ = npg.add(cp^)
        _ = npd.add(SdfShape.box(c, h))

    run_np(table, "aabb", npa, pairs, n)
    run_np(table, "circle", npc, pairs, n)
    run_np(table, "sat", nps, pairs, n)
    run_np(table, "obb", npo, pairs, n)
    run_np(table, "gjk+epa", npg, pairs, n)
    run_np(table, "sdf", npd, pairs, n)


struct SphereNarrowPhase(NarrowPhase):
    """Analytic euclidean sphere-sphere — bench-local baseline for the CGA rows
    (the two paths' parity is asserted in `test_cga_narrowphase`)."""

    comptime dim: Int = 3
    var spheres: List[Sphere]

    def __init__(out self):
        self.spheres = List[Sphere]()

    def add(mut self, s: Sphere) -> Int:
        self.spheres.append(s)
        return len(self.spheres) - 1

    def test(self, a: Int, b: Int) -> Contact[3]:
        var sa = self.spheres[a]
        var sb = self.spheres[b]
        var rsum = sa.radius + sb.radius
        var d_sq = distance_sq(sa.center, sb.center)
        if d_sq > rsum * rsum:
            return Contact[3].miss()
        var dist = sqrt(d_sq) if d_sq > 0 else Real(0)
        var delta = sb.center - sa.center
        var n = normalize(delta) if dist > 0 else Vec3(1, 0, 0)
        return Contact[3](True, n, rsum - dist)


def bench_narrowphase_sphere(mut table: BenchTable, n: Int) raises:
    """Sphere-sphere: analytic euclidean vs conformal GA (same spheres, same
    candidate pairs)."""
    var extent = Real(Float64(n) ** (1.0 / 3.0)) * 3.0
    var items = scene3(n, extent, 1.0)
    var bf = BruteForce[3]()
    bf.rebuild(items)
    var pairs = List[Pair]()
    bf.pairs(pairs)

    var npe = SphereNarrowPhase()
    var npcga = CgaSphereNarrowPhase()
    for i in range(n):
        var b = items[i].box
        var s = Sphere(b.center(), b.half_extents()[0])
        _ = npe.add(s)
        _ = npcga.add(s)

    run_np(table, "3d sphere analytic", npe, pairs, n)
    run_np(table, "3d sphere cga", npcga, pairs, n)


struct EuclidShapeNarrowPhase(NarrowPhase):
    """The control group for the CGA heterogeneous rows: the same sphere+plane
    registry answered by hand-written euclidean formulas behind an explicit
    kind switch. This is the "ten if-else branches" code that the unified-meet
    argument claims to beat, written as well as it reasonably can be — same
    registry layout, same dispatch shape, same formulas.

    Hit counts are printed per row and land within ~0.3% of each other rather
    than matching exactly. That gap is itself a result: this path computes the
    centre distance directly, while the CGA path RECONSTRUCTS it as
    `d² = r₁² + r₂² − 2·S₁·S₂`, a subtraction of similar magnitudes that loses
    precision and flips a handful of pairs sitting exactly on the touching
    boundary. `test_cga_narrowphase` still passes because it asserts parity on
    configurations that are not borderline."""

    comptime dim: Int = 3
    var kinds: List[Int]  # 0 = sphere, 1 = plane
    var spheres: List[Sphere]
    var planes: List[Plane3]
    var slot: List[Int]

    def __init__(out self):
        self.kinds = List[Int]()
        self.spheres = List[Sphere]()
        self.planes = List[Plane3]()
        self.slot = List[Int]()

    def add(mut self, s: Sphere) -> Int:
        self.kinds.append(0)
        self.slot.append(len(self.spheres))
        self.spheres.append(s)
        return len(self.kinds) - 1

    def add_plane(mut self, p: Plane3) -> Int:
        self.kinds.append(1)
        self.slot.append(len(self.planes))
        self.planes.append(p)
        return len(self.kinds) - 1

    def _sphere_plane(self, si: Int, pi: Int, flip: Bool) -> Contact[3]:
        var sp = self.spheres[self.slot[si]]
        var pl = self.planes[self.slot[pi]]
        var dist = dot(sp.center, pl.normal) - pl.d
        if abs(dist) > sp.radius:
            return Contact[3].miss()
        var toward = pl.normal * Real(-1 if dist >= 0 else 1)
        var n = toward * Real(-1 if flip else 1)
        return Contact[3](True, n, sp.radius - abs(dist))

    def test(self, a: Int, b: Int) -> Contact[3]:
        if self.kinds[a] == 0 and self.kinds[b] == 0:
            var sa = self.spheres[self.slot[a]]
            var sb = self.spheres[self.slot[b]]
            var rsum = sa.radius + sb.radius
            var d_sq = distance_sq(sa.center, sb.center)
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
        return Contact[3].miss()


def bench_narrowphase_mixed(
    mut table: BenchTable, n: Int, n_planes: Int
) raises:
    """Heterogeneous scene: `n` spheres plus `n_planes` planes, every candidate
    pair answered by CGA inner products vs the euclidean switch. `n_planes` is
    the scaling axis — it controls how often the dispatch actually changes
    branch, which is precisely what the branchless-meet argument is about."""
    var extent = Real(Float64(n) ** (1.0 / 3.0)) * 3.0
    var items = scene3(n, extent, 1.0)

    var npe = EuclidShapeNarrowPhase()
    var npc = CgaShapeNarrowPhase()
    var proxies = List[BoxProxy[3]]()
    # interleave planes among the spheres so proxy kind alternates in pair
    # order rather than sitting in one contiguous run (a contiguous run is
    # trivially predicted and would flatter the branchy path).
    var every = (n // (n_planes + 1)) + 1
    var pi = 0
    for i in range(n):
        var b = items[i].box
        var s = Sphere(b.center(), b.half_extents()[0])
        if pi < n_planes and (i % every) == (every - 1):
            # axis-cycling planes placed through the cloud so they are hit
            var nrm = Vec3(0, 1, 0)
            if pi % 3 == 1:
                nrm = Vec3(1, 0, 0)
            elif pi % 3 == 2:
                nrm = Vec3(0, 0, 1)
            var pl = Plane3(nrm, dot(b.center(), nrm))
            _ = npe.add_plane(pl)
            _ = npc.add_plane(pl)
            pi += 1
        else:
            _ = npe.add(s)
            _ = npc.add(s)
        # a plane is unbounded; give its proxy the scene box so the broadphase
        # offers it against everything (both paths see the identical pair set)
        proxies.append(items[i])

    var bf = BruteForce[3]()
    bf.rebuild(proxies)
    var pairs = List[Pair]()
    bf.pairs(pairs)

    var tag = " (" + String(n_planes) + " planes)"
    run_np(table, "3d mixed euclid switch" + tag, npe, pairs, n)
    run_np(table, "3d mixed cga" + tag, npc, pairs, n)


def main() raises:
    var bp_table = BenchTable("Broadphase x scene (rebuild + candidate pairs)")
    bench_broadphase_2d(bp_table, 1_000)
    bench_broadphase_2d(bp_table, 4_000)
    bench_broadphase_2d(bp_table, 8_000)
    bench_broadphase_3d(bp_table, 1_000)
    bench_broadphase_3d(bp_table, 4_000)
    bp_table.print_report()

    var np_table = BenchTable("Narrowphase x scene (per-pair exact test)")
    bench_narrowphase(np_table, 500)
    bench_narrowphase(np_table, 2_000)
    bench_narrowphase_sphere(np_table, 500)
    bench_narrowphase_sphere(np_table, 2_000)
    np_table.print_report()

    # Heterogeneous scene: the case the "branchless unified meet" argument is
    # actually about. Plane count is the scaling axis (how often the dispatch
    # switches branch); 0 planes is the homogeneous control.
    var mix_table = BenchTable(
        "Heterogeneous narrowphase: CGA inner products vs a euclidean switch"
    )
    bench_narrowphase_mixed(mix_table, 2_000, 0)
    bench_narrowphase_mixed(mix_table, 2_000, 1)
    bench_narrowphase_mixed(mix_table, 2_000, 8)
    bench_narrowphase_mixed(mix_table, 2_000, 64)
    bench_narrowphase_mixed(mix_table, 2_000, 256)
    mix_table.print_report()
