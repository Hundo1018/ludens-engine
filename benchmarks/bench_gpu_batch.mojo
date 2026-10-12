"""Batched articulations and narrowphase (ROADMAP 17.17).

Articulations: n instances of a 5-link Y-tree (revolute + prismatic), one
step of 1/240 s each:
- `Chain.step_aba` per instance (the existing CPU path; revolute-only ABA,
  so this row uses an all-revolute tree) -- allocates ~14 Lists per call;
- `ArticBatch.step_host` (the GPU kernel body on the host, flat arrays, no
  allocation);
- with an accelerator: `GpuArticBatch.step`, 30 steps fused per launch,
  state resident on the device (per-step time; download measured apart).
Narrowphase: n random box / sphere / capsule pairs:
- `ColliderSet.pair_manifold` per pair;
- `NarrowBatch.run_host`;
- with an accelerator: `GpuNarrow.run` including upload and download.

Run: pixi run mojo run -I build benchmarks/bench_gpu_batch.mojo
"""

from std.sys import has_accelerator
from std.math import sin, cos, sqrt
from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.chain import Chain, ChainLink
from physics.artic_batch import ArticBatch
from physics.gpu_artic import GpuArticBatch
from collision.collider_set import ColliderSet, Pose3
from collision.manifold import Axes3
from collision.narrow_batch import NarrowBatch
from collision.gpu_narrow import GpuNarrow
from max.gpu.host import DeviceContext

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 240.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def tree(prismatic: Bool) raises -> Chain:
    var c = Chain()
    c.add_link(ChainLink.revolute(_v(0, 0, 1), _v(0, 0, 0), _v(0, -0.3, 0), 1.5, _v(0.03, 0.01, 0.03)))
    var l = c.add_link_to(0, ChainLink.revolute(_v(1, 0, 0), _v(-0.2, -0.6, 0), _v(0, -0.25, 0), 0.8, _v(0.02, 0.01, 0.02)))
    var mid = ChainLink.prismatic(_v(0, -1, 0), _v(0.2, -0.6, 0), _v(0, -0.1, 0), 0.9, _v(0.02, 0.01, 0.02)) if prismatic else ChainLink.revolute(_v(0, 0, 1), _v(0.2, -0.6, 0), _v(0, -0.1, 0), 0.9, _v(0.02, 0.01, 0.02))
    var r = c.add_link_to(0, mid)
    _ = c.add_link_to(l, ChainLink.revolute(_v(0, 1, 0), _v(0, -0.5, 0), _v(0.03, -0.2, 0), 0.5, _v(0.01, 0.005, 0.01)))
    _ = c.add_link_to(r, ChainLink.revolute(_v(1, 0, 0), _v(0, -0.5, 0), _v(0, -0.2, 0.04), 0.5, _v(0.01, 0.005, 0.01)))
    return c^


struct Lcg:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64(self.s >> 11) / Float64(1 << 53))

    def range(mut self, lo: Real, hi: Real) -> Real:
        return lo + (hi - lo) * self.next()


def pose(mut r: Lcg) -> Pose3:
    var axis = Vec3(r.range(-1, 1), r.range(-1, 1), r.range(-1, 1), 0)
    var l = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]) + 1e-6
    var q = Quat.from_axis_angle(axis / l, r.range(0, 6.28))
    var ax = Axes3(fill=Vec3(0, 0, 0, 0))
    ax[0] = q.rotate(Vec3(1, 0, 0, 0))
    ax[1] = q.rotate(Vec3(0, 1, 0, 0))
    ax[2] = q.rotate(Vec3(0, 0, 1, 0))
    return Pose3(Vec3(r.range(-0.8, 0.8), r.range(-0.8, 0.8), r.range(-0.8, 0.8), 0), ax^)


