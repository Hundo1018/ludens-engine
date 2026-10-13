# tier: unit
"""Collision-mesh baking (ROADMAP 17.45): `geometry.mesh_bake`.

  1. Ordinary: a 4x4-quad grid exported with split vertices (every triangle
     owns its three) welds back to the 25 shared vertices with every original
     vertex still on the surface; a closed cube with one flipped face, one
     zero-area and one duplicate triangle repairs to 12 consistent faces with
     no open edge; a flat 20x20 grid (800 triangles) simplifies with zero
     error and its four boundary corners in place; on a flat grid every
     interior edge is inactive and only the rim is active; on a cube every
     edge is active (90 degree creases).
  2. Integration: `bake_collision_mesh` on a bumpy 24x24 heightfield-like
     surface (1152 triangles), target 1/8 with a 0.05 error budget: the budget
     stops it first (446 triangles) and the report's error bound holds --
     every original vertex lies within 2x the reported error of the baked
     surface -- and the result builds a `TriMesh`-ready soup (indices in range,
     no degenerate face).
  3. Extreme: empty mesh; a single triangle (nothing to collapse, all three
     edges active); an all-degenerate soup repairs to nothing.
"""

from std.math import sin, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.mesh_bake import weld, repair, simplify, active_edges, bake_collision_mesh


def _h(x: Real, z: Real, bumpy: Bool) -> Real:
    return Real(0.3) * sin(x * 0.7) * sin(z * 0.5) if bumpy else Real(0)


def _grid(n: Int, size: Real, bumpy: Bool, split: Bool) -> Tuple[List[Real], List[Int]]:
    """n x n quads on [0, size]^2 (y up), two triangles each, CCW from above."""
    var v = List[Real]()
    var ix = List[Int]()
    if not split:
        for j in range(n + 1):
            for i in range(n + 1):
                var x = size * Real(i) / Real(n)
                var z = size * Real(j) / Real(n)
                v.append(x)
                v.append(_h(x, z, bumpy))
                v.append(z)
        for j in range(n):
            for i in range(n):
                var a = j * (n + 1) + i
                var b = a + 1
                var c = a + n + 1
                var d = c + 1
                ix.append(a); ix.append(c); ix.append(b)
                ix.append(b); ix.append(c); ix.append(d)
    else:
        for j in range(n):
            for i in range(n):
                var corners = List[Tuple[Int, Int]]()
                corners.append((i, j)); corners.append((i, j + 1)); corners.append((i + 1, j))
                corners.append((i + 1, j)); corners.append((i, j + 1)); corners.append((i + 1, j + 1))
                for k in range(6):
                    var x = size * Real(corners[k][0]) / Real(n)
                    var z = size * Real(corners[k][1]) / Real(n)
                    v.append(x)
                    v.append(_h(x, z, bumpy))
                    v.append(z)
                    ix.append(len(ix))
    return (v^, ix^)


def _cube() -> Tuple[List[Real], List[Int]]:
    var v = List[Real]()
    for c in range(8):
        v.append(Real(c & 1))
        v.append(Real((c >> 1) & 1))
        v.append(Real((c >> 2) & 1))
    var ix = List[Int]()
    # outward CCW faces
    var f: List[Int] = [0, 2, 3, 0, 3, 1,  4, 5, 7, 4, 7, 6,  0, 1, 5, 0, 5, 4,  2, 6, 7, 2, 7, 3,  0, 4, 6, 0, 6, 2,  1, 3, 7, 1, 7, 5]
    for i in range(len(f)):
        ix.append(f[i])
    return (v^, ix^)


