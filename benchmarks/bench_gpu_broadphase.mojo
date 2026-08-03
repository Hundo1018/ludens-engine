"""GPU all-pairs broadphase vs the CPU acceleration structures.

The CPU structures win by doing FEWER tests; the device wins by doing more
tests per unit time. Which strategy pays depends on N and on what the structure
costs to build, so the sweep is over N with the same scene fed to every path.

Both GPU rows are shown because the distinction matters for how this could be
used: `gpu total` includes uploading the boxes and reading the pairs back,
which is what a CPU-side caller actually pays; a resident-data pipeline that
kept boxes on the device would pay closer to the kernel alone. Pair sets are
identical to brute force (`test_gpu_broadphase`); only the output ORDER differs,
which is why this cannot be dropped into `solver6` without a sort.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from std.benchmark import keep
from harness.bench import BenchTable
from scheduler.rng import Pcg32, Rng
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from collision.broadphase import BruteForce, Pair, BoxProxy
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_bvh import BVHBroadPhase
from collision.bp_sap import SapBroadPhase
from collision.bp_gpu import gpu_pairs_ctx

comptime REPS = 3


def _scene(n: Int, extent: Real) -> List[BoxProxy[3]]:
    var rng = Pcg32.seeded(5)
    var out = List[BoxProxy[3]]()
    for i in range(n):
        var c = Vec3(
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
        )
        out.append(BoxProxy[3](i, AABB[3](c - Vec3(0.5, 0.5, 0.5), c + Vec3(0.5, 0.5, 0.5))))
    return out^


def _cpu_row(mut t: BenchTable, name: String, items: List[BoxProxy[3]], n: Int, kind: Int) raises:
    var best = Int.MAX
    var count = 0
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var out = List[Pair]()
        if kind == 0:
            var bp = BruteForce[3]()
            bp.rebuild(items)
            bp.pairs(out)
        elif kind == 1:
            var bp = SpatialHashBroadPhase[3](2.0)
            bp.rebuild(items)
            bp.pairs(out)
        elif kind == 2:
            var bp = BVHBroadPhase[3]()
            bp.rebuild(items)
            bp.pairs(out)
        else:
            var bp = SapBroadPhase[3]()
            bp.rebuild(items)
            bp.pairs(out)
        var dt = Int(perf_counter_ns()) - t0
        count = len(out)
        if dt < best:
            best = dt
    t.add(name + " p=" + String(count), n, "frame", best, 1)


def _gpu_row[N: Int](mut t: BenchTable, mut ctx: DeviceContext, items: List[BoxProxy[3]]) raises:
    var best = Int.MAX
    var count = 0
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var out = List[Pair]()
        var ok = gpu_pairs_ctx[N, 1 << 20](ctx, items, out)
        keep(ok)
        var dt = Int(perf_counter_ns()) - t0
        count = len(out)
        if dt < best:
            best = dt
    t.add("gpu all-pairs (total) p=" + String(count), N, "frame", best, 1)


def main() raises:
    var t = BenchTable("Broadphase: GPU all-pairs vs CPU structures")

    comptime for si in range(3):
        comptime N = 512 if si == 0 else (2048 if si == 1 else 8192)
        # extents chosen so density (and therefore the pair count per box)
        # stays roughly constant as N grows: extent ~ N^(1/3)
        comptime EXT: Real = Real(24.0 if si == 0 else (38.0 if si == 1 else 60.0))
        var items = _scene(N, EXT)
        _cpu_row(t, "cpu brute", items, N, 0)
        _cpu_row(t, "cpu hashgrid", items, N, 1)
        _cpu_row(t, "cpu bvh", items, N, 2)
        _cpu_row(t, "cpu sap", items, N, 3)

    comptime if has_accelerator():
        var ctx = DeviceContext()
        # burn JIT + first-launch cost outside the timed rows
        var warm = List[Pair]()
        var w512 = _scene(512, 20.0)
        _ = gpu_pairs_ctx[512, 1 << 16](ctx, w512, warm)

        var i512 = _scene(512, 24.0)
        _gpu_row[512](t, ctx, i512)
        var i2048 = _scene(2048, 38.0)
        _gpu_row[2048](t, ctx, i2048)
        var i8192 = _scene(8192, 60.0)
        _gpu_row[8192](t, ctx, i8192)
    else:
        print("(no accelerator: CPU rows only)")

    t.print_report()
