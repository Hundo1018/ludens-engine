"""ROADMAP 17.53: query prefilter, batch dispatch, ray traversal.

1. 1024 rays against N random static colliders (N = 16 .. 4096): the linear
   candidate scan (`ray_cast`) vs a `QueryIndex` built once (BVH prefilter,
   build time included in its row) -- where the crossover is.
2. `ray_cast_batch` serial vs parallel dispatch, N = 4096.
3. A 1 km diagonal ray over a 1024 x 1024 heightfield (1 m cells): triangle
   candidates from the old segment-AABB query vs the grid DDA, and the cost
   of one ray each way.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3, length
from geometry.aabb import AABB
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter, ray_cast, ray_cast_indexed, QueryIndex
from scheduler.dispatch import Dispatch
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

    var tb = BenchTable("ray_cast_batch (17.53): 1024 rays, N = 4096")
    var sc = _world(4096)
    var r = _rays(4096)
    var ro4 = r[0].copy()
    var rd4 = r[1].copy()
    var t3 = Int(perf_counter_ns())
    _ = sc.ray_cast_batch(ro4, rd4, 1e4, ALL)
    var t4 = Int(perf_counter_ns())
    _ = sc.ray_cast_batch(ro4, rd4, 1e4, ALL, Dispatch.parallel())
    var t5 = Int(perf_counter_ns())
    _ = sc.query_index()
    var t5b = Int(perf_counter_ns())
    tb.add("serial", 4096, "ray", t4 - t3, RAYS)
    tb.add("parallel dispatch", 4096, "ray", t5 - t4, RAYS)
    tb.add("of which: QueryIndex build (once per batch)", 4096, "ray", t5b - t5, RAYS)
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