def main() raises:
    var t = BenchTable("Batched articulations and narrowphase (17.17): host kernel body vs existing CPU path (+ device when present)")
    var zero = List[Real](length=5, fill=0)
    for n in [64, 1024]:
        var chains = List[Chain]()
        for k in range(n):
            var c = tree(False)
            for i in range(5):
                c.q[i] = 0.3 * sin(Real(k * 5 + i))
                c.qd[i] = 0.5 * cos(Real(k * 3 + 2 * i))
            chains.append(c^)
        var steps = max(2, 20480 // n)
        var t0 = now()
        for _ in range(steps):
            for k in range(n):
                chains[k].step_aba(DT, zero, G)
        t.add("articulation: Chain.step_aba per instance (revolute tree)", n, "instance-step", now() - t0, steps * n)

        for pr in [False, True]:
            var b = ArticBatch(tree(pr), n)
            for k in range(n):
                for i in range(5):
                    b.set_q(k, i, 0.3 * sin(Real(k * 5 + i)))
                    b.set_qd(k, i, 0.5 * cos(Real(k * 3 + 2 * i)))
            t0 = now()
            for _ in range(steps):
                b.step_host(DT, G)
            var label = String("articulation: ArticBatch.step_host (kernel body on host, ") + ("revolute + prismatic" if pr else "revolute") + " tree)"
            t.add(label, n, "instance-step", now() - t0, steps * n)
            keep(b.state[0])

        comptime if has_accelerator():
            var ctx = DeviceContext()
            var b = ArticBatch(tree(True), n)
            var g = GpuArticBatch(ctx, b)
            g.step(ctx, 30, DT, G)
            ctx.synchronize()
            t0 = now()
            for _ in range(10):
                g.step(ctx, 30, DT, G)
            ctx.synchronize()
            t.add("articulation: GpuArticBatch.step (30 steps fused per launch, resident state)", n, "instance-step", now() - t0, 300 * n)
            t0 = now()
            g.download(ctx, b)
            t.add("articulation: GpuArticBatch.download (q, qd, tau, qdd)", n, "download", now() - t0, 1)

    for n in [1024, 16384]:
        var cs = ColliderSet()
        var r = Lcg(3)
        for i in range(48):
            if i % 3 == 0:
                _ = cs.add(Vec3(r.range(0.2, 0.7), r.range(0.2, 0.7), r.range(0.2, 0.7), 0))
            elif i % 3 == 1:
                _ = cs.add_sphere(r.range(0.2, 0.6))
            else:
                _ = cs.add_capsule(r.range(0.15, 0.4), r.range(0.2, 0.6))
        var nb = NarrowBatch(n)
        var pi = List[Int]()
        var pj = List[Int]()
        var pa = List[Pose3]()
        var pb = List[Pose3]()
        for _ in range(n):
            var i = Int(r.next() * 48) % 48
            var j = (i + 1 + Int(r.next() * 47)) % 48
            var a = pose(r)
            var b = pose(r)
            nb.add_pair(cs, i, j, a, b, 0.02, Vec3(0.01, 0.01, 0.01, 0))
            pi.append(i)
            pj.append(j)
            pa.append(a^)
            pb.append(b^)
        var reps = max(1, 65536 // n)
        var hits = 0
        var t0 = now()
        for _ in range(reps):
            for k in range(n):
                if cs.pair_manifold(pi[k], pj[k], pa[k], pb[k], 0.02, Vec3(0.01, 0.01, 0.01, 0)).hit:
                    hits += 1
        t.add("narrowphase: ColliderSet.pair_manifold per pair", n, "pair", now() - t0, reps * n)
        t0 = now()
        for _ in range(reps):
            nb.run_host()
        t.add("narrowphase: NarrowBatch.run_host (kernel body on host)", n, "pair", now() - t0, reps * n)
        keep(hits)
        comptime if has_accelerator():
            var ctx = DeviceContext()
            var g = GpuNarrow(ctx, n)
            g.run(ctx, nb)
            t0 = now()
            for _ in range(reps):
                g.run(ctx, nb)
            t.add("narrowphase: GpuNarrow.run (upload + kernel + download)", n, "pair", now() - t0, reps * n)
    t.print_report()
