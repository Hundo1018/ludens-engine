# tier: unit
"""Mesh -> SDF grid (ROADMAP 17.45): `geometry.sdf_grid`.

Mesh: a unit sphere from a 3x-subdivided octahedron (512 triangles, chord
error ~0.005), baked at 24^3 with 0.5 padding (cell 0.13).

  1. Ordinary: at 200 random points in the grid the sampled distance is
     within one cell diagonal of the exact distance to the mesh, and within
     a cell diagonal + the chord error of the analytic sphere |p| - 1; the
     centre is inside (negative), a corner outside.
  2. Integration: the gradient at radius 1.2 points outward (cos > 0.95 with
     the radial direction) -- what a contact normal needs; node values equal
     the exact signed distance at the nodes.
  3. Extreme: res = 1 (one node); an empty mesh (all zeros); an open
     hemisphere's winding number at its centre is ~0.5 (the measure that
     ray parity cannot give).
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, normalize, dot
from geometry.sdf_grid import bake_sdf_grid, bake_sdf_grid_bvh, winding_number, closest_on_triangle
from scheduler.rng import SplitMix64


def _sphere_mesh(levels: Int, keep_upper_only: Bool = False) -> Tuple[List[Real], List[Int]]:
    var v = List[Real]()
    var ix = List[Int]()
    var pts = List[Vec3]()
    pts.append(Vec3(1, 0, 0, 0)); pts.append(Vec3(-1, 0, 0, 0))
    pts.append(Vec3(0, 1, 0, 0)); pts.append(Vec3(0, -1, 0, 0))
    pts.append(Vec3(0, 0, 1, 0)); pts.append(Vec3(0, 0, -1, 0))
    var tris: List[Int] = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]
    for _ in range(levels):
        var nt = List[Int]()
        for t in range(len(tris) // 3):
            var a = tris[3 * t]
            var b = tris[3 * t + 1]
            var c = tris[3 * t + 2]
            pts.append(normalize(pts[a] + pts[b]))
            var ab = len(pts) - 1
            pts.append(normalize(pts[b] + pts[c]))
            var bc = len(pts) - 1
            pts.append(normalize(pts[c] + pts[a]))
            var ca = len(pts) - 1
            nt.append(a); nt.append(ab); nt.append(ca)
            nt.append(ab); nt.append(b); nt.append(bc)
            nt.append(ca); nt.append(bc); nt.append(c)
            nt.append(ab); nt.append(bc); nt.append(ca)
        tris = nt^
    for i in range(len(pts)):
        v.append(pts[i][0]); v.append(pts[i][1]); v.append(pts[i][2])
    for t in range(len(tris) // 3):
        if keep_upper_only:
            var cy = pts[tris[3 * t]][1] + pts[tris[3 * t + 1]][1] + pts[tris[3 * t + 2]][1]
            if cy < 0:
                continue
        ix.append(tris[3 * t]); ix.append(tris[3 * t + 1]); ix.append(tris[3 * t + 2])
    return (v^, ix^)


def _exact(v: List[Real], ix: List[Int], p: Vec3) -> Real:
    var best = Real(1e30)
    for t in range(len(ix) // 3):
        var a = Vec3(v[3 * ix[3 * t]], v[3 * ix[3 * t] + 1], v[3 * ix[3 * t] + 2], 0)
        var b = Vec3(v[3 * ix[3 * t + 1]], v[3 * ix[3 * t + 1] + 1], v[3 * ix[3 * t + 1] + 2], 0)
        var c = Vec3(v[3 * ix[3 * t + 2]], v[3 * ix[3 * t + 2] + 1], v[3 * ix[3 * t + 2] + 2], 0)
        best = min(best, length(closest_on_triangle(p, a, b, c) - p))
    return -best if winding_number(v, ix, p) > 0.5 else best


def main() raises:
    var s = Suite("sdf_grid")
    var m = _sphere_mesh(3)
    s.eqi(len(m[1]) // 3, 512, "test mesh: 512 triangles")
    var g = bake_sdf_grid(m[0], m[1], 24, 0.5)
    var diag = g.cell * sqrt(Real(3))
    print("  24^3 grid, cell", g.cell, " diagonal", diag)

    var rng = SplitMix64.seeded(1745)
    var worst_mesh = Real(0)
    var worst_sphere = Real(0)
    for _ in range(200):
        var p = Vec3(
            Real(rng.next_f32()) * 3 - 1.5, Real(rng.next_f32()) * 3 - 1.5, Real(rng.next_f32()) * 3 - 1.5, 0
        )
        var d = g.distance(p)
        worst_mesh = max(worst_mesh, abs(d - _exact(m[0], m[1], p)))
        worst_sphere = max(worst_sphere, abs(d - (length(p) - 1)))
    print("  worst |sdf - exact mesh distance|", worst_mesh, " worst |sdf - (|p| - 1)|", worst_sphere)
    s.check(worst_mesh <= diag, "sampled distance within one cell diagonal of the exact mesh distance")
    s.check(worst_sphere <= diag + 0.01, "and within a diagonal + chord error of the analytic sphere")
    s.check(g.distance(Vec3(0, 0, 0, 0)) < -0.8, "centre is inside (about -1; nearest nodes are 0.11 off-centre)")
    s.check(g.distance(Vec3(1.4, 1.4, 1.4, 0)) > 1, "corner is outside")

    var cos_ok = True
    for k in range(12):
        var dir = normalize(Vec3(Real(k % 3) - 1 + 0.3, Real((k // 3) % 2) - 0.5, Real(k % 4) - 1.5, 0))
        var gr = g.gradient(dir * 1.2)
        if dot(normalize(gr), dir) < 0.95:
            cos_ok = False
    s.check(cos_ok, "gradient at radius 1.2 points outward (cos > 0.95)")
    var nodes_ok = True
    for n in range(10):
        var i = (n * 7) % 24
        var j = (n * 5 + 3) % 24
        var k = (n * 11 + 1) % 24
        if abs(g.at(i, j, k) - _exact(m[0], m[1], g.node(i, j, k))) > 1e-6:
            nodes_ok = False
    s.check(nodes_ok, "node values are the exact signed distance")

    var one = bake_sdf_grid(m[0], m[1], 1, 0.5)
    s.check(one.distance(Vec3(5, 5, 5, 0)) == one.values[0], "res = 1: one node answers everywhere")
    var empty = bake_sdf_grid(List[Real](), List[Int](), 4, 1)
    s.check(empty.distance(Vec3(0, 0, 0, 0)) == 0, "empty mesh: all zeros")
    var hemi = _sphere_mesh(2, True)
    var w = winding_number(hemi[0], hemi[1], Vec3(0, 0, 0, 0))
    print("  open hemisphere winding at its centre", w)
    s.check(abs(w - 0.5) < 0.02, "open hemisphere: winding number ~0.5 at the centre")
    # ---- BVH bake == brute bake (ROADMAP 17.45) ----
    var shapes = List[Int]()
    var same_all = True
    for which in range(3):
        var mesh = _sphere_mesh(3, which == 1)
        if which == 2:
            mesh = _sphere_mesh(2)
        var gb = bake_sdf_grid(mesh[0], mesh[1], 20, 0.5)
        var gv = bake_sdf_grid_bvh(mesh[0], mesh[1], 20, 0.5)
        for c in range(len(gb.values)):
            if gb.values[c] != gv.values[c]:
                same_all = False
        shapes.append(len(mesh[1]) // 3)
    print("  BVH bake vs brute, res 20: closed 512-tri sphere, open 256-tri hemisphere, 128-tri sphere: identical", same_all)
    s.check(same_all, "BVH bake == brute bake, every node (closed and open meshes)")
    s.finish()
