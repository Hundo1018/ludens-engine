# tier: unit
"""Isosurfaces and particle surfaces (ROADMAP 17.60, `geometry.isosurface`).

  1. Ordinary: the zero set of the signed distance R - |x| (R = 0.4 on a
     41^3 grid, spacing 0.025) is a closed mesh (every edge shared by two
     triangles) with outward winding (positive volume); its area and
     volume are 4 pi R^2 and 4/3 pi R^3 within 2 % (printed).
  2. Integration: a ball of particles (radius 0.3, spacing 0.04) splatted
     with the poly6 kernel (R 0.1) and cut at half the interior value gives
     a closed surface whose sphericity A^3 / (36 pi V^2) is within 5 % of 1.
  3. Extreme: an all-outside or all-inside field gives no triangles; a
     grid with fewer than 2 nodes on an axis, spacing <= 0 and a kernel
     radius <= 0 raise.
"""

from std.math import pi, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.isosurface import ScalarGrid, marching_tetrahedra, splat_particles


def main() raises:
    var s = Suite("isosurface")
    var r = Real(0.4)
    var g = ScalarGrid(41, 41, 41, Vec3(-0.5, -0.5, -0.5, 0), 0.025)
    for k in range(41):
        for j in range(41):
            for i in range(41):
                g.v[g.idx(i, j, k)] = r - length(g.node(i, j, k))
    var m = marching_tetrahedra(g, 0)
    var a_want = 4 * Real(pi) * r * r
    var v_want = 4 * Real(pi) * r * r * r / 3
    print("  sphere R 0.4:", m.triangles(), "triangles, open edges", m.open_edges(), " area", m.area(), "(", a_want, ") volume", m.volume(), "(", v_want, ")")
    s.check(m.open_edges() == 0 and m.volume() > 0, "closed mesh, outward winding")
    s.check(abs(m.area() / a_want - 1) < 0.02 and abs(m.volume() / v_want - 1) < 0.02, "area and volume of the sphere (2 %)")

    var pts = List[Vec3]()
    var sp = Real(0.04)
    for k in range(-8, 9):
        for j in range(-8, 9):
            for i in range(-8, 9):
                var p = Vec3(Real(i), Real(j), Real(k), 0) * sp
                if length(p) <= 0.3:
                    pts.append(p)
    var pg = splat_particles(pts, 0.1, Vec3(-0.5, -0.5, -0.5, 0), 0.025, 41, 41, 41)
    var inner = pg.v[pg.idx(20, 20, 20)]
    var pm = marching_tetrahedra(pg, 0.5 * inner)
    var sph = pm.area() ** 3 / (36 * Real(pi) * pm.volume() * pm.volume())
    print("  particle ball (", len(pts), "particles): ", pm.triangles(), "triangles, open edges", pm.open_edges(), " volume", pm.volume(), " sphericity A^3 / 36 pi V^2", sph)
    s.check(pm.open_edges() == 0 and pm.volume() > 0 and abs(sph - 1) < 0.05, "particles give a closed, nearly spherical surface")

    var empty = ScalarGrid(5, 5, 5, Vec3(0, 0, 0, 0), 1)
    var full = ScalarGrid(5, 5, 5, Vec3(0, 0, 0, 0), 1)
    for q in range(125):
        full.v[q] = 1
    var raised = 0
    try:
        _ = ScalarGrid(1, 4, 4, Vec3(0, 0, 0, 0), 1)
    except:
        raised += 1
    try:
        _ = ScalarGrid(4, 4, 4, Vec3(0, 0, 0, 0), 0)
    except:
        raised += 1
    try:
        _ = splat_particles(pts, 0, Vec3(0, 0, 0, 0), 1, 4, 4, 4)
    except:
        raised += 1
    s.check(marching_tetrahedra(empty, 0.5).triangles() == 0 and marching_tetrahedra(full, 0.5).triangles() == 0 and raised == 3, "uniform fields give nothing; bad grids raise")
    s.finish()
