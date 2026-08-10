"""LBVH build: CPU Morton+radix vs GPU Morton+bitonic.

Only the SORT moves to the device — it is the one expensive parallel step in an
LBVH build. The hierarchy emit stays on the host in both rows (O(n) pointer
work over an already-ordered array), so the comparison is sort-vs-sort with the
same tail, plus the transfer the GPU row has to pay.

The two sorts have different complexity on purpose: the CPU does an O(n) LSD
radix sort, the GPU an O(n log²n) bitonic one. Bitonic is the choice a
deterministic GPU sort forces (a radix scatter through atomics is not stable,
and stability is what LSD radix depends on), so the device is doing
asymptotically MORE work and has to win it back on width alone. That is the
question this table answers.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from std.benchmark import keep
from harness.bench import BenchTable
from scheduler.rng import Pcg32, Rng
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from geometry.bvh import BVH, morton_order
from geometry.gpu_lbvh import gpu_morton_order_ctx
from collision.broadphase import BoxProxy

comptime REPS = 3


def _scene(n: Int, extent: Real) -> List[BoxProxy[3]]:
    var rng = Pcg32.seeded(17)
    var out = List[BoxProxy[3]]()
    for i in range(n):
        var c = Vec3(
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
        )
        out.append(BoxProxy[3](i, AABB[3](c - Vec3(0.4, 0.4, 0.4), c + Vec3(0.4, 0.4, 0.4))))
    return out^


def _cpu_row(mut t: BenchTable, items: List[BoxProxy[3]], n: Int) raises:
    var boxes = List[AABB[3]]()
    var prox = List[Int]()
    for i in range(n):
        boxes.append(items[i].box)
        prox.append(items[i].proxy)
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var b = BVH[3]()
        b.build_boxes(boxes, prox, False, True)
        keep(len(b.nodes))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add("cpu lbvh (morton+radix, full build)", n, "build", best, 1)


def _gpu_row[N: Int, NPAD: Int](
    mut t: BenchTable, mut ctx: DeviceContext, items: List[BoxProxy[3]]
) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var order = List[Int]()
        gpu_morton_order_ctx[N, NPAD](ctx, items, order)
        # host emit from the device order, same tail as the CPU row
        var boxes = List[AABB[3]]()
        var prox = List[Int]()
        for i in range(len(order)):
            boxes.append(items[order[i]].box)
            prox.append(items[order[i]].proxy)
        var b = BVH[3]()
        # presorted emit: the device already produced the Z-order, so
        # re-running the host sort would charge this path twice
        b.build_lbvh_presorted(boxes, prox)
        keep(len(b.nodes))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add("gpu morton+bitonic (+host emit)", N, "build", best, 1)


def _cpu_sort_ns(items: List[BoxProxy[3]], n: Int) raises -> Int:
    """CPU Morton + radix sort ALONE — the step the device version replaces."""
    var boxes = List[AABB[3]]()
    for i in range(n):
        boxes.append(items[i].box)
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var o = morton_order[3](boxes)
        keep(len(o))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    return best


def _gpu_sort_ns[N: Int, NPAD: Int](
    mut ctx: DeviceContext, items: List[BoxProxy[3]]
) raises -> Int:
    """GPU Morton + bitonic sort ALONE, including transfer."""
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var order = List[Int]()
        gpu_morton_order_ctx[N, NPAD](ctx, items, order)
        keep(len(order))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    return best


def main() raises:
    var t = BenchTable("LBVH build: CPU radix sort vs GPU bitonic sort")

    comptime for si in range(4):
        comptime N = 1024 if si == 0 else (4096 if si == 1 else (16384 if si == 2 else 65536))
        comptime EXT: Real = Real(
            30.0 if si == 0 else (48.0 if si == 1 else (76.0 if si == 2 else 120.0))
        )
        var items = _scene(N, EXT)
        _cpu_row(t, items, N)

    comptime if has_accelerator():
        var ctx = DeviceContext()
        var warm = _scene(1024, 30.0)
        var wo = List[Int]()
        gpu_morton_order_ctx[1024, 1024](ctx, warm, wo)  # JIT warm-up

        var i1 = _scene(1024, 30.0)
        _gpu_row[1024, 1024](t, ctx, i1)
        var i2 = _scene(4096, 48.0)
        _gpu_row[4096, 4096](t, ctx, i2)
        var i3 = _scene(16384, 76.0)
        _gpu_row[16384, 16384](t, ctx, i3)
        # ADVANTAGE REGIME: the CPU/GPU gap closed monotonically (2.4x -> 1.4x
        # -> 1.27x), so this is where the trend is followed to its conclusion.
        var i4 = _scene(65536, 120.0)
        _gpu_row[65536, 65536](t, ctx, i4)
    else:
        print("(no accelerator: CPU rows only)")

    # SORT ALONE on both sides — the step that actually differs. The full-build
    # rows above share a hierarchy emit that dominates them, so they cannot
    # answer whether the device sort is faster; these rows can.
    t.add("cpu sort only (morton+radix)", 16384, "sort", _cpu_sort_ns(_scene(16384, 76.0), 16384), 1)
    t.add("cpu sort only (morton+radix)", 65536, "sort", _cpu_sort_ns(_scene(65536, 120.0), 65536), 1)
    comptime if has_accelerator():
        var ctx2 = DeviceContext()
        var w = _scene(1024, 30.0)
        var wo = List[Int]()
        gpu_morton_order_ctx[1024, 1024](ctx2, w, wo)
        t.add(
            "gpu sort only (morton+bitonic)", 16384, "sort",
            _gpu_sort_ns[16384, 16384](ctx2, _scene(16384, 76.0)), 1,
        )
        t.add(
            "gpu sort only (morton+bitonic)", 65536, "sort",
            _gpu_sort_ns[65536, 65536](ctx2, _scene(65536, 120.0)), 1,
        )
    t.print_report()
