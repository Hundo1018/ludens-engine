"""Procedural generation (ROADMAP 17.69): sampler, triangulation and terrain costs.

Poisson-disk vs dart throwing vs jittered grid on 100 x 100 at r = 2 (cost
per output point, with the point count each reaches); Delaunay of 250 /
500 / 1000 Poisson points (cost per point; the bad-triangle search is
linear, so per-point cost grows with n); terrain height per sample, plain /
ridged / domain-warped; thermal erosion per cell per pass.

Run with: `mojo run -I build benchmarks/bench_pcg.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec2
from procedural.scatter import poisson_disk, dart_throwing, jittered_grid
from procedural.delaunay import delaunay
from procedural.terrain_gen import TerrainParams, terrain_height, height_tile, thermal_erosion
from harness.bench import BenchTable, now


def main() raises:
    var t = BenchTable("Point distributions, 100 x 100, r = 2 (17.69)")
    var t0 = now()
    var a = poisson_disk(100, 100, 2, 1)
    var t1 = now()
    var b = dart_throwing(100, 100, 2, 1, 5000)
    var t2 = now()
    var c = jittered_grid(100, 100, 2, 0.25, 1)
    var t3 = now()
    t.add("poisson_disk (" + String(len(a)) + " points)", len(a), "point", t1 - t0, len(a))
    t.add("dart_throwing 5000 tries (" + String(len(b)) + " points)", len(b), "point", t2 - t1, len(b))
    t.add("jittered_grid (" + String(len(c)) + " points)", len(c), "point", t3 - t2, len(c))
    t.print_report()

    var d = BenchTable("Delaunay (Bowyer-Watson, exact predicates) (17.69)")
    var ns: List[Int] = [250, 500, 1000]
    for n in ns:
        var sub = List[Vec2]()
        for i in range(n):
            sub.append(a[i])
        var t4 = now()
        var tri = delaunay(sub)
        var t5 = now()
        keep(len(tri))
        d.add("delaunay n=" + String(n), n, "point", t5 - t4, n)
    d.print_report()

    var h = BenchTable("Terrain samples and erosion (17.69)")
    var ps: List[TerrainParams] = [TerrainParams(1, 32, 10, 5, False, 0), TerrainParams(1, 32, 10, 5, True, 0), TerrainParams(1, 32, 10, 5, False, 0.7)]
    var names: List[String] = ["fbm 5 octaves", "ridged", "domain-warped (+2 x 3 octaves)"]
    for k in range(3):
        var acc = Real(0)
        var t6 = now()
        for i in range(20000):
            acc += terrain_height(Real(i % 141) * 0.7, Real(i // 141) * 0.7, ps[k])
        var t7 = now()
        keep(acc)
        h.add(names[k], 20000, "sample", t7 - t6, 20000)
    var tile = height_tile(0, 0, 64, 64, 1, TerrainParams(3, 8, 10, 4, False, 0))
    var t8 = now()
    thermal_erosion(tile, 64, 64, 1, 0.8, 0.5, 50)
    var t9 = now()
    keep(tile[100])
    h.add("thermal_erosion 65^2, 50 passes", 65 * 65, "cell-pass", t9 - t8, 65 * 65 * 50)
    h.print_report()