def _closest_on_tri(p: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    # Ericson 5.1.5 (same as collision.trimesh.closest_point_on_triangle, which
    # this unit test cannot import: collision is a higher layer than geometry)
    var ab = b - a
    var ac = c - a
    var ap = p - a
    var d1 = dot(ab, ap)
    var d2 = dot(ac, ap)
    if d1 <= 0 and d2 <= 0:
        return a
    var bp = p - b
    var d3 = dot(ab, bp)
    var d4 = dot(ac, bp)
    if d3 >= 0 and d4 <= d3:
        return b
    var vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        return a + ab * (d1 / (d1 - d3))
    var cp = p - c
    var d5 = dot(ab, cp)
    var d6 = dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        return c
    var vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        return a + ac * (d2 / (d2 - d6))
    var va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
    var den = 1 / (va + vb + vc)
    return a + ab * (vb * den) + ac * (vc * den)


def _v(v: List[Real], i: Int) -> Vec3:
    return Vec3(v[3 * i], v[3 * i + 1], v[3 * i + 2], 0)


def _max_dist(orig: List[Real], v: List[Real], ix: List[Int]) -> Float64:
    """Largest distance from an original vertex to the mesh (v, ix)."""
    var worst = Float64(0)
    for i in range(len(orig) // 3):
        var p = _v(orig, i)
        var best = Float64(1e30)
        for t in range(len(ix) // 3):
            var q = _closest_on_tri(p, _v(v, ix[3 * t]), _v(v, ix[3 * t + 1]), _v(v, ix[3 * t + 2]))
            best = min(best, Float64(length(q - p)))
        worst = max(worst, best)
    return worst


def main() raises:
    var s = Suite("mesh_bake")

    # ---- weld ----------------------------------------------------------
    var sg = _grid(4, 4, False, True)
    s.eqi(len(sg[0]) // 3, 96, "split grid: 4x4 quads x 6 own vertices = 96")
    var w = weld(sg[0], sg[1], 1e-4)
    s.eqi(len(w[0]) // 3, 25, "weld: 25 shared vertices (5 x 5)")
    s.eqi(w[2], 71, "weld: 71 vertices merged away")
    s.check(_max_dist(sg[0], w[0], w[1]) == 0, "weld: every original vertex is still on the surface")

    # ---- repair --------------------------------------------------------
    var cube = _cube()
    var cv = cube[0].copy()
    var ci = cube[1].copy()
    var t2 = ci[6 + 1]  # flip the third triangle
    ci[6 + 1] = ci[6 + 2]
    ci[6 + 2] = t2
    ci.append(0); ci.append(1); ci.append(1)  # zero-area (repeated vertex)
    ci.append(0); ci.append(3); ci.append(2)  # duplicate of triangle 0 (other winding)
    var r = repair(cv, ci)
    s.eqi(r.degenerate, 1, "repair: one degenerate triangle removed")
    s.eqi(r.duplicate, 1, "repair: one duplicate removed")
    s.eqi(len(ci) // 3, 12, "repair: 12 faces left")
    s.eqi(r.open_edges, 0, "repair: the cube is closed")
    s.eqi(r.nonmanifold_edges, 0, "repair: no non-manifold edge")
    s.check(r.flipped == 1 or r.flipped == 11, "repair: the odd face (or its 11 complements) flipped to agree")
    # every edge is walked once in each direction now
    var dir_ok = True
    for t in range(12):
        for k in range(3):
            var a = ci[3 * t + k]
            var b = ci[3 * t + (k + 1) % 3]
            var back = 0
            for u in range(12):
                for m in range(3):
                    if ci[3 * u + m] == b and ci[3 * u + (m + 1) % 3] == a:
                        back += 1
            if back != 1:
                dir_ok = False
    s.check(dir_ok, "repair: every edge is walked once each way (consistent winding)")

    # ---- simplify (flat) -----------------------------------------------
    var fg = _grid(20, 10, False, False)
    var fv = fg[0].copy()
    var fi = fg[1].copy()
    var sr = simplify(fv, fi, 2, 1e-6)
    print("  flat 20x20 grid: 800 ->", len(fi) // 3, "triangles,", sr[0], "collapses, error", sr[1])
    s.check(len(fi) // 3 < 800 // 10, "simplify: a flat grid loses > 90% of its triangles at zero error")
    s.check(sr[1] < 1e-6, "simplify: flat collapses cost nothing")
    var corners_ok = True
    for c in range(4):
        var want = Vec3(Real(10 * (c & 1)), 0, Real(10 * (c >> 1)), 0)
        var found = False
        for i in range(len(fv) // 3):
            if length(_v(fv, i) - want) < 1e-6:
                found = True
        corners_ok = corners_ok and found
    s.check(corners_ok, "simplify: the four boundary corners stay put")

    # ---- active edges --------------------------------------------------
    var flat = _grid(3, 3, False, False)
    var act = active_edges(flat[0], flat[1], 0.0872664626)
    var n_active = 0
    for t in range(len(act)):
        for k in range(3):
            if (act[t] >> UInt8(k)) & 1:
                n_active += 1
    s.eqi(n_active, 12, "active edges, flat 3x3 grid: only the 12 rim edges")
    var cact = active_edges(cube[0], cube[1], 0.0872664626)
    var cube_all = 0
    for t in range(len(cact)):
        for k in range(3):
            if (cact[t] >> UInt8(k)) & 1:
                cube_all += 1
    # 12 cube edges x 2 sides = 24 half-edges are creases; the 6 face diagonals x 2 are flat
    s.eqi(cube_all, 24, "active edges, cube: the 24 crease half-edges, not the 12 diagonal ones")

    # ---- bake (bumpy) --------------------------------------------------
    var bg = _grid(24, 12, True, True)
    var baked = bake_collision_mesh(bg[0], bg[1], 1e-4, 1152 // 8, 0.05)
    var rep = baked.report.copy()
    print("  bumpy 24x24: verts", rep.verts_in, "->", rep.verts_out, " tris", rep.tris_in, "->", rep.tris_out,
          " welded", rep.welded, " collapses", rep.collapses, " max error", rep.max_error)
    var dist = _max_dist(bg[0], baked.verts, baked.idx)
    print("  bumpy: largest original-vertex distance to the baked surface", dist)
    s.check(rep.tris_out < 1152 // 2 and rep.max_error <= 0.05, "bake: under half the triangles left, stopped by the 0.05 error budget before the 1/8 target")
    s.check(dist <= 2 * rep.max_error + 1e-6, "bake: every original vertex within 2x the reported error")
    var ok_idx = True
    for t in range(baked.ntri()):
        for k in range(3):
            if baked.idx[3 * t + k] < 0 or baked.idx[3 * t + k] >= len(baked.verts) // 3:
                ok_idx = False
        var a = _v(baked.verts, baked.idx[3 * t])
        var n = cross(_v(baked.verts, baked.idx[3 * t + 1]) - a, _v(baked.verts, baked.idx[3 * t + 2]) - a)
        if dot(n, n) == 0:
            ok_idx = False
    s.check(ok_idx, "bake: indices in range, no degenerate face")
    s.eqi(rep.open_edges, 4 * 24, "bake: the 96 rim edges stay open (boundary vertices are pinned)")

    # ---- extremes ------------------------------------------------------
    var empty = bake_collision_mesh(List[Real](), List[Int](), 1e-4, 0, 1)
    s.eqi(empty.ntri(), 0, "empty mesh bakes to empty")
    var one_v: List[Real] = [0, 0, 0, 1, 0, 0, 0, 0, 1]
    var one_i: List[Int] = [0, 2, 1]
    var one = bake_collision_mesh(one_v, one_i, 1e-4, 0, 1)
    s.eqi(one.ntri(), 1, "single triangle: nothing to collapse (all its vertices are boundary)")
    s.eqi(Int(one.active[0]), 7, "single triangle: all three edges active")
    var deg_v: List[Real] = [0, 0, 0, 1, 0, 0, 2, 0, 0]
    var deg_i: List[Int] = [0, 1, 2, 0, 0, 1]
    var deg = bake_collision_mesh(deg_v, deg_i, 1e-4)
    s.eqi(deg.ntri(), 0, "all-degenerate soup repairs to nothing")
    s.finish()
