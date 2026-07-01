"""Scene-query benchmark: raycast & overlap across the four query backends.

A fixed random scene (same seed per backend, so identical workloads) of N boxes
is queried with M rays and M overlap boxes. BVH uses true ray traversal; grid and
loose-tree gather candidates from the ray's / query's AABB then exact-test; brute
force tests everything. All backends return identical results (see `test_queries`);
the table shows the cost. Note BVH's per-node ray pruning beats the AABB-gather
backends for raycasts, while the spatial indexes win overlap over brute force.
Run: `mojo run -I build benchmarks/bench_queries.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import WorldType, Real, normalize
from geometry.aabb import AABB
from geometry.ray import Ray
from collision.broadphase import BoxProxy
from collision.queries import (
    SceneQuery,
    BruteForceQuery,
    BvhQuery,
    GridQuery,
    TreeQuery,
)
from scheduler.rng import XorShift64, range_f

comptime AREA = Real(40)
comptime MAXT = Real(60)


def scatter[D: Int](mut rng: XorShift64, n: Int) -> List[BoxProxy[D]]:
    var items = List[BoxProxy[D]]()
    for i in range(n):
        var c = SIMD[WorldType, D](0)
        comptime for k in range(D):
            c[k] = range_f(rng, 0, AREA)
        items.append(BoxProxy[D](i, AABB[D].from_center(c, SIMD[WorldType, D](0.5))))
    return items^


def make_rays[D: Int](mut rng: XorShift64, m: Int) -> List[Ray[D]]:
    var rays = List[Ray[D]]()
    for i in range(m):
        var o = SIMD[WorldType, D](0)
        var d = SIMD[WorldType, D](0)
        comptime for k in range(D):
            o[k] = range_f(rng, 0, AREA)
            d[k] = range_f(rng, -1, 1)
        rays.append(Ray[D](o, normalize(d), MAXT))
    return rays^


def make_boxes[D: Int](mut rng: XorShift64, m: Int) -> List[AABB[D]]:
    var boxes = List[AABB[D]]()
    for i in range(m):
        var c = SIMD[WorldType, D](0)
        comptime for k in range(D):
            c[k] = range_f(rng, 0, AREA)
        boxes.append(AABB[D].from_center(c, SIMD[WorldType, D](2)))
    return boxes^


def bench_raycast[Q: SceneQuery](mut table: BenchTable, variant: String, n: Int, m: Int) raises:
    var rng = XorShift64.seeded(123)
    var items = scatter[Q.dim](rng, n)
    var rays = make_rays[Q.dim](rng, m)
    var q = Q()
    q.rebuild(items)
    var hits = 0
    var t0 = now()
    for i in range(len(rays)):
        var h = q.raycast(rays[i])
        if h.hit:
            hits += 1
        keep(h.proxy)
    var t1 = now()
    keep(hits)
    table.add(variant, n, "raycast", t1 - t0, m)


def bench_overlap[Q: SceneQuery](mut table: BenchTable, variant: String, n: Int, m: Int) raises:
    var rng = XorShift64.seeded(123)
    var items = scatter[Q.dim](rng, n)
    var boxes = make_boxes[Q.dim](rng, m)
    var q = Q()
    q.rebuild(items)
    var total = 0
    var t0 = now()
    for i in range(len(boxes)):
        var out = List[Int]()
        q.overlap(boxes[i], out)
        total += len(out)
    var t1 = now()
    keep(total)
    table.add(variant, n, "overlap", t1 - t0, m)


def main() raises:
    var n = 1500
    var m = 1500

    var rc = BenchTable("Scene raycast — brute vs BVH vs grid vs tree")
    bench_raycast[BruteForceQuery[2]](rc, "brute", n, m)
    bench_raycast[BvhQuery[2]](rc, "bvh", n, m)
    bench_raycast[GridQuery[2]](rc, "grid", n, m)
    bench_raycast[TreeQuery[2]](rc, "tree", n, m)
    rc.print_report()

    var ov = BenchTable("Scene overlap — brute vs BVH vs grid vs tree")
    bench_overlap[BruteForceQuery[2]](ov, "brute", n, m)
    bench_overlap[BvhQuery[2]](ov, "bvh", n, m)
    bench_overlap[GridQuery[2]](ov, "grid", n, m)
    bench_overlap[TreeQuery[2]](ov, "tree", n, m)
    ov.print_report()
