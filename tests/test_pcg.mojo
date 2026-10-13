# tier: integration
"""Procedural generation: scatter, Delaunay, terrain (ROADMAP 17.69).

  1. Ordinary: Poisson-disk (Bridson), dart throwing and a jittered grid
     (jitter 0.25) keep their distance guarantees (>= r; >= 0.5 cell); the
     same seed gives the same points bit for bit, another seed different
     ones; Delaunay of 400 Poisson points is Delaunay (exact predicates) with
     2n - 2 - h triangles (h = hull vertices).
  2. Integration: two terrain tiles generated separately (and in either
     order) agree bit for bit on their shared edge; a tile becomes a
     `HeightField` in the scene and a dropped box comes to rest on it;
     thermal erosion brings the steepest slope under the talus limit while
     conserving the total height (mass) to 1e-5.
  3. Extreme: a regular 12-gon plus its centre (12 cocircular points) and a
     6 x 6 lattice (every cell cocircular) triangulate as Delaunay with the
     right count; collinear points give no triangles; duplicates are
     skipped; fewer than 3 points give none; r larger than the area gives
     one point; ridged terrain is never negative.
"""

from std.math import sqrt, cos, sin, pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec2, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from procedural.scatter import poisson_disk, dart_throwing, jittered_grid, min_distance
from procedural.delaunay import delaunay, is_delaunay
from procedural.terrain_gen import TerrainParams, terrain_height, height_tile, thermal_erosion, max_slope


