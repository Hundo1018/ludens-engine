# tier: component
"""GPU narrowphase (ROADMAP 17.17): device vs host run of the same kernel body.

4096 random box / sphere / capsule pairs. The host reference is
`NarrowBatch.run_host` (bit-identical to `ColliderSet.pair_manifold`, see
test_narrow_batch); the device results must agree on hit / count for at
least 99.9 % of pairs (a contact exactly at a clipping boundary may flip
under fused multiply-add) and on normals / depths within 1e-4 where they
agree. Box / capsule pairs get 5e-3: `capsule_box_manifold` locates the
deepest segment point by a ternary search on squared distance, whose argmin
is only resolvable to ~sqrt(eps) of the segment length (f32: ~3e-4), so
host and device land on different t from rounding alone (measured on an
RTX host: ~1.2e-3 normal difference, box / capsule pairs only).
No accelerator -> the device half is skipped.
"""

from std.sys import has_accelerator
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from collision.collider_set import ColliderSet, Pose3, SHAPE_BOX, SHAPE_CAPSULE
from collision.manifold import Axes3
from collision.narrow_batch import PAIR_STRIDE, NarrowBatch, OUT_STRIDE, O_HIT, O_COUNT, O_NORMAL, O_POINTS
from collision.gpu_narrow import GpuNarrow
from max.gpu.host import DeviceContext

comptime PAIRS = 4096


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


def build(mut cs: ColliderSet) raises -> NarrowBatch:
    var r = Lcg(5)
    for i in range(48):
        if i % 3 == 0:
            _ = cs.add(Vec3(r.range(0.2, 0.7), r.range(0.2, 0.7), r.range(0.2, 0.7), 0))
        elif i % 3 == 1:
            _ = cs.add_sphere(r.range(0.2, 0.6))
        else:
            _ = cs.add_capsule(r.range(0.15, 0.4), r.range(0.2, 0.6))
    var nb = NarrowBatch(PAIRS)
    for _ in range(PAIRS):
        var i = Int(r.next() * 48) % 48
        var j = (i + 1 + Int(r.next() * 47)) % 48
        nb.add_pair(cs, i, j, pose(r), pose(r), r.range(0, 0.05), Vec3(0.01, 0.01, 0.01, 0))
    return nb^


def main() raises:
    var s = Suite("gpu_narrow")
    var cs = ColliderSet()
    var host = build(cs)
    host.run_host()
    var hits = 0
    for k in range(host.count):
        if host.out[k * OUT_STRIDE + O_HIT] != 0:
            hits += 1
    s.check(hits > PAIRS // 4, "host reference: " + String(hits) + " of " + String(PAIRS) + " pairs touch")

    comptime if has_accelerator():
        s.begin_device()
        var ctx = DeviceContext()  # the test is the single owner (F17)
        var dev = build(cs)
        var g = GpuNarrow(ctx, 256)  # smaller than PAIRS: exercises growth
        g.run(ctx, dev)
        var disagree = 0
        var worst = Float64(0)  # every pair kind except box / capsule
        var worst_bc = Float64(0)  # box / capsule (ternary-search contact point)
        for k in range(PAIRS):
            var o = k * OUT_STRIDE
            if dev.out[o + O_HIT] != host.out[o + O_HIT] or dev.out[o + O_COUNT] != host.out[o + O_COUNT]:
                disagree += 1
                continue
            var pw = Float64(0)
            for c in range(3):
                pw = max(pw, abs(Float64(dev.out[o + O_NORMAL + c] - host.out[o + O_NORMAL + c])))
            for c in range(Int(host.out[o + O_COUNT])):
                pw = max(pw, abs(Float64(dev.out[o + O_POINTS + 4 * c + 3] - host.out[o + O_POINTS + 4 * c + 3])))
            var ka = Int(host.inp[k * PAIR_STRIDE])
            var kb = Int(host.inp[k * PAIR_STRIDE + 1])
            if min(ka, kb) == SHAPE_BOX and max(ka, kb) == SHAPE_CAPSULE:
                worst_bc = max(worst_bc, pw)
            else:
                worst = max(worst, pw)
        print("  [device] device vs host: hit/count disagree on", disagree, "pairs; max normal/depth diff", worst, "(box/capsule", worst_bc, ")")
        s.check(disagree * 1000 <= PAIRS, "hit / count agree on >= 99.9 % of pairs")
        s.check(worst < 1e-4, "normals and depths agree within 1e-4 (all kinds but box / capsule)")
        s.check(worst_bc < 5e-3, "box / capsule normals and depths agree within 5e-3")
    else:
        s.skip_device("no accelerator on this host")
    s.finish()
