# tier: unit
"""Walking Delaunay against the linear-search one (ROADMAP 17.69: point
location by walk, parity with `delaunay`).

  1. 500 random points (general position): `delaunay_walk` gives the same
     triangle set as `delaunay` (each triangle rotated to its smallest
     index, sorted), and it is Delaunay.
  2. Cocircular inputs (6 x 6 lattice, regular 12-gon + centre): both are
     Delaunay with the same triangle count (2n - 2 - hull).
  3. Duplicates: the same count as `delaunay` with every point doubled.
  4. Timing, 2000 points: walk vs linear search (printed; the walk is
     expected to win by a widening margin as n grows).
"""

from std.math import sin, cos
from std.time import perf_counter_ns
from harness.runner import Suite
from geometry.vec import Real, Vec2
from procedural.delaunay import delaunay, delaunay_walk, is_delaunay
from scheduler.rng import SplitMix64


def canon(t: List[Int]) -> List[Int]:
    var keys = List[Int]()
    for k in range(len(t) // 3):
        var a = t[3 * k]
        var b = t[3 * k + 1]
        var c = t[3 * k + 2]
        if b < a and b < c:
            var x = a
            a = b
            b = c
            c = x
        elif c < a and c < b:
            var x = a
            a = c
            c = b
            b = x
        keys.append((a * 100003 + b) * 100003 + c)
    sort(keys)
    return keys^


def main() raises:
    var s = Suite("delaunay_walk")
    var rng = SplitMix64.seeded(17)
    var pts = List[Vec2]()
    for _ in range(500):
        pts.append(Vec2(Real(rng.next_f32()) * 100, Real(rng.next_f32()) * 100))
    var a = delaunay(pts)
    var b = delaunay_walk(pts)
    var ca = canon(a)
    var cb = canon(b)
    var same = len(ca) == len(cb)
    if same:
        for k in range(len(ca)):
            same = same and ca[k] == cb[k]
    print("500 random points:", len(a) // 3, "vs", len(b) // 3, "triangles, identical sets", same)
    s.check(same and is_delaunay(pts, b), "random points: same triangle set as delaunay, Delaunay")

    var grid = List[Vec2]()
    for j in range(6):
        for i in range(6):
            grid.append(Vec2(Real(i), Real(j)))
    var gw = delaunay_walk(grid)
    var gl = delaunay(grid)
    var ring = List[Vec2]()
    ring.append(Vec2(0, 0))
    for k in range(12):
        ring.append(Vec2(cos(Real(k) * 0.5235987756), sin(Real(k) * 0.5235987756)))
    var rw = delaunay_walk(ring)
    print("lattice:", len(gw) // 3, "/", len(gl) // 3, " ring:", len(rw) // 3)
    s.check(is_delaunay(grid, gw) and len(gw) == len(gl) and len(gw) // 3 == 50, "6 x 6 lattice: Delaunay, 50 triangles")
    s.check(is_delaunay(ring, rw) and len(rw) // 3 == 12, "12-gon + centre: Delaunay, 12 triangles")

    var dbl = pts.copy()
    for p in pts:
        dbl.append(p)
    s.check(len(delaunay_walk(dbl)) == len(b), "duplicated points are skipped")

    var big = List[Vec2]()
    for _ in range(2000):
        big.append(Vec2(Real(rng.next_f32()) * 100, Real(rng.next_f32()) * 100))
    var t0 = perf_counter_ns()
    var bl = delaunay(big)
    var t1 = perf_counter_ns()
    var bw = delaunay_walk(big)
    var t2 = perf_counter_ns()
    print("2000 points: linear", Float64(t1 - t0) / 1e6, "ms  walk", Float64(t2 - t1) / 1e6, "ms")
    s.check(len(bl) == len(bw), "2000 points: same triangle count")
    s.finish()
