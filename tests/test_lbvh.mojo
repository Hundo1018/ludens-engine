"""Linear BVH (Morton sort + highest-differing-bit split) parity.

The three build heuristics must be interchangeable: same leaves in, same
answers out, only tree shape and build cost differ. LBVH is the one most
likely to break that contract in a way a smoke test would miss, because its
split points come from a bit pattern rather than from geometry — duplicate
Morton codes (many leaves quantising into one grid cell) and degenerate
extents are the cases where a radix-tree build can silently drop leaves or
recurse forever, so both are exercised here.

The tightness comparison at the end is not a pass/fail gate, it is the
measurement that justifies keeping all three: a Z-order curve approximates
spatial proximity, so LBVH is expected to build the loosest tree of the three.
"""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, Vec2
from geometry.aabb import AABB
from geometry.bvh import BVH
from geometry.ray import Ray


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var k = v[i]
        var j = i - 1
        while j >= 0 and v[j] > k:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = k
    return v^


def _same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    var sa = _sorted(a.copy())
    var sb = _sorted(b.copy())
    for i in range(len(sa)):
        if sa[i] != sb[i]:
            return False
    return True


def _build3(
    boxes: List[AABB[3]], proxies: List[Int], sah: Bool, lbvh: Bool
) -> BVH[3]:
    var t = BVH[3]()
    t.build_boxes(boxes, proxies, sah, lbvh)
    return t^


def main() raises:
    var s = Suite("lbvh")
    var rng = SplitMix64.seeded(31)

    # --- scene 1: ordinary random cloud ---
    var boxes = List[AABB[3]]()
    var proxies = List[Int]()
    for i in range(600):
        var c = Vec3(
            Real(rng.next_f32()) * 40 - 20,
            Real(rng.next_f32()) * 40 - 20,
            Real(rng.next_f32()) * 40 - 20,
        )
        var h = Vec3(0.5, 0.5, 0.5)
        boxes.append(AABB[3](c - h, c + h))
        proxies.append(i)

    var med = _build3(boxes, proxies, False, False)
    var sah = _build3(boxes, proxies, True, False)
    var lin = _build3(boxes, proxies, False, True)

    s.eqi(len(lin.nodes), len(med.nodes), "LBVH emits the same node count")

    # region queries must agree with both other builds
    var region_ok = True
    for _ in range(40):
        var c = Vec3(
            Real(rng.next_f32()) * 40 - 20,
            Real(rng.next_f32()) * 40 - 20,
            Real(rng.next_f32()) * 40 - 20,
        )
        var q = AABB[3](c - Vec3(4, 4, 4), c + Vec3(4, 4, 4))
        var rm = List[Int]()
        var rs = List[Int]()
        var rl = List[Int]()
        med.query_region(q, rm)
        sah.query_region(q, rs)
        lin.query_region(q, rl)
        if not _same(rm, rl) or not _same(rs, rl):
            region_ok = False
    s.check(region_ok, "region queries: LBVH == median == SAH")

    # raycasts must return the same nearest hit
    var ray_ok = True
    for _ in range(40):
        var o = Vec3(
            Real(rng.next_f32()) * 60 - 30,
            Real(rng.next_f32()) * 60 - 30,
            Real(rng.next_f32()) * 60 - 30,
        )
        var d = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        if abs(Float64(d[0])) + abs(Float64(d[1])) + abs(Float64(d[2])) < 1e-3:
            continue
        var r = Ray[3](o, d, 1e30)
        var hm = med.raycast(r)
        var hl = lin.raycast(r)
        if hm.hit != hl.hit:
            ray_ok = False
        elif hm.hit and hm.proxy != hl.proxy:
            ray_ok = False
    s.check(ray_ok, "raycast nearest hit: LBVH == median")

    # --- scene 2: DUPLICATE Morton codes. Every leaf lands in one grid cell,
    #     so no bit ever differs and the radix descent must fall back to a
    #     median split instead of recursing forever. ---
    var dup_boxes = List[AABB[3]]()
    var dup_prox = List[Int]()
    for i in range(64):
        var c = Vec3(1.0, 1.0, 1.0)  # identical centroids
        dup_boxes.append(AABB[3](c - Vec3(0.5, 0.5, 0.5), c + Vec3(0.5, 0.5, 0.5)))
        dup_prox.append(i)
    var dup = _build3(dup_boxes, dup_prox, False, True)
    var dup_ref = _build3(dup_boxes, dup_prox, False, False)
    var rq = List[Int]()
    var rq2 = List[Int]()
    dup.query_region(AABB[3](Vec3(0, 0, 0), Vec3(2, 2, 2)), rq)
    dup_ref.query_region(AABB[3](Vec3(0, 0, 0), Vec3(2, 2, 2)), rq2)
    s.eqi(len(rq), 64, "coincident leaves: all 64 still reachable")
    s.check(_same(rq, rq2), "coincident leaves: same set as median build")

    # --- scene 3: degenerate extent on one axis (a flat sheet) ---
    var flat_boxes = List[AABB[3]]()
    var flat_prox = List[Int]()
    for i in range(200):
        var c = Vec3(
            Real(rng.next_f32()) * 20 - 10, 0.0, Real(rng.next_f32()) * 20 - 10
        )
        flat_boxes.append(
            AABB[3](c - Vec3(0.3, 0.3, 0.3), c + Vec3(0.3, 0.3, 0.3))
        )
        flat_prox.append(i)
    var flat = _build3(flat_boxes, flat_prox, False, True)
    var flat_ref = _build3(flat_boxes, flat_prox, False, False)
    var fq = List[Int]()
    var fq2 = List[Int]()
    var fbox = AABB[3](Vec3(-5, -1, -5), Vec3(5, 1, 5))
    flat.query_region(fbox, fq)
    flat_ref.query_region(fbox, fq2)
    s.check(_same(fq, fq2), "flat sheet (zero extent on one axis): same set")

    # --- scene 4: 2D instantiation goes through the same generic code ---
    var b2 = List[AABB[2]]()
    var p2 = List[Int]()
    for i in range(150):
        var c = Vec2(Real(rng.next_f32()) * 20, Real(rng.next_f32()) * 20)
        b2.append(AABB[2](c - Vec2(0.4, 0.4), c + Vec2(0.4, 0.4)))
        p2.append(i)
    var t2 = BVH[2]()
    t2.build_boxes(b2, p2, False, True)
    var t2ref = BVH[2]()
    t2ref.build_boxes(b2, p2, False, False)
    var q2a = List[Int]()
    var q2b = List[Int]()
    var qb = AABB[2](Vec2(5, 5), Vec2(12, 12))
    t2.query_region(qb, q2a)
    t2ref.query_region(qb, q2b)
    s.check(_same(q2a, q2b), "2D: LBVH == median")

    # --- tightness: measurement, not a gate ---
    print("  Sigma-area  median:", med.cost(), " sah:", sah.cost(), " lbvh:", lin.cost())
    print(
        "  avg leaf depth  median:", med.avg_leaf_depth(),
        " sah:", sah.avg_leaf_depth(), " lbvh:", lin.avg_leaf_depth(),
    )

    s.finish()
