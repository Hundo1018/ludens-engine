"""Sweep-and-prune parity: the pair SET must equal brute force's.

Every `BroadPhase` implementation answers the same question — which boxes
overlap — and may only differ in how it gets there. SAP is the interesting
case for that contract because it CARRIES STATE between frames (last frame's
sorted order is repaired rather than rebuilt), so a bug would not show up on
the first frame but on the tenth. The moving-scene check below therefore
re-queries after every step, including a step where boxes teleport, which is
the worst case for the coherence assumption.

`query_region` is checked too, since its early exit depends on the sweep order
being correct.
"""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec2, Vec3
from geometry.aabb import AABB
from collision.broadphase import BruteForce, Pair, BoxProxy
from collision.bp_sap import SapBroadPhase


def _key(p: Pair) -> Int:
    var a = p.a if p.a < p.b else p.b
    var b = p.b if p.a < p.b else p.a
    return a * 100000 + b


def _sorted_keys(ps: List[Pair]) -> List[Int]:
    var ks = List[Int]()
    for ref p in ps:
        ks.append(_key(p))
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
    var ka = _sorted_keys(a)
    var kb = _sorted_keys(b)
    for i in range(len(ka)):
        if ka[i] != kb[i]:
            return False
    return True


def _scene2(mut rng: SplitMix64, n: Int, extent: Real, h: Real) -> List[BoxProxy[2]]:
    var out = List[BoxProxy[2]]()
    for i in range(n):
        var c = Vec2(
            Real(rng.next_f32()) * extent, Real(rng.next_f32()) * extent
        )
        out.append(BoxProxy[2](i, AABB[2](c - Vec2(h, h), c + Vec2(h, h))))
    return out^


def main() raises:
    var s = Suite("sap")
    var rng = SplitMix64.seeded(11)

    # 1. static scenes at several densities
    var static_ok = True
    var counts = List[Int]()
    counts.append(1)
    counts.append(2)
    counts.append(50)
    counts.append(400)
    for ci in range(len(counts)):
        var n = counts[ci]
        var items = _scene2(rng, n, 30.0, 1.0)
        var bf = BruteForce[2]()
        var sap = SapBroadPhase[2]()
        bf.rebuild(items)
        sap.rebuild(items)
        var pb = List[Pair]()
        var ps = List[Pair]()
        bf.pairs(pb)
        sap.pairs(ps)
        if not _same(pb, ps):
            static_ok = False
            print("  static mismatch n=", n, " bf=", len(pb), " sap=", len(ps))
    s.check(static_ok, "static scenes: SAP pair set == brute force")

    # 2. moving scene: the stateful path. Small motion keeps the previous order
    #    almost correct (the coherence case the insertion sort is built for).
    var items = _scene2(rng, 300, 25.0, 1.0)
    var bf2 = BruteForce[2]()
    var sap2 = SapBroadPhase[2]()
    var moving_ok = True
    var saw_pairs = 0
    for step in range(12):
        for i in range(len(items)):
            var d = Vec2(
                Real(rng.next_f32()) * 0.6 - 0.3, Real(rng.next_f32()) * 0.6 - 0.3
            )
            items[i] = BoxProxy[2](
                items[i].proxy, AABB[2](items[i].box.min + d, items[i].box.max + d)
            )
        bf2.rebuild(items)
        sap2.rebuild(items)
        var pb = List[Pair]()
        var ps = List[Pair]()
        bf2.pairs(pb)
        sap2.pairs(ps)
        saw_pairs += len(pb)
        if not _same(pb, ps):
            moving_ok = False
            print("  moving mismatch step=", step)
    s.check(moving_ok, "12 coherent frames: SAP tracks brute force exactly")
    s.check(saw_pairs > 0, "the moving scene actually produces overlaps")

    # 3. teleport: destroys the coherence assumption in one frame. The
    #    insertion sort must still land on a correct order.
    for i in range(len(items)):
        var c = Vec2(Real(rng.next_f32()) * 25.0, Real(rng.next_f32()) * 25.0)
        items[i] = BoxProxy[2](items[i].proxy, AABB[2](c - Vec2(1, 1), c + Vec2(1, 1)))
    bf2.rebuild(items)
    sap2.rebuild(items)
    var pb3 = List[Pair]()
    var ps3 = List[Pair]()
    bf2.pairs(pb3)
    sap2.pairs(ps3)
    s.check(_same(pb3, ps3), "after a full teleport: pair set still exact")

    # 4. population change resets the permutation rather than corrupting it
    var fewer = List[BoxProxy[2]]()
    for i in range(120):
        fewer.append(items[i])
    bf2.rebuild(fewer)
    sap2.rebuild(fewer)
    var pb4 = List[Pair]()
    var ps4 = List[Pair]()
    bf2.pairs(pb4)
    sap2.pairs(ps4)
    s.check(_same(pb4, ps4), "population change: pair set still exact")

    # 5. query_region agrees with brute force (its early exit relies on order)
    var region_ok = True
    for q in range(8):
        var c = Vec2(Real(rng.next_f32()) * 25.0, Real(rng.next_f32()) * 25.0)
        var box = AABB[2](c - Vec2(3, 3), c + Vec2(3, 3))
        var ra = List[Int]()
        var rb = List[Int]()
        bf2.query_region(box, ra)
        sap2.query_region(box, rb)
        var ka = List[Pair]()
        var kb = List[Pair]()
        for ref x in ra:
            ka.append(Pair(0, x))
        for ref x in rb:
            kb.append(Pair(0, x))
        if not _same(ka, kb):
            region_ok = False
    s.check(region_ok, "query_region matches brute force")

    # 6. 3D instantiation works through the same generic path
    var items3 = List[BoxProxy[3]]()
    for i in range(80):
        var c = Vec3(
            Real(rng.next_f32()) * 12,
            Real(rng.next_f32()) * 12,
            Real(rng.next_f32()) * 12,
        )
        items3.append(
            BoxProxy[3](i, AABB[3](c - Vec3(1, 1, 1), c + Vec3(1, 1, 1)))
        )
    var bf3 = BruteForce[3]()
    var sap3 = SapBroadPhase[3]()
    bf3.rebuild(items3)
    sap3.rebuild(items3)
    var p3a = List[Pair]()
    var p3b = List[Pair]()
    bf3.pairs(p3a)
    sap3.pairs(p3b)
    s.check(_same(p3a, p3b), "3D: SAP pair set == brute force")

    s.finish()
