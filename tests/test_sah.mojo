from std.math import sqrt
from harness.runner import Suite
from geometry.vec import WorldType, Real, Vec3
from geometry.aabb import AABB
from geometry.bvh import BVH, _Leaf
from geometry.ray import Ray
from scheduler.rng import XorShift64, range_f


def _clustered(mut rng: XorShift64, n: Int) -> List[_Leaf[3]]:
    """A deliberately non-uniform scene: most boxes packed into a few tight
    clusters, a few scattered wide. Median-split ignores the empty space
    between clusters; SAH cuts along it — the regime where SAH wins."""
    var leaves = List[_Leaf[3]]()
    for i in range(n):
        var cx = Real(0)
        var cy = Real(0)
        var cz = Real(0)
        if i % 5 == 0:  # 20% scattered wide
            cx = range_f(rng, -30, 30)
            cy = range_f(rng, -30, 30)
            cz = range_f(rng, -30, 30)
        else:  # 80% in one of three tight clusters
            var c = i % 3
            var bx = Real(c) * 20 - 20
            cx = bx + range_f(rng, -1.5, 1.5)
            cy = range_f(rng, -1.5, 1.5)
            cz = bx + range_f(rng, -1.5, 1.5)
        var half = SIMD[WorldType, 3](range_f(rng, 0.2, 0.8))
        leaves.append(
            _Leaf[3](AABB[3].from_center(Vec3(cx, cy, cz), half), i)
        )
    return leaves^


def _sorted(mut v: List[Int]):
    for i in range(1, len(v)):
        var key = v[i]
        var j = i - 1
        while j >= 0 and v[j] > key:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = key


def _same_set(mut a: List[Int], mut b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    _sorted(a)
    _sorted(b)
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var s = Suite("sah")

    # same seed -> identical leaf sets fed to each build heuristic
    var med = BVH[3]()
    var sah = BVH[3]()
    var rm = XorShift64(0xABCDEF)
    var rs = XorShift64(0xABCDEF)
    med.build(_clustered(rm, 200), sah=False)
    sah.build(_clustered(rs, 200), sah=True)

    # 1. Both cover every input proxy exactly once.
    var lm_leaves = 0
    var ls_leaves = 0
    for i in range(len(med.nodes)):
        if med.nodes[i].is_leaf():
            lm_leaves += 1
    for i in range(len(sah.nodes)):
        if sah.nodes[i].is_leaf():
            ls_leaves += 1
    s.eqi(lm_leaves, 200, "median tree has all 200 leaves")
    s.eqi(ls_leaves, 200, "SAH tree has all 200 leaves")

    # 2. Region-query parity: identical result SETS for 300 random boxes.
    var qrng = XorShift64(0x13579)
    var region_ok = True
    for _ in range(300):
        var c = Vec3(
            range_f(qrng, -35, 35),
            range_f(qrng, -35, 35),
            range_f(qrng, -35, 35),
        )
        var half = SIMD[WorldType, 3](range_f(qrng, 1, 8))
        var box = AABB[3].from_center(c, half)
        var hm = List[Int]()
        var hs = List[Int]()
        med.query_region(box, hm)
        sah.query_region(box, hs)
        if not _same_set(hm, hs):
            region_ok = False
            break
    s.check(region_ok, "SAH == median region-query result sets (300 boxes)")

    # 3. Raycast parity: identical nearest hit (proxy + t) for 300 rays.
    var rrng = XorShift64(0x2468)
    var ray_ok = True
    for _ in range(300):
        var o = Vec3(
            range_f(rrng, -40, 40),
            range_f(rrng, -40, 40),
            range_f(rrng, -40, 40),
        )
        var d = Vec3(
            range_f(rrng, -1, 1),
            range_f(rrng, -1, 1),
            range_f(rrng, -1, 1),
        )
        var dl = sqrt(Float64(d[0]) ** 2 + Float64(d[1]) ** 2 + Float64(d[2]) ** 2)
        if dl < 1e-6:
            continue
        d = d / Real(dl)
        var ray = Ray[3](o, d, 200)
        var hm = med.raycast(ray)
        var hs = sah.raycast(ray)
        if hm.hit != hs.hit or hm.proxy != hs.proxy or hm.t != hs.t:
            ray_ok = False
            break
    s.check(ray_ok, "SAH == median raycast nearest hit (proxy+t, 300 rays)")

    # 4. Quality: on this clustered scene SAH builds a tighter tree
    #    (lower Σ node surface area) than median-split.
    var cm = Float64(med.cost())
    var cs = Float64(sah.cost())
    print("  Σ node area  median:", cm, " SAH:", cs, " ratio:", cs / cm)
    print("  avg leaf depth  median:", Float64(med.avg_leaf_depth()),
          " SAH:", Float64(sah.avg_leaf_depth()))
    s.check(cs < cm, "SAH tree is tighter than median (lower Σ area)")

    s.finish()
