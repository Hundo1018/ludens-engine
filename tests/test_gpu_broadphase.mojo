"""GPU broadphase parity: the device pair SET must equal brute force's.

Only the set is compared, never the order: hits are appended through a single
atomic cursor, so the order depends on how the warps interleave and is not
reproducible. That is a real constraint on where this can be used — `solver6`
depends on a deterministic pair order for bit-identical results, so it would
have to sort first — and asserting set equality rather than sequence equality
is what states that constraint honestly.

The capacity path is checked too: the kernel counts every hit but only writes
the first `CAP`, so an undersized buffer must report failure rather than
silently return a truncated answer.
"""

from std.sys import has_accelerator
from std.gpu.host import DeviceContext
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from collision.broadphase import BruteForce, Pair, BoxProxy
from collision.bp_gpu import gpu_pairs_ctx


def _keys(ps: List[Pair]) -> List[Int]:
    var ks = List[Int]()
    for ref p in ps:
        var a = p.a if p.a < p.b else p.b
        var b = p.b if p.a < p.b else p.a
        ks.append(a * 1000000 + b)
    for i in range(1, len(ks)):
        var v = ks[i]
        var j = i - 1
        while j >= 0 and ks[j] > v:
            ks[j + 1] = ks[j]
            j -= 1
        ks[j + 1] = v
    return ks^


def _same(a: List[Pair], b: List[Pair]) -> Bool:
    if len(a) != len(b):
        return False
    var ka = _keys(a)
    var kb = _keys(b)
    for i in range(len(ka)):
        if ka[i] != kb[i]:
            return False
    return True


def _scene(mut rng: SplitMix64, n: Int, extent: Real, h: Real) -> List[BoxProxy[3]]:
    var out = List[BoxProxy[3]]()
    for i in range(n):
        var c = Vec3(
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
            Real(rng.next_f32()) * extent,
        )
        out.append(BoxProxy[3](i, AABB[3](c - Vec3(h, h, h), c + Vec3(h, h, h))))
    return out^


def main() raises:
    var s = Suite("gpu_broadphase")

    comptime if not has_accelerator():
        print("  (no accelerator: GPU broadphase checks skipped)")
        s.check(True, "no accelerator — vacuously satisfied")
        s.finish()
        return

    var ctx = DeviceContext()
    var rng = SplitMix64.seeded(77)

    # sparse scene: few overlaps
    var sparse = _scene(rng, 512, 40.0, 0.6)
    var bf = BruteForce[3]()
    bf.rebuild(sparse)
    var want = List[Pair]()
    bf.pairs(want)
    var got = List[Pair]()
    var ok = gpu_pairs_ctx[512, 1 << 16](ctx, sparse, got)
    s.check(ok, "sparse scene: no capacity overflow")
    print("  sparse pairs cpu=", len(want), " gpu=", len(got))
    s.check(_same(want, got), "sparse scene: GPU pair set == brute force")

    # dense scene: many overlaps, exercises the atomic cursor hard
    var dense = _scene(rng, 512, 10.0, 0.9)
    var bf2 = BruteForce[3]()
    bf2.rebuild(dense)
    var want2 = List[Pair]()
    bf2.pairs(want2)
    var got2 = List[Pair]()
    var ok2 = gpu_pairs_ctx[512, 1 << 18](ctx, dense, got2)
    s.check(ok2, "dense scene: no capacity overflow")
    print("  dense pairs cpu=", len(want2), " gpu=", len(got2))
    s.check(_same(want2, got2), "dense scene: GPU pair set == brute force")

    # capacity guard: a deliberately tiny buffer must REPORT failure
    var got3 = List[Pair]()
    var ok3 = gpu_pairs_ctx[512, 8](ctx, dense, got3)
    s.check(not ok3, "undersized buffer reports overflow instead of truncating silently")

    s.finish()
