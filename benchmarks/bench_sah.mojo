"""BVH build heuristic: median-split vs binned SAH.

`test_sah` proves the two builds answer every query identically; this table
shows the trade: SAH pays more at BUILD time to cut a TIGHTER tree (lower
Σ node area), which is repaid in cheaper queries — but only when the scene
has empty space to exploit. Clustered scene = SAH wins queries; uniform
scene = trees are near-identical, so SAH's pricier build is not repaid
(honesty rows). Amortisation depends on queries-per-build.
"""

from std.math import sqrt
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import WorldType, Real, Vec3
from geometry.aabb import AABB
from geometry.bvh import BVH, _Leaf
from geometry.ray import Ray
from scheduler.rng import XorShift64, range_f

comptime N = 2000
comptime M = 4000


def _scene(mut rng: XorShift64, clustered: Bool) -> List[_Leaf[3]]:
    var leaves = List[_Leaf[3]]()
    for i in range(N):
        var cx = Real(0)
        var cy = Real(0)
        var cz = Real(0)
        if clustered and i % 5 != 0:
            var c = i % 3
            var bx = Real(c) * 20 - 20
            cx = bx + range_f(rng, -1.5, 1.5)
            cy = range_f(rng, -1.5, 1.5)
            cz = bx + range_f(rng, -1.5, 1.5)
        else:
            cx = range_f(rng, -40, 40)
            cy = range_f(rng, -40, 40)
            cz = range_f(rng, -40, 40)
        var half = SIMD[WorldType, 3](range_f(rng, 0.2, 0.8))
        leaves.append(_Leaf[3](AABB[3].from_center(Vec3(cx, cy, cz), half), i))
    return leaves^


def _rays(mut rng: XorShift64) -> List[Ray[3]]:
    var rays = List[Ray[3]]()
    for _ in range(M):
        var o = Vec3(
            range_f(rng, -50, 50), range_f(rng, -50, 50), range_f(rng, -50, 50)
        )
        var d = Vec3(
            range_f(rng, -1, 1), range_f(rng, -1, 1), range_f(rng, -1, 1)
        )
        var dl = sqrt(
            Float64(d[0]) ** 2 + Float64(d[1]) ** 2 + Float64(d[2]) ** 2
        )
        if dl < 1e-6:
            dl = 1
        rays.append(Ray[3](o, d / Real(dl), 300))
    return rays^


def _build_ns(leaves: List[_Leaf[3]], sah: Bool) raises -> Int:
    # rebuild several times so the timing is above the clock's noise floor
    var t0 = Int(perf_counter_ns())
    for _ in range(20):
        var b = BVH[3]()
        var copy = List[_Leaf[3]]()
        for i in range(len(leaves)):
            copy.append(leaves[i])
        b.build(copy^, sah)
    return (Int(perf_counter_ns()) - t0) // 20


def _query_ns(bvh: BVH[3], rays: List[Ray[3]]) raises -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = 0
    for i in range(len(rays)):
        acc += bvh.raycast(rays[i]).proxy
    _ = acc
    return Int(perf_counter_ns()) - t0


def _row(mut t: BenchTable, label: String, clustered: Bool) raises:
    var sr = XorShift64(0xC0FFEE)
    var leaves = _scene(sr, clustered)
    var med = BVH[3]()
    var sah = BVH[3]()
    var lm = List[_Leaf[3]]()
    var ls = List[_Leaf[3]]()
    for i in range(len(leaves)):
        lm.append(leaves[i])
        ls.append(leaves[i])
    med.build(lm^, sah=False)
    sah.build(ls^, sah=True)
    var qr = XorShift64(0xBEEF)
    var rays = _rays(qr)
    print(
        "  [" + label + "] Σarea median", Float64(med.cost()),
        " SAH", Float64(sah.cost()),
        " ratio", Float64(sah.cost()) / Float64(med.cost()),
    )
    t.add(label + " build median", N, "build", _build_ns(leaves, False), 1)
    t.add(label + " build SAH", N, "build", _build_ns(leaves, True), 1)
    t.add(label + " raycast median", M, "ray", _query_ns(med, rays), M)
    t.add(label + " raycast SAH", M, "ray", _query_ns(sah, rays), M)


def main() raises:
    var t = BenchTable("BVH build heuristic: median vs binned SAH")
    _row(t, "clustered", True)
    _row(t, "uniform", False)
    t.print_report()
