# tier: unit
"""Convex polytopes for fracture (ROADMAP 17.5): hull, plane split, measures.

  ordinary  a box has the textbook volume / centroid / inertia; splitting it by
            a plane gives two closed pieces whose volumes add up to the whole
            and whose cap carries the cut's tag; the hull of a cube's corners
            plus interior points is the cube.
  integ.    the pieces of a split are themselves splittable (a Voronoi cell is
            ~12 successive splits): 1000 cuts of a rolling plane conserve volume
            to 1e-9 and every piece stays closed (surface area vectors sum to 0)
            and convex; `simplified` drops edge/face points without changing
            the solid; `plane_patch` finds a footprint.
  extreme   the plane misses the solid, touches only a face / only a corner;
            coplanar, collinear, coincident and too-few-point clouds give an
            empty hull instead of garbage; a hull with a duplicated point.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.polytope import Polytope, polytope_split, convex_hull


def _closed(p: Polytope) -> Float64:
    """|sum of triangle area vectors| -- zero for a closed surface."""
    var sx = Float64(0)
    var sy = Float64(0)
    var sz = Float64(0)
    for f in range(p.nt()):
        var a = 3 * p.t[3 * f]
        var b = 3 * p.t[3 * f + 1]
        var c = 3 * p.t[3 * f + 2]
        var e1x = p.v[b] - p.v[a]
        var e1y = p.v[b + 1] - p.v[a + 1]
        var e1z = p.v[b + 2] - p.v[a + 2]
        var e2x = p.v[c] - p.v[a]
        var e2y = p.v[c + 1] - p.v[a + 1]
        var e2z = p.v[c + 2] - p.v[a + 2]
        sx += (e1y * e2z - e1z * e2y) / 2
        sy += (e1z * e2x - e1x * e2z) / 2
        sz += (e1x * e2y - e1y * e2x) / 2
    return sqrt(sx * sx + sy * sy + sz * sz)


def _convex(p: Polytope) -> Bool:
    for f in range(p.nt()):
        var a = 3 * p.t[3 * f]
        var b = 3 * p.t[3 * f + 1]
        var c = 3 * p.t[3 * f + 2]
        var e1x = p.v[b] - p.v[a]
        var e1y = p.v[b + 1] - p.v[a + 1]
        var e1z = p.v[b + 2] - p.v[a + 2]
        var e2x = p.v[c] - p.v[a]
        var e2y = p.v[c + 1] - p.v[a + 1]
        var e2z = p.v[c + 2] - p.v[a + 2]
        var nx = e1y * e2z - e1z * e2y
        var ny = e1z * e2x - e1x * e2z
        var nz = e1x * e2y - e1y * e2x
        var nl = sqrt(nx * nx + ny * ny + nz * nz)
        if nl < 1e-7:
            continue  # sliver: its normal is noise
        for i in range(p.nv()):
            var d = ((p.v[3 * i] - p.v[a]) * nx + (p.v[3 * i + 1] - p.v[a + 1]) * ny + (p.v[3 * i + 2] - p.v[a + 2]) * nz) / nl
            if d > 1e-7:
                return False
    return True


def _cube_cloud(extra: Bool) -> List[Float64]:
    var pts = List[Float64]()
    for k in range(8):
        pts.append(Float64(k & 1))
        pts.append(Float64((k >> 1) & 1))
        pts.append(Float64((k >> 2) & 1))
    if extra:
        for q in [0.5, 0.5, 0.5, 0.25, 0.75, 0.5, 0.5, 0.0, 0.5, 0.0, 0.0, 0.5, 0.3, 0.3, 0.3]:
            pts.append(q)
    return pts^


def case_ordinary(mut s: Suite):
    var b = Polytope.box(1, 2, 3, 1, 0.5, 0.25)
    s.almost(b.volume(), 8 * 1 * 0.5 * 0.25, "box volume", 1e-12)
    var c = b.centroid()
    s.almost(c[0], 1, "box centroid x", 1e-12)
    s.almost(c[1], 2, "box centroid y", 1e-12)
    s.almost(c[2], 3, "box centroid z", 1e-12)
    var ii = b.inertia_diag()
    var m = b.volume()
    s.almost(ii[0], m / 3 * (0.5 * 0.5 + 0.25 * 0.25), "box Ixx", 1e-12)
    s.almost(ii[1], m / 3 * (1 * 1 + 0.25 * 0.25), "box Iyy", 1e-12)
    s.almost(ii[2], m / 3 * (1 * 1 + 0.5 * 0.5), "box Izz", 1e-12)
    s.almost(_closed(b), 0, "box is closed", 1e-12)

    var r = polytope_split(b, 1, 0, 0, 1.5, 7, 1e-9)
    var pr = r^.into_pair()
    s.almost(pr[0].volume() + pr[1].volume(), b.volume(), "split conserves volume", 1e-12)
    s.almost(pr[0].volume(), 0.5 * 1.0 * 0.5, "front volume (x in [1.5, 2])", 1e-12)
    s.check(pr[0].has_tag(7) and pr[1].has_tag(7), "both pieces carry the cap tag")
    var cap = pr[1].tag_patch(7)
    s.almost(cap[0], 1.0 * 0.5, "cap area = 1.0 x 0.5", 1e-12)
    s.almost(cap[1], 1.5, "cap centre x", 1e-12)
    s.almost(cap[4], 1.0, "back cap normal +x", 1e-12)
    s.almost(_closed(pr[0]), 0, "front closed", 1e-12)
    s.almost(_closed(pr[1]), 0, "back closed", 1e-12)

    var h = convex_hull(_cube_cloud(True))
    s.almost(h.volume(), 1.0, "hull of cube + interior points = unit cube", 1e-12)
    s.eqi(h.nv(), 8, "hull keeps only the 8 corners")
    s.check(_convex(h), "hull is convex")


def case_integration(mut s: Suite):
    # a wedge of planes at changing angles through a box: 1000 successive cuts
    var piece = Polytope.box(0, 0, 0, 1, 1, 1)
    var whole = piece.volume()
    var pieces = List[Polytope]()
    pieces.append(piece^)
    var rng = UInt64(12345)
    for k in range(60):
        rng = rng * 6364136223846793005 + 1442695040888963407
        var a = Float64((rng >> 33) % 1000) / 1000.0 * 6.283185307179586
        rng = rng * 6364136223846793005 + 1442695040888963407
        var e = Float64((rng >> 33) % 1000) / 1000.0 * 3.141592653589793
        var nx = sqrt(1 - (1 - 2 * e / 3.141592653589793) ** 2) * (1.0 if a < 3.14 else -1.0)
        var ny = 1 - 2 * e / 3.141592653589793
        var nz = sqrt(max(1 - nx * nx - ny * ny, 0.0))
        rng = rng * 6364136223846793005 + 1442695040888963407
        var d = (Float64((rng >> 33) % 1000) / 1000.0 - 0.5) * 0.8
        var next = List[Polytope]()
        for i in range(len(pieces)):
            var r = polytope_split(pieces[i], nx, ny, nz, d, k, 1e-9)
            if r.front.is_empty() or r.back.is_empty():
                next.append(pieces[i].copy())
            else:
                var pr = r^.into_pair()
                next.append(pr[0].copy())
                next.append(pr[1].copy())
        pieces = next^
    var total = Float64(0)
    var worst_closed = Float64(0)
    var all_convex = True
    for i in range(len(pieces)):
        total += pieces[i].volume()
        worst_closed = max(worst_closed, _closed(pieces[i]))
        if not _convex(pieces[i]):
            all_convex = False
    print("  rolling cuts:", len(pieces), "pieces, volume error", abs(total - whole), "worst open", worst_closed)
    s.check(len(pieces) > 100, "60 planes make > 100 pieces")
    s.almost(total, whole, "60 successive cuts conserve volume", 1e-9)
    s.check(worst_closed < 1e-9, "every piece is closed")
    s.check(all_convex, "every piece is convex")

    # simplified: same solid, fewer vertices
    var big = pieces[0].copy()
    var simp = big.simplified(1e-9)
    s.almost(simp.volume(), big.volume(), "simplified keeps the volume", 1e-10)
    s.check(simp.nv() <= big.nv(), "simplified never adds vertices")
    s.check(_convex(simp), "simplified stays convex")

    # footprint of a box standing on y = 0
    var b = Polytope.box(0, 0.5, 0, 0.5, 0.5, 0.25)
    var pp = b.plane_patch(0, -1, 0, 0, 1e-9)
    s.almost(pp[0], 1.0 * 0.5, "footprint area", 1e-12)
    s.almost(pp[2], 0.0, "footprint at y = 0", 1e-12)
    var none = b.plane_patch(0, -1, 0, 5, 1e-9)
    s.almost(none[0], 0, "no footprint away from the plane", 0)


def case_extreme(mut s: Suite):
    var b = Polytope.box(0, 0, 0, 1, 1, 1)
    # plane misses the solid
    var miss = polytope_split(b, 1, 0, 0, 5, 1, 1e-9)
    s.check(miss.front.is_empty() and not miss.back.is_empty(), "plane beyond the solid: all back")
    s.almost(miss.back.volume(), 8, "...and unchanged", 1e-12)
    var miss2 = polytope_split(b, 1, 0, 0, -5, 1, 1e-9)
    s.check(miss2.back.is_empty() and not miss2.front.is_empty(), "plane before the solid: all front")
    # plane flush with a face
    var flush = polytope_split(b, 1, 0, 0, 1, 1, 1e-9)
    s.check(flush.front.is_empty(), "plane flush with a face yields no sliver")
    s.almost(flush.back.volume(), 8, "...and the solid intact", 1e-12)
    # plane through a single corner
    var s3 = sqrt(3.0)
    var corner = polytope_split(b, 1 / s3, 1 / s3, 1 / s3, s3, 1, 1e-9)
    s.check(corner.front.is_empty(), "plane touching one corner yields no sliver")
    # plane through the middle along a face diagonal plane (coplanar with mesh diagonals)
    var diag = polytope_split(b, 1 / sqrt(2.0), 1 / sqrt(2.0), 0, 0, 2, 1e-9)
    var pd = diag^.into_pair()
    s.almost(pd[0].volume(), 4, "diagonal plane halves the cube", 1e-12)
    s.almost(pd[1].volume(), 4, "...both halves", 1e-12)

    # degenerate clouds
    var few = List[Float64]()
    for q in [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]:
        few.append(q)
    s.check(convex_hull(few).is_empty(), "3 points: no hull")
    var coplanar = List[Float64]()
    for k in range(10):
        coplanar.append(Float64(k % 4))
        coplanar.append(Float64(k // 4))
        coplanar.append(0.0)
    s.check(convex_hull(coplanar).is_empty(), "coplanar cloud: no hull")
    var line = List[Float64]()
    for k in range(10):
        line.append(Float64(k))
        line.append(Float64(k) * 2)
        line.append(Float64(k) * 3)
    s.check(convex_hull(line).is_empty(), "collinear cloud: no hull")
    var same = List[Float64]()
    for _ in range(12):
        same.append(1.5)
        same.append(1.5)
        same.append(1.5)
    s.check(convex_hull(same).is_empty(), "coincident points: no hull")
    var dup = _cube_cloud(False)
    for q in range(len(dup)):
        dup.append(dup[q])
    s.almost(convex_hull(dup).volume(), 1.0, "duplicated points do not change the hull", 1e-12)
    var thin = List[Float64]()
    for k in range(8):
        thin.append(Float64(k & 1))
        thin.append(Float64((k >> 1) & 1) * 1e-4)
        thin.append(Float64((k >> 2) & 1))
    s.almost(convex_hull(thin).volume(), 1e-4, "a 1e-4-thick slab is still a hull", 1e-10)
    s.almost(Polytope.empty().volume(), 0, "empty polytope has no volume", 0)


def main() raises:
    var s = Suite("polytope")
    case_ordinary(s)
    case_integration(s)
    case_extreme(s)
    s.finish()
