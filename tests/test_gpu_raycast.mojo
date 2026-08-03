"""Batched GPU raycast parity against the CPU BVH.

Unlike the GPU broadphase, this result is fully deterministic — each thread
keeps its own nearest hit in registers and writes once — so parity here is
stronger than set equality: the PROXY ID must match, not merely the distance.
That is the strict test, because two boxes at nearly the same distance are
exactly where a differing tie-break or a differing slab-test epsilon shows up,
and a distance-only check would pass while the engine returned a different
object.

Rays that miss everything are checked separately: a miss must come back as -1
rather than as some arbitrary proxy with a large t.
"""

from std.sys import has_accelerator
from std.gpu.host import DeviceContext
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, normalize
from geometry.aabb import AABB
from geometry.ray import Ray
from geometry.bvh import BVH
from collision.broadphase import BoxProxy
from collision.gpu_raycast import gpu_raycast_ctx

comptime NB = 1024
comptime NR = 2048
comptime MAXT: Real = 1000.0


def main() raises:
    var s = Suite("gpu_raycast")

    comptime if not has_accelerator():
        print("  (no accelerator: GPU raycast checks skipped)")
        s.check(True, "no accelerator — vacuously satisfied")
        s.finish()
        return

    var rng = SplitMix64.seeded(97)
    var items = List[BoxProxy[3]]()
    var boxes = List[AABB[3]]()
    var proxies = List[Int]()
    for i in range(NB):
        var c = Vec3(
            Real(rng.next_f32()) * 60 - 30,
            Real(rng.next_f32()) * 60 - 30,
            Real(rng.next_f32()) * 60 - 30,
        )
        var b = AABB[3](c - Vec3(0.7, 0.7, 0.7), c + Vec3(0.7, 0.7, 0.7))
        items.append(BoxProxy[3](i, b))
        boxes.append(b)
        proxies.append(i)

    var bvh = BVH[3]()
    bvh.build_boxes(boxes, proxies)

    var rays = List[Ray[3]]()
    for _ in range(NR):
        var o = Vec3(
            Real(rng.next_f32()) * 80 - 40,
            Real(rng.next_f32()) * 80 - 40,
            Real(rng.next_f32()) * 80 - 40,
        )
        var d = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        if abs(Float64(d[0])) + abs(Float64(d[1])) + abs(Float64(d[2])) < 1e-3:
            d = Vec3(1, 0, 0)
        rays.append(Ray[3](o, normalize(d), MAXT))

    var ctx = DeviceContext()
    var gp = List[Int]()
    var gt = List[Real]()
    gpu_raycast_ctx[NB, NR](ctx, items, rays, gp, gt, MAXT)

    s.eqi(len(gp), NR, "one result per ray")

    var same_proxy = 0
    var same_miss = 0
    var hits = 0
    var misses = 0
    var worst_t = Real(0)
    for i in range(NR):
        var h = bvh.raycast(rays[i])
        if h.hit:
            hits += 1
            if gp[i] == h.proxy:
                same_proxy += 1
            var dtv = abs(gt[i] - h.t)
            if dtv > worst_t:
                worst_t = dtv
        else:
            misses += 1
            if gp[i] == -1:
                same_miss += 1
    print("  hits:", hits, " misses:", misses, " worst |dt|:", worst_t)
    s.eqi(same_proxy, hits, "every hit returns the SAME proxy as the CPU BVH")
    s.eqi(same_miss, misses, "every miss returns -1")
    s.check(worst_t < 1e-2, "hit distances agree")
    s.check(hits > NR // 20, "the scene actually produces hits")

    s.finish()
