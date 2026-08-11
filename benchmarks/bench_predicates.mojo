"""Exact predicates: what the filter costs, and what the fallback costs.

Robustness is usually sold as free because "the filter almost always decides".
This table checks both halves of that claim separately, because they are very
different numbers and a scene made of degenerate geometry pays the second one.

Each predicate appears twice on the same shape of input:

  generic     random points, well separated. The float32 stage decides and
              returns; this is the price of robustness on ordinary geometry,
              measured against the naive sign test it replaces.
  degenerate  points constructed to be exactly collinear, coplanar, cocircular
              or cospherical, so both filtered stages must abstain and the
              exact expansion runs every time. This is the worst case, not the
              expected case, and it is what a fallback written for clarity
              rather than speed costs.

The last pair is the integration: `convex_hull_2d` with its side test routed
through the layer, against the same hull with the naive test, on a cloud that
is mostly one exact straight line. Both rows report their own convexity, and on
this particular cloud BOTH are convex — the naive test survives it. That is
worth stating plainly rather than quietly picking an input where it does not:
what the exact path buys is not a better answer on any one input, it is the
guarantee that there is no input where the answer is self-contradictory.
`test_predicates` measures that directly — the naive test violates cyclic
invariance on about 28% of near-degenerate triples, and the exact one on none.

Run with: `mojo run -I build benchmarks/bench_predicates.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec2, Vec3
from geometry.quickhull import convex_hull_2d
from geometry.predicates import (
    orient2d, orient3d, incircle, insphere, orient2d_naive, orient3d_naive,
)
from scheduler.rng import SplitMix64, Rng
from harness.bench import BenchTable, now

comptime N: Int = 20000


def gen2(degenerate: Bool) -> List[Real]:
    """3 * N flat (x, y) pairs: `a`, `b`, `c` per triple. Degenerate puts c
    exactly on the line through a and b, by construction rather than by
    rounding — c is a + k * (b - a) with k a power of two, which is exact."""
    var rng = SplitMix64.seeded(7)
    var out = List[Real](capacity=6 * N)
    for _ in range(N):
        var ax = Real(rng.next_f32()) * 8 - 4
        var ay = Real(rng.next_f32()) * 8 - 4
        var dx = Real(rng.next_f32()) * 4 - 2
        var dy = Real(rng.next_f32()) * 4 - 2
        out.append(ax)
        out.append(ay)
        out.append(ax + dx)
        out.append(ay + dy)
        if degenerate:
            out.append(ax + dx * 0.5)  # exact: halving is exact in binary
            out.append(ay + dy * 0.5)
        else:
            out.append(Real(rng.next_f32()) * 8 - 4)
            out.append(Real(rng.next_f32()) * 8 - 4)
    return out^


def gen3(degenerate: Bool) -> List[Real]:
    """4 * N flat (x, y, z) points. Degenerate makes all four share a plane by
    construction: three random points plus their exact midpoint combination."""
    var rng = SplitMix64.seeded(11)
    var out = List[Real](capacity=12 * N)
    for _ in range(N):
        var p = List[Real](capacity=9)
        for _ in range(9):
            p.append(Real(rng.next_f32()) * 8 - 4)
        for k in range(9):
            out.append(p[k])
        if degenerate:
            # (a + b) / 2 lies in the plane of a, b, c for any c, exactly
            out.append((p[0] + p[3]) * 0.5)
            out.append((p[1] + p[4]) * 0.5)
            out.append((p[2] + p[5]) * 0.5)
        else:
            for _ in range(3):
                out.append(Real(rng.next_f32()) * 8 - 4)
    return out^


def run2(mut table: BenchTable, name: String, d: List[Real], exact: Bool):
    var acc = 0
    var t0 = now()
    for i in range(N):
        var a = Vec2(d[6 * i], d[6 * i + 1])
        var b = Vec2(d[6 * i + 2], d[6 * i + 3])
        var c = Vec2(d[6 * i + 4], d[6 * i + 5])
        acc += orient2d(a, b, c) if exact else orient2d_naive(a, b, c)
    keep(acc)
    var t1 = now()
    table.add(name, N, "orient2d", t1 - t0, N)


def run3(mut table: BenchTable, name: String, d: List[Real], exact: Bool):
    var acc = 0
    var t0 = now()
    for i in range(N):
        var a = Vec3(d[12 * i], d[12 * i + 1], d[12 * i + 2])
        var b = Vec3(d[12 * i + 3], d[12 * i + 4], d[12 * i + 5])
        var c = Vec3(d[12 * i + 6], d[12 * i + 7], d[12 * i + 8])
        var e = Vec3(d[12 * i + 9], d[12 * i + 10], d[12 * i + 11])
        acc += orient3d(a, b, c, e) if exact else orient3d_naive(a, b, c, e)
    keep(acc)
    var t1 = now()
    table.add(name, N, "orient3d", t1 - t0, N)


def run_ic(mut table: BenchTable, name: String, reps: Int):
    """Four DISTINCT exactly-cocircular points: the axis crossings of a circle
    whose centre and radius are powers of two, so every coordinate is exact.

    A first version passed the same point twice, which looks cocircular and is
    not measuring anything: identical points make the predicate's `permanent`
    exactly zero and it returns 0 without ever reaching the expansion. The row
    read 8ns and was timing the early exit."""
    var acc = 0
    var t0 = now()
    for i in range(reps):
        var r = Real(1 << (i % 6))  # 1, 2, 4, ... all exact
        var cx = Real((i % 5) - 2)
        var cy = Real((i % 7) - 3)
        var a = Vec2(cx + r, cy)
        var b = Vec2(cx, cy + r)
        var c = Vec2(cx - r, cy)
        var e = Vec2(cx, cy - r)
        acc += incircle(a, b, c, e)
    keep(acc)
    var t1 = now()
    table.add(name, reps, "incircle", t1 - t0, reps)


def run_is(mut table: BenchTable, name: String, reps: Int):
    """Five distinct exactly-cospherical points, built the same way."""
    var acc = 0
    var t0 = now()
    for i in range(reps):
        var r = Real(1 << (i % 5))
        var cx = Real((i % 5) - 2)
        var cy = Real((i % 7) - 3)
        var cz = Real((i % 3) - 1)
        var a = Vec3(cx + r, cy, cz)
        var b = Vec3(cx, cy + r, cz)
        var c = Vec3(cx - r, cy, cz)
        var d = Vec3(cx, cy, cz + r)
        var e = Vec3(cx, cy, cz - r)
        acc += insphere(a, b, c, d, e)
    keep(acc)
    var t1 = now()
    table.add(name, reps, "insphere", t1 - t0, reps)


def bench_hull(mut table: BenchTable, exact: Bool, reps: Int) raises:
    """A cloud that is mostly one exact straight line — the input the predicate
    layer exists for."""
    var cloud = List[Vec2]()
    for i in range(200):
        var x = Real(i) * 0.0625  # exact in binary
        cloud.append(Vec2(x, x * 0.5))
    cloud.append(Vec2(7.0, 6.0))
    cloud.append(Vec2(7.0, -6.0))
    # convexity is checked OUTSIDE the timed loop: it is evidence about the
    # result, not part of what the hull builder costs
    var h0 = convex_hull_2d(cloud, exact=exact)
    var convex = True
    for i in range(len(h0)):
        if orient2d(
            h0.verts[i],
            h0.verts[(i + 1) % len(h0)],
            h0.verts[(i + 2) % len(h0)],
        ) < 0:
            convex = False
    var acc = 0
    var t0 = now()
    for _ in range(reps):
        acc += len(convex_hull_2d(cloud, exact=exact))
    keep(acc)
    var t1 = now()
    table.add(
        ("exact" if exact else "naive") + " hull verts=" + String(acc // reps)
        + (" convex" if convex else " NOT-CONVEX"),
        len(cloud), "hull", t1 - t0, reps,
    )


def main() raises:
    var g2 = gen2(False)
    var d2 = gen2(True)
    var g3 = gen3(False)
    var d3 = gen3(True)

    var table = BenchTable("Geometric predicates: filtered path vs exact fallback")
    run2(table, "orient2d naive (generic)", g2, False)
    run2(table, "orient2d robust (generic, filter decides)", g2, True)
    run2(table, "orient2d naive (degenerate)", d2, False)
    run2(table, "orient2d robust (degenerate, exact runs)", d2, True)
    run3(table, "orient3d naive (generic)", g3, False)
    run3(table, "orient3d robust (generic, filter decides)", g3, True)
    run3(table, "orient3d naive (degenerate)", d3, False)
    run3(table, "orient3d robust (degenerate, exact runs)", d3, True)
    # incircle/insphere always land on the exact path here by construction, so
    # only a few hundred reps: the 5x5 permutation sum is the slow case and
    # timing 20,000 of them would dominate the whole benchmark suite.
    run_ic(table, "incircle (cocircular, exact runs)", 2000)
    run_is(table, "insphere (cospherical, exact runs)", 200)
    table.print_report()

    var ht = BenchTable("Convex hull of a near-degenerate cloud")
    bench_hull(ht, False, 200)
    bench_hull(ht, True, 200)
    ht.print_report()
