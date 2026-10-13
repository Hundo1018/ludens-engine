# tier: unit
"""GJK distance and closest points (ROADMAP 17.53): `geometry.gjk_distance`.

  1. Ordinary: two unit cubes 3 apart on x are 1 apart, closest points on
     the facing faces; a sphere (r 0.5) off a cube's corner along the
     diagonal is |c - corner| - 0.5 away with the witness on the corner; two
     skew capsules (segments crossing 2 apart in height) are 2 - r1 - r2
     apart.
  2. Integration: 300 random point-cloud pairs, each answer certified: the
     witnesses are `dist` apart (upper bound) and the plane pair through them
     normal to `normal` separates the clouds (lower bound), so `dist` is the
     true distance; it never exceeds the closest vertex pair.
  3. Extreme: overlapping shapes report overlap; identical point clouds;
     a single point against a triangle (face, edge and vertex regions);
     degenerate (collinear) clouds.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.gjk_distance import convex_distance
from scheduler.rng import SplitMix64


def _box(c: Vec3, h: Real) -> List[Vec3]:
    var out = List[Vec3]()
    for k in range(8):
        out.append(c + Vec3(h if (k & 1) else -h, h if (k & 2) else -h, h if (k & 4) else -h, 0))
    return out^


def main() raises:
    var s = Suite("gjk_distance")

    # ---- cubes ---------------------------------------------------------
    var d = convex_distance(_box(Vec3(0, 0, 0, 0), 1), 0, _box(Vec3(3, 0.3, -0.2, 0), 1), 0)
    print("  cubes 3 apart:", d.dist, " pa.x", d.pa[0], " pb.x", d.pb[0], " normal", d.normal[0], d.normal[1], d.normal[2])
    s.almost(Float64(d.dist), 1.0, "two unit cubes 3 apart are 1 apart", 1e-5)
    s.check(abs(d.pa[0] - 1) < 1e-5 and abs(d.pb[0] - 2) < 1e-5, "witnesses on the facing faces")
    s.check(abs(d.normal[0] - 1) < 1e-5, "normal from A toward B")

    # ---- sphere off a corner -------------------------------------------
    var c = Vec3(2, 2, 2, 0)
    var ds = convex_distance(_box(Vec3(0, 0, 0, 0), 1), 0, [c], 0.5)
    var want = length(c - Vec3(1, 1, 1, 0)) - 0.5
    print("  sphere off the corner:", ds.dist, " want", want)
    s.almost(Float64(ds.dist), Float64(want), "sphere off a cube corner: |c - corner| - r", 1e-5)
    s.check(length(ds.pa - Vec3(1, 1, 1, 0)) < 1e-5, "witness on A is the corner")

    # ---- skew capsules -------------------------------------------------
    var dc = convex_distance(
        [Vec3(-1, 0, 0, 0), Vec3(1, 0, 0, 0)], 0.3,
        [Vec3(0, 2, -1, 0), Vec3(0, 2, 1, 0)], 0.2,
    )
    s.almost(Float64(dc.dist), 1.5, "skew capsules 2 apart, radii 0.3 + 0.2: 1.5", 1e-5)

    # ---- random pairs against a sampled oracle -------------------------
    var rng = SplitMix64.seeded(1753)
    var worst_over = Real(0)
    var worst_gap = Real(0)
    var wit_ok = True
    var sep_ok = True
    for _ in range(300):
        var a = List[Vec3]()
        var b = List[Vec3]()
        var ca = Vec3(Real(rng.next_f32()) * 4 - 2, Real(rng.next_f32()) * 4 - 2, Real(rng.next_f32()) * 4 - 2, 0)
        var cb = ca + Vec3(Real(rng.next_f32()) * 6 - 3, Real(rng.next_f32()) * 6 - 3, Real(rng.next_f32()) * 6 - 3, 0)
        for _ in range(6):
            a.append(ca + Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0))
            b.append(cb + Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0))
        var g = convex_distance(a, 0, b, 0)
        if g.overlap:
            continue
        # oracle: segments between every vertex pair of each cloud, sampled
        var oracle = Real(1e30)
        for i in range(6):
            for j in range(6):
                oracle = min(oracle, length(a[i] - b[j]))
        # vertex-to-vertex is an upper bound; GJK must not exceed it
        worst_over = max(worst_over, g.dist - oracle)
        if abs(length(g.pb - g.pa) - g.dist) > 1e-4:
            wit_ok = False
        worst_gap = max(worst_gap, abs(length(g.pb - g.pa) - g.dist))
        var ha = dot(g.pa, g.normal)
        var hb = dot(g.pb, g.normal)
        for i in range(6):
            if dot(a[i], g.normal) > ha + 1e-4 or dot(b[i], g.normal) < hb - 1e-4:
                sep_ok = False
    print("  300 random clouds: GJK above the vertex-pair bound by at most", worst_over, " witness gap error", worst_gap)
    s.check(worst_over <= 1e-5, "GJK distance never exceeds the closest vertex pair")
    s.check(wit_ok, "witness points are exactly dist apart")
    s.check(sep_ok, "the planes through the witnesses separate the clouds (dist is a lower bound too)")

    # ---- extremes ------------------------------------------------------
    var ov = convex_distance(_box(Vec3(0, 0, 0, 0), 1), 0, _box(Vec3(0.5, 0, 0, 0), 1), 0)
    s.check(ov.overlap and ov.dist <= 0, "overlapping cubes: overlap")
    var same = convex_distance(_box(Vec3(0, 0, 0, 0), 1), 0, _box(Vec3(0, 0, 0, 0), 1), 0)
    s.check(same.overlap, "identical clouds: overlap")
    var tri: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(2, 0, 0, 0), Vec3(0, 0, 2, 0)]
    var face = convex_distance([Vec3(0.5, 1, 0.5, 0)], 0, tri, 0)
    var edge = convex_distance([Vec3(1, 1, -1, 0)], 0, tri, 0)
    var vert = convex_distance([Vec3(-1, 0, -1, 0)], 0, tri, 0)
    s.almost(Float64(face.dist), 1.0, "point over the triangle's face", 1e-5)
    s.almost(Float64(edge.dist), Float64(sqrt(Real(2))), "point off an edge", 1e-5)
    s.almost(Float64(vert.dist), Float64(sqrt(Real(2))), "point off a vertex", 1e-5)
    var line: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(2, 0, 0, 0)]
    var dl = convex_distance(line, 0, [Vec3(1, 3, 0, 0)], 0)
    s.almost(Float64(dl.dist), 3.0, "collinear cloud (a segment) vs a point", 1e-5)
    s.finish()
