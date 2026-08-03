"""Batched GPU raycast vs the CPU BVH, swept over ray count.

The CPU BVH answers a ray in O(log n) by descending only the nodes it enters;
the kernel answers it in O(n) by testing every box, but with a ray per lane.
Ray COUNT is therefore the axis: a structure amortises its build over many
rays, while the device amortises its fixed transfer cost the same way, so the
two curves cross somewhere and the question is where.

The BVH row includes its build, because a scene query in a real frame is
issued against a structure that had to be built that frame; the GPU row
includes upload and readback for the same reason. Parity is exact — same proxy
per ray, bit-identical distances (`test_gpu_raycast`) — so this is cost-only.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from std.benchmark import keep
from harness.bench import BenchTable
from scheduler.rng import Pcg32, Rng
from geometry.vec import Real, Vec3, normalize
from geometry.aabb import AABB
from geometry.ray import Ray
from geometry.bvh import BVH
from collision.broadphase import BoxProxy

from collision.gpu_raycast import gpu_raycast_ctx

comptime NB = 4096
comptime MAXT: Real = 1000.0
comptime REPS = 3


def _scene() -> List[BoxProxy[3]]:
    var rng = Pcg32.seeded(13)
    var out = List[BoxProxy[3]]()
    for i in range(NB):
        var c = Vec3(
            Real(rng.next_f32()) * 80 - 40,
            Real(rng.next_f32()) * 80 - 40,
            Real(rng.next_f32()) * 80 - 40,
        )
        out.append(BoxProxy[3](i, AABB[3](c - Vec3(0.7, 0.7, 0.7), c + Vec3(0.7, 0.7, 0.7))))
    return out^


def _rays(n: Int) -> List[Ray[3]]:
    var rng = Pcg32.seeded(29)
    var out = List[Ray[3]]()
    for _ in range(n):
        var o = Vec3(
            Real(rng.next_f32()) * 100 - 50,
            Real(rng.next_f32()) * 100 - 50,
            Real(rng.next_f32()) * 100 - 50,
        )
        var d = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        if abs(Float64(d[0])) + abs(Float64(d[1])) + abs(Float64(d[2])) < 1e-3:
            d = Vec3(1, 0, 0)
        out.append(Ray[3](o, normalize(d), MAXT))
    return out^


def _cpu_row(mut t: BenchTable, items: List[BoxProxy[3]], rays: List[Ray[3]]) raises:
    var boxes = List[AABB[3]]()
    var prox = List[Int]()
    for i in range(len(items)):
        boxes.append(items[i].box)
        prox.append(items[i].proxy)
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var bvh = BVH[3]()
        bvh.build_boxes(boxes, prox)
        var acc = 0
        for i in range(len(rays)):
            acc += bvh.raycast(rays[i]).proxy
        keep(acc)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add("cpu bvh (build+cast)", len(rays), "ray", best, len(rays))


def _gpu_row[NR: Int](
    mut t: BenchTable, mut ctx: DeviceContext,
    items: List[BoxProxy[3]], rays: List[Ray[3]],
) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var gp = List[Int]()
        var gt = List[Real]()
        gpu_raycast_ctx[NB, NR](ctx, items, rays, gp, gt, MAXT)
        keep(len(gp))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add("gpu batched (total)", NR, "ray", best, NR)


def main() raises:
    var t = BenchTable("Scene raycast: GPU batched vs CPU BVH (4096 boxes)")
    var items = _scene()

    comptime for ri in range(4):
        comptime NR = 256 if ri == 0 else (2048 if ri == 1 else (16384 if ri == 2 else 65536))
        var rays = _rays(NR)
        _cpu_row(t, items, rays)

    comptime if has_accelerator():
        var ctx = DeviceContext()
        var wr = _rays(256)
        var wp = List[Int]()
        var wt = List[Real]()
        gpu_raycast_ctx[NB, 256](ctx, items, wr, wp, wt, MAXT)  # JIT warm-up

        var r0 = _rays(256)
        _gpu_row[256](t, ctx, items, r0)
        var r1 = _rays(2048)
        _gpu_row[2048](t, ctx, items, r1)
        var r2 = _rays(16384)
        _gpu_row[16384](t, ctx, items, r2)
        var r3 = _rays(65536)
        _gpu_row[65536](t, ctx, items, r3)
    else:
        print("(no accelerator: CPU rows only)")

    t.print_report()
