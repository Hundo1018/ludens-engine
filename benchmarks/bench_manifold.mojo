"""Manifold narrowphase benchmark: full contact-patch generation vs boolean test.

`bench_collision` prices the boolean hit/no-hit predicate (`NarrowPhase.test`);
the contact solver, however, pays for `test_manifold` — clipped contact points
with per-point depths (`ManifoldNarrowPhase`, parity vs the boolean paths in
`test_manifold`). Same deterministic scenes, same candidate pairs: each manifold
row sits next to its boolean twin, so the table reads as "what the contact
patch costs on top of the predicate", per pair.
Run with: `mojo run -I build benchmarks/bench_manifold.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Vec2, Vec3, Real
from geometry.aabb import AABB2, AABB3
from geometry.shape import Polygon
from geometry.gjk import ConvexPoly
from geometry.obb import OBB
from collision.broadphase import BruteForce, Pair, BoxProxy
from collision.narrowphase import (
    NarrowPhase,
    AABBNarrowPhase,
    SATNarrowPhase,
    OBBNarrowPhase,
    GJKNarrowPhase,
)
from collision.manifold import (
    ManifoldNarrowPhase,
    AABBManifoldNarrowPhase,
    SATManifoldNarrowPhase,
    OBBManifoldNarrowPhase,
    GjkManifoldNarrowPhase,
)
from harness.bench import BenchTable, now


struct Rng(Movable):
    """A tiny LCG so scenes are deterministic across variants."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_f(mut self) -> Real:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.state >> 16) % 1_000_000) / 1_000_000.0)


def scene2(n: Int, extent: Real, half: Real) -> List[BoxProxy[2]]:
    var rng = Rng(0x1234)
    var items = List[BoxProxy[2]]()
    for i in range(n):
        var cx = rng.next_f() * extent
        var cy = rng.next_f() * extent
        items.append(
            BoxProxy[2](i, AABB2(Vec2(cx - half, cy - half), Vec2(cx + half, cy + half)))
        )
    return items^


def scene3(n: Int, extent: Real, half: Real) -> List[BoxProxy[3]]:
    var rng = Rng(0x1234)
    var items = List[BoxProxy[3]]()
    for i in range(n):
        var cx = rng.next_f() * extent
        var cy = rng.next_f() * extent
        var cz = rng.next_f() * extent
        items.append(
            BoxProxy[3](
                i,
                AABB3(
                    Vec3(cx - half, cy - half, cz - half),
                    Vec3(cx + half, cy + half, cz + half),
                ),
            )
        )
    return items^


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
    table.add(variant + " hits=" + String(hits), n, "boolean", t1 - t0, len(pairs))


def run_mnp[
    MNP: ManifoldNarrowPhase
](mut table: BenchTable, variant: String, np: MNP, pairs: List[Pair], n: Int):
    var pts = 0
    var t0 = now()
    for k in range(len(pairs)):
        var m = np.test_manifold(pairs[k].a, pairs[k].b)
        if m.hit:
            pts += m.count
    keep(pts)
    var t1 = now()
    table.add(variant + " pts=" + String(pts), n, "manifold", t1 - t0, len(pairs))


def bench_2d(mut table: BenchTable, n: Int) raises:
    var extent = Real(Float64(n) ** 0.5) * 3.0
    var items = scene2(n, extent, 1.0)

    var bf = BruteForce[2]()
    bf.rebuild(items)
    var pairs = List[Pair]()
    bf.pairs(pairs)

    var ba = AABBNarrowPhase[2]()
    var ma = AABBManifoldNarrowPhase[2]()
    var bs = SATNarrowPhase()
    var ms = SATManifoldNarrowPhase()
    var bo = OBBNarrowPhase()
    var mo = OBBManifoldNarrowPhase()
    for i in range(n):
        var b = items[i].box
        var c = b.center()
        var h = b.half_extents()
        _ = ba.add(b)
        _ = ma.add(b)
        _ = bs.add(Polygon.box(c[0], c[1], h[0], h[1]))
        _ = ms.add(Polygon.box(c[0], c[1], h[0], h[1]))
        _ = bo.add(OBB(c, h, 0))
        _ = mo.add(OBB(c, h, 0))

    run_np(table, "2d aabb bool", ba, pairs, n)
    run_mnp(table, "2d aabb manifold", ma, pairs, n)
    run_np(table, "2d sat bool", bs, pairs, n)
    run_mnp(table, "2d sat manifold", ms, pairs, n)
    run_np(table, "2d obb bool", bo, pairs, n)
    run_mnp(table, "2d obb manifold", mo, pairs, n)


def box_poly3(c: Vec3, h: Vec3) -> ConvexPoly[3]:
    var cp = ConvexPoly[3]()
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                cp.add(
                    Vec3(
                        c[0] + h[0] * (Real(1) if sx == 1 else Real(-1)),
                        c[1] + h[1] * (Real(1) if sy == 1 else Real(-1)),
                        c[2] + h[2] * (Real(1) if sz == 1 else Real(-1)),
                    )
                )
    return cp^


def bench_3d(mut table: BenchTable, n: Int) raises:
    var extent = Real(Float64(n) ** (1.0 / 3.0)) * 3.0
    var items = scene3(n, extent, 1.0)

    var bf = BruteForce[3]()
    bf.rebuild(items)
    var pairs = List[Pair]()
    bf.pairs(pairs)

    var ba = AABBNarrowPhase[3]()
    var ma = AABBManifoldNarrowPhase[3]()
    var bg = GJKNarrowPhase[3]()
    var mg = GjkManifoldNarrowPhase()
    for i in range(n):
        var b = items[i].box
        _ = ba.add(b)
        _ = ma.add(b)
        _ = bg.add(box_poly3(b.center(), b.half_extents()))
        _ = mg.add(box_poly3(b.center(), b.half_extents()))

    run_np(table, "3d aabb bool", ba, pairs, n)
    run_mnp(table, "3d aabb manifold", ma, pairs, n)
    run_np(table, "3d gjk+epa bool", bg, pairs, n)
    run_mnp(table, "3d gjk+epa manifold", mg, pairs, n)


def main() raises:
    var table = BenchTable("Manifold narrowphase (contact patch vs boolean, per pair)")
    bench_2d(table, 2_000)
    bench_3d(table, 2_000)
    table.print_report()
