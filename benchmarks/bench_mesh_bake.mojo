"""Collision-mesh baking and mesh SDFs (ROADMAP 17.45): what each stage costs.

Rows:
  weld / repair / simplify  `geometry.mesh_bake` on a bumpy grid exported with
              split vertices (6 per quad), N = triangles in. simplify targets
              N / 8 under a 0.05 error budget (it stops at the budget).
  active edges  the per-triangle crease flags.
  sdf bake    `geometry.sdf_grid.bake_sdf_grid` of a 512-triangle sphere at
              res^3 (brute force over triangles: res^3 x T).
  sdf sample vs exact  one distance query: trilinear SdfGrid sample vs a scan
              of closest-point-on-triangle over all 512 triangles -- the
              trade the grid buys (sampling no longer depends on T).

Run with: `mojo run -I build benchmarks/bench_mesh_bake.mojo`.
"""

from std.math import sin, sqrt
from std.benchmark import keep
from geometry.vec import Real, Vec3, length, normalize
from geometry.mesh_bake import weld, repair, simplify, active_edges
from geometry.sdf_grid import bake_sdf_grid, closest_on_triangle
from harness.bench import BenchTable, now


def _split_grid(n: Int) -> Tuple[List[Real], List[Int]]:
    var v = List[Real]()
    var ix = List[Int]()
    for j in range(n):
        for i in range(n):
            var c: List[Int] = [i, j, i, j + 1, i + 1, j, i + 1, j, i, j + 1, i + 1, j + 1]
            for k in range(6):
                var x = Real(c[2 * k]) * 0.5
                var z = Real(c[2 * k + 1]) * 0.5
                v.append(x)
                v.append(Real(0.3) * sin(x * 0.7) * sin(z * 0.5))
                v.append(z)
                ix.append(len(ix))
    return (v^, ix^)


def _sphere(levels: Int) -> Tuple[List[Real], List[Int]]:
    var pts = List[Vec3]()
    pts.append(Vec3(1, 0, 0, 0)); pts.append(Vec3(-1, 0, 0, 0))
    pts.append(Vec3(0, 1, 0, 0)); pts.append(Vec3(0, -1, 0, 0))
    pts.append(Vec3(0, 0, 1, 0)); pts.append(Vec3(0, 0, -1, 0))
    var tris: List[Int] = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]
    for _ in range(levels):
        var nt = List[Int]()
        for t in range(len(tris) // 3):
            var a = tris[3 * t]
            var b = tris[3 * t + 1]
            var c = tris[3 * t + 2]
            pts.append(normalize(pts[a] + pts[b]))
            var ab = len(pts) - 1
            pts.append(normalize(pts[b] + pts[c]))
            var bc = len(pts) - 1
            pts.append(normalize(pts[c] + pts[a]))
            var ca = len(pts) - 1
            nt.append(a); nt.append(ab); nt.append(ca)
            nt.append(ab); nt.append(b); nt.append(bc)
            nt.append(ca); nt.append(bc); nt.append(c)
            nt.append(ab); nt.append(bc); nt.append(ca)
        tris = nt^
    var v = List[Real]()
    for i in range(len(pts)):
        v.append(pts[i][0]); v.append(pts[i][1]); v.append(pts[i][2])
    return (v^, tris^)


def main():
    var t = BenchTable("Collision-mesh baking: stage cost (N = triangles in)")
    for n in [16, 32, 64]:
        var g = _split_grid(n)
        var tris = 2 * n * n
        var t0 = now()
        var w = weld(g[0], g[1], 1e-4)
        var t1 = now()
        t.add("weld (split vertices)", tris, "mesh", t1 - t0, 1)
        var v = w[0].copy()
        var ix = w[1].copy()
        t0 = now()
        var r = repair(v, ix)
        t1 = now()
        keep(r.open_edges)
        t.add("repair", tris, "mesh", t1 - t0, 1)
        t0 = now()
        var act = active_edges(v, ix, 0.0872664626)
        t1 = now()
        keep(len(act))
        t.add("active edges", tris, "mesh", t1 - t0, 1)
        t0 = now()
        var sr = simplify(v, ix, tris // 8, 0.05)
        t1 = now()
        keep(sr[0])
        t.add("simplify (QEM, -> budget 0.05)", tris, "mesh", t1 - t0, 1)
    t.print_report()

    var s = BenchTable("Mesh SDF: bake once, then sample (512-triangle sphere)")
    var m = _sphere(3)
    var mv = m[0].copy()
    var mi = m[1].copy()
    for res in [8, 16]:
        var t0 = now()
        var grid = bake_sdf_grid(mv, mi, res, 0.5)
        var t1 = now()
        s.add("sdf bake res^3", res, "grid", t1 - t0, 1)
        keep(grid.values[0])
    var grid = bake_sdf_grid(mv, mi, 16, 0.5)
    var q = 10000
    var t0 = now()
    var acc = Real(0)
    for i in range(q):
        var p = Vec3(Real(i % 31) * 0.1 - 1.5, Real(i % 17) * 0.17 - 1.4, Real(i % 13) * 0.2 - 1.2, 0)
        acc += grid.distance(p)
    var t1 = now()
    keep(acc)
    s.add("sample: SdfGrid trilinear", 512, "query", t1 - t0, q)
    var q2 = 1000
    t0 = now()
    acc = 0
    for i in range(q2):
        var p = Vec3(Real(i % 31) * 0.1 - 1.5, Real(i % 17) * 0.17 - 1.4, Real(i % 13) * 0.2 - 1.2, 0)
        var best = Real(1e30)
        for tt in range(len(mi) // 3):
            var ia = mi[3 * tt]
            var ib = mi[3 * tt + 1]
            var ic = mi[3 * tt + 2]
            var a = Vec3(mv[3 * ia], mv[3 * ia + 1], mv[3 * ia + 2], 0)
            var b = Vec3(mv[3 * ib], mv[3 * ib + 1], mv[3 * ib + 2], 0)
            var c = Vec3(mv[3 * ic], mv[3 * ic + 1], mv[3 * ic + 2], 0)
            best = min(best, length(closest_on_triangle(p, a, b, c) - p))
        acc += best
    t1 = now()
    keep(acc)
    s.add("sample: exact scan over triangles", 512, "query", t1 - t0, q2)
    s.print_report()
