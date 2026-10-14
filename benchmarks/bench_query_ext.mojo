"""ROADMAP 17.53: query prefilter, batch dispatch, ray traversal.

1. 1024 rays against N random static colliders (N = 16 .. 4096): the linear
   candidate scan (`ray_cast`) vs a `QueryIndex` built once (BVH prefilter,
   build time included in its row) -- where the crossover is.
2. `ray_cast_batch` serial vs parallel dispatch, N = 4096: per-batch index
   build (SAH vs the LBVH default) and a prebuilt index reused for 16384
   rays (`ray_cast_batch_in`).
3. A 1 km diagonal ray over a 1024 x 1024 heightfield (1 m cells): triangle
   candidates from the old segment-AABB query vs the grid DDA, and the cost
   of one ray each way.
4. The CGA hypothesis (closed-form closest points for round primitives):
   sphere-sphere surface distance through the general GJK path the queries
   use, through the CGA inner product of two dual spheres, and through the
   euclidean centre distance; 4096 random pairs, max deviation from the
   euclidean value. (Point-circle: `bench_ga`.)
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3, length
from geometry.aabb import AABB
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter, ray_cast, ray_cast_indexed, QueryIndex
from scheduler.dispatch import Dispatch
from geometry.gjk_distance import convex_distance
from geometry.cga import sphere_dual, sphere_dist_sq
from std.math import sqrt
from scheduler.rng import SplitMix64

comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)
comptime RAYS = 1024


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _world(n: Int) raises -> ContactScene6[QuatBody6]:
    var rng = SplitMix64.seeded(17)
    var sc = ContactScene6[QuatBody6]()
    var side = Real(4) * Real(n) ** 0.3333
    for k in range(n):
        var p = Vec3((Real(rng.next_f32()) - 0.5) * side, (Real(rng.next_f32()) - 0.5) * side, (Real(rng.next_f32()) - 0.5) * side, 0)
        if k % 2 == 0:
            _ = sc.add(_st(p), Vec3(0.4, 0.4, 0.4, 0), True)
        else:
            _ = sc.add_sphere(_st(p), 0.4, True)
    return sc^


def _rays(n: Int) -> Tuple[List[Vec3], List[Vec3]]:
    var rng = SplitMix64.seeded(99)
    var o = List[Vec3]()
    var d = List[Vec3]()
    var side = Real(4) * Real(n) ** 0.3333
    for _ in range(RAYS):
        o.append(Vec3((Real(rng.next_f32()) - 0.5) * side, (Real(rng.next_f32()) - 0.5) * side, (Real(rng.next_f32()) - 0.5) * side, 0))
        var v = Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0)
        d.append(v / max(length(v), Real(1e-3)))
    return (o^, d^)


def _med(var v: List[Int]) -> Int:
    sort(v)
    return v[len(v) // 2]


def main() raises:
    var t = BenchTable("Query prefilter (17.53): 1024 rays, N static colliders")
    for n in [16, 256, 1024, 4096]:
        var sc = _world(n)
        var r = _rays(n)
        var ro = r[0].copy()
        var rd = r[1].copy()
        var poses = sc.query_poses()
        var t0 = Int(perf_counter_ns())
        var hits_a = 0
        for k in range(RAYS):
            if ray_cast(sc.colliders, poses, ro[k], rd[k], 1e4, ALL).hit:
                hits_a += 1
        var t1 = Int(perf_counter_ns())
        var idx = sc.query_index()
        var hits_b = 0
        for k in range(RAYS):
            if ray_cast_indexed(sc.colliders, idx, ro[k], rd[k], 1e4, ALL).hit:
                hits_b += 1
        var t2 = Int(perf_counter_ns())
        t.add("linear scan", n, "ray", t1 - t0, RAYS)
        t.add("QueryIndex (incl. build)", n, "ray", t2 - t1, RAYS)
        if hits_a != hits_b:
            print("MISMATCH at N", n)
    t.print_report()

    # batch dispatch: warm pool, median of 7 runs each
    var sc = _world(4096)
    var r = _rays(4096)
    var ro4 = r[0].copy()
    var rd4 = r[1].copy()
    var ro16 = List[Vec3]()
    var rd16 = List[Vec3]()
    for _ in range(16):
        for k in range(len(ro4)):
            ro16.append(ro4[k])
            rd16.append(rd4[k])
    _ = sc.ray_cast_batch(ro4, rd4, 1e4, ALL, Dispatch.parallel())
    var c_ser = List[Int]()
    var c_par = List[Int]()
    var c_sah = List[Int]()
    var c_lb = List[Int]()
    var p_ser = List[Int]()
    var p_par = List[Int]()
    for _ in range(7):
        var a = Int(perf_counter_ns())
        _ = sc.ray_cast_batch(ro4, rd4, 1e4, ALL)
        var b = Int(perf_counter_ns())
        _ = sc.ray_cast_batch(ro4, rd4, 1e4, ALL, Dispatch.parallel())
        var c = Int(perf_counter_ns())
        _ = QueryIndex(sc.colliders, sc.query_poses(), True, False)
        var d = Int(perf_counter_ns())
        var idx = sc.query_index()
        var e = Int(perf_counter_ns())
        _ = sc.ray_cast_batch_in(idx, ro16, rd16, 1e4, ALL)
        var f = Int(perf_counter_ns())
        _ = sc.ray_cast_batch_in(idx, ro16, rd16, 1e4, ALL, Dispatch.parallel())
        var g = Int(perf_counter_ns())
        c_ser.append(b - a)
        c_par.append(c - b)
        c_sah.append(d - c)
        c_lb.append(e - d)
        p_ser.append(f - e)
        p_par.append(g - f)
    var tb = BenchTable("ray_cast_batch (17.53): N = 4096 colliders, median of 7, warm thread pool")
    tb.add("1024 rays, serial (index built per batch)", 4096, "ray", _med(c_ser^), RAYS)
    tb.add("1024 rays, parallel (index built per batch)", 4096, "ray", _med(c_par^), RAYS)
    tb.add("index build, SAH (old default)", 4096, "ray", _med(c_sah^), RAYS)
    tb.add("index build, LBVH (default)", 4096, "ray", _med(c_lb^), RAYS)
    tb.add("16384 rays, prebuilt index, serial", 4096, "ray", _med(p_ser^), 16 * RAYS)
    tb.add("16384 rays, prebuilt index, parallel", 4096, "ray", _med(p_par^), 16 * RAYS)
    tb.print_report()

    var hh = List[Real]()
    var hn = 1024
    for j in range(hn):
        for i in range(hn):
            hh.append(Real(((i * 13 + j * 7) % 11)) * 0.05)
    var sh = ContactScene6[QuatBody6]()
    var hf = sh.add_heightfield(_st(Vec3(0, 0, 0, 0)), hh, hn, hn, 1.0, 0, 0)
    # from 3 m up at one corner, descending to the terrain near the far one
    var o = Vec3(0.5, 3.0, 0.3, 0)
    var d = Vec3(1000, -2.6, 1000, 0)
    d = d / length(d)
    var end = o + d * 1414
    var old_c = List[Int]()
    sh.colliders.mesh_candidates(hf.index(), AABB[3](Vec3(o[0], end[1], o[2], 0), Vec3(end[0], o[1], end[2], 0)), old_c)
    var new_c = List[Int]()
    sh.colliders.mesh_ray_candidates(hf.index(), o, d, 1414, new_c)
    var t6 = Int(perf_counter_ns())
    var h = sh.ray_cast(o, d, 1414, ALL)
    var t7 = Int(perf_counter_ns())
    print("### Heightfield ray traversal (17.53): 1 km diagonal ray, 1024 x 1024 cells\n")
    print("| candidates from segment AABB | candidates from DDA | ray_cast ns (DDA) | hit t |")
    print("|---:|---:|---:|---:|")
    print("|", len(old_c), "|", len(new_c), "|", t7 - t6, "|", h.t, "|")

    # ---- CGA hypothesis: sphere-sphere distance ----
    var rng = SplitMix64.seeded(5)
    var ca = List[Vec3]()
    var cb = List[Vec3]()
    var ra = List[Real]()
    var rb = List[Real]()
    for _ in range(4096):
        ca.append(Vec3(Real(rng.next_f32()) * 10, Real(rng.next_f32()) * 10, Real(rng.next_f32()) * 10, 0))
        cb.append(Vec3(Real(rng.next_f32()) * 10, Real(rng.next_f32()) * 10, Real(rng.next_f32()) * 10, 0))
        ra.append(Real(rng.next_f32()) * 0.5 + 0.1)
        rb.append(Real(rng.next_f32()) * 0.5 + 0.1)
    var g_ns = List[Int]()
    var c_ns = List[Int]()
    var e_ns = List[Int]()
    var dev_g = Real(0)
    var dev_c = Real(0)
    var acc = Real(0)
    for _ in range(7):
        var t_a = Int(perf_counter_ns())
        for k in range(4096):
            var pa = List[Vec3]()
            pa.append(ca[k])
            var pb = List[Vec3]()
            pb.append(cb[k])
            acc += convex_distance(pa, ra[k], pb, rb[k]).dist
        var t_b = Int(perf_counter_ns())
        for k in range(4096):
            acc += sqrt(max(sphere_dist_sq(sphere_dual(ca[k], ra[k]), sphere_dual(cb[k], rb[k]), ra[k], rb[k]), Real(0))) - ra[k] - rb[k]
        var t_c = Int(perf_counter_ns())
        for k in range(4096):
            acc += length(cb[k] - ca[k]) - ra[k] - rb[k]
        var t_d = Int(perf_counter_ns())
        g_ns.append(t_b - t_a)
        c_ns.append(t_c - t_b)
        e_ns.append(t_d - t_c)
    for k in range(4096):
        var e = length(cb[k] - ca[k]) - ra[k] - rb[k]
        var pa = List[Vec3]()
        pa.append(ca[k])
        var pb = List[Vec3]()
        pb.append(cb[k])
        dev_g = max(dev_g, abs(convex_distance(pa, ra[k], pb, rb[k]).dist - e))
        dev_c = max(dev_c, abs(sqrt(max(sphere_dist_sq(sphere_dual(ca[k], ra[k]), sphere_dual(cb[k], rb[k]), ra[k], rb[k]), Real(0))) - ra[k] - rb[k] - e))
    print("\n### CGA hypothesis (17.53): sphere-sphere surface distance, 4096 random pairs, median of 7\n")
    print("| path | ns / pair | max deviation from euclidean |")
    print("|---|---:|---:|")
    print("| GJK `convex_distance` (query path) |", Float64(_med(g_ns^)) / 4096.0, "|", dev_g, "|")
    print("| CGA dual-sphere inner product |", Float64(_med(c_ns^)) / 4096.0, "|", dev_c, "|")
    print("| euclidean centre distance |", Float64(_med(e_ns^)) / 4096.0, "| 0 |")
    if acc == 12345.678:
        print("")