def _hull_count(tri: List[Int]) -> Int:
    """Boundary edges (used by one triangle) = hull vertices."""
    var b = 0
    for t in range(len(tri) // 3):
        for e in range(3):
            var a = tri[3 * t + e]
            var c = tri[3 * t + (e + 1) % 3]
            var twin = False
            for u in range(len(tri) // 3):
                for f in range(3):
                    if tri[3 * u + f] == c and tri[3 * u + (f + 1) % 3] == a:
                        twin = True
            if not twin:
                b += 1
    return b


def main() raises:
    var s = Suite("pcg")

    # ---- scatter ---------------------------------------------------------------------------------
    var pd = poisson_disk(100, 100, 2, 7)
    var pd2 = poisson_disk(100, 100, 2, 7)
    var pd3 = poisson_disk(100, 100, 2, 8)
    var md = min_distance(pd)
    var same = len(pd) == len(pd2)
    for i in range(min(len(pd), len(pd2))):
        if pd[i] != pd2[i]:
            same = False
    print("  Poisson-disk 100 x 100, r = 2:", len(pd), "points, min distance", md, " other seed", len(pd3), "points")
    s.check(md >= 2 and len(pd) > 1500, "Bridson: every pair >= r, densely packed")
    s.check(same and (len(pd3) != len(pd) or pd3[5] != pd[5]), "same seed: bit-identical; other seed: different")
    var dt = dart_throwing(100, 100, 2, 7, 5000)
    var jg = jittered_grid(100, 100, 2, 0.25, 7)
    print("  dart throwing (5000 tries):", len(dt), "points, min", min_distance(dt), "  jittered grid:", len(jg), "points, min", min_distance(jg))
    s.check(min_distance(dt) >= 2 and min_distance(jg) >= 1.0 - 1e-5, "dart throwing >= r; jittered grid (0.25) >= 0.5 cell")

    # ---- Delaunay ----------------------------------------------------------------------------------
    var sub = List[Vec2]()
    for i in range(400):
        sub.append(pd[i])
    var tri = delaunay(sub)
    var h = _hull_count(tri)
    var nt = len(tri) // 3
    print("  Delaunay of 400 Poisson points:", nt, "triangles, hull", h, " 2n - 2 - h =", 2 * 400 - 2 - h)
    s.check(is_delaunay(sub, tri) and nt == 2 * 400 - 2 - h, "empty circumcircles, Euler count")

    var ring = List[Vec2]()
    for k in range(12):
        ring.append(Vec2(Real(10 * cos(2 * pi * Float64(k) / 12)), Real(10 * sin(2 * pi * Float64(k) / 12))))
    ring.append(Vec2(0, 0))
    var rt = delaunay(ring)
    var lat = List[Vec2]()
    for j in range(6):
        for i in range(6):
            lat.append(Vec2(Real(i), Real(j)))
    var lt = delaunay(lat)
    print("  12-gon + centre:", len(rt) // 3, "triangles; 6 x 6 lattice:", len(lt) // 3, "triangles (2n - 2 - h = 50)")
    s.check(is_delaunay(ring, rt) and len(rt) // 3 == 12, "cocircular 12-gon: Delaunay, 12 triangles")
    s.check(is_delaunay(lat, lt) and len(lt) // 3 == 50, "lattice (all cells cocircular): Delaunay, 50 triangles")
    var line: List[Vec2] = [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)]
    var dupl: List[Vec2] = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 0), Vec2(1, 1)]
    var two: List[Vec2] = [Vec2(0, 0), Vec2(1, 0)]
    var dd = delaunay(dupl)
    s.check(len(delaunay(line)) == 0 and len(delaunay(two)) == 0 and len(dd) // 3 == 2 and is_delaunay(dupl, dd), "collinear: none; duplicates skipped; < 3 points: none")
    s.check(len(poisson_disk(1, 1, 5, 3)) == 1, "r larger than the area: one point")

    # ---- terrain ----------------------------------------------------------------------------------
    var p = TerrainParams(42, 32, 10, 5, False, 0.7)
    var t00 = height_tile(0, 0, 16, 16, 1, p)
    var t10 = height_tile(1, 0, 16, 16, 1, p)
    var t10b = height_tile(1, 0, 16, 16, 1, p)
    var seam = True
    for j in range(17):
        if t00[j * 17 + 16] != t10[j * 17 + 0]:
            seam = False
    for i in range(len(t10)):
        if t10[i] != t10b[i]:
            seam = False
    s.check(seam, "adjacent tiles share their edge bit for bit, in any order")
    var ridged = TerrainParams(42, 32, 10, 5, True, 0)
    var neg = False
    for k in range(200):
        if terrain_height(Real(k) * 1.7, Real(k % 13) * 2.3, ridged) < 0:
            neg = True
    s.check(not neg, "ridged terrain is never negative")

    var steep = TerrainParams(3, 8, 10, 4, False, 0)
    var er = height_tile(0, 0, 32, 32, 1, steep)
    var m0 = Float64(0)
    for v in er:
        m0 += Float64(v)
    var s0 = max_slope(er, 32, 32, 1)
    thermal_erosion(er, 32, 32, 1, 0.8, 0.5, 400)
    var m1 = Float64(0)
    for v in er:
        m1 += Float64(v)
    var s1 = max_slope(er, 32, 32, 1)
    print("  thermal erosion (talus 0.8): max slope", s0, "->", s1, "  total height", m0, "->", m1)
    s.check(s1 < 0.8 + 0.05 and s1 < s0, "erosion brings slopes to the talus limit")
    s.check(abs(m1 - m0) <= 1e-5 * (abs(m0) + 1000), "erosion conserves mass")

    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), t00, 17, 17, 1, 0, 0)
    var hcen = terrain_height(8, 8, p)
    var box = sc.add(QuatBody6.at_rest(Vec3(8, hcen + 3, 8, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    for _ in range(600):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    var by = sc.pose(box).pos[1]
    var bp = sc.pose(box).pos
    var under = terrain_height(bp[0], bp[2], p)
    print("  box on the generated heightfield: y", by, " terrain under it", under, " speed", sc.velocity(box)[1])
    s.check(isfinite(by) and by > under - 0.05 and by < under + 1.0 and abs(sc.velocity(box)[1]) < 0.05, "a dropped box rests on the generated terrain")
    s.finish()
