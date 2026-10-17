# tier: integration
"""Tetrahedral meshing of a closed surface (ROADMAP 17.58,
`geometry.tetmesh`, `physics.fem.fem_from_tetmesh`).

  1. Ordinary: a closed UV sphere (r = 0.5, 24 x 12) at 8, 16 and 24 cells
     across: every tet has positive volume, and the tet volume approaches
     the faceted sphere's own volume (divergence theorem; the 24 x 12
     polyhedron is ~3 % smaller than 4/3 pi r^3): measured 3.6 % -> 0.37 %
     -> 0.03 %; asserted falling and < 1 % at 16 cells.
  2. Integration: every surface vertex is embedded (barycentric weights sum
     to 1, and evaluate back to the vertex within 1e-5 m); after rotating
     all tet nodes 30 degrees and moving them 1 m, the embedded vertices
     follow exactly the same motion (1e-5). The meshed sphere as an FEM
     body (E = 5e5, density 1000, explicit in 16 substeps) dropped from
     0.3 m onto a floor settles (fastest node < 0.1 m/s after 3 s) with its
     volume kept (2 %; its own weight strains it ~1 %).
  3. Extreme: res < 1 and a malformed mesh raise; a degenerate (flat) mesh
     gives no tets; density <= 0 raises.
"""

from std.math import sin, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot, cross
from geometry.quat import Quat
from geometry.tetmesh import TetMesh, tetrahedralize, embed, place
from physics.fem import FemBody, fem_from_tetmesh

comptime R: Real = 0.5


def _sphere(nu: Int, nv: Int) -> Tuple[List[Float64], List[Int]]:
    """UV sphere: poles plus (nv - 1) rings of nu vertices, outward triangles."""
    var v = List[Float64]()
    var t = List[Int]()
    v.append(0)
    v.append(Float64(R))
    v.append(0)
    for j in range(1, nv):
        var th = Float64(pi) * Float64(j) / Float64(nv)
        for i in range(nu):
            var ph = 2 * Float64(pi) * Float64(i) / Float64(nu)
            v.append(Float64(R) * sin(th) * cos(ph))
            v.append(Float64(R) * cos(th))
            v.append(Float64(R) * sin(th) * sin(ph))
    v.append(0)
    v.append(-Float64(R))
    v.append(0)
    var south = 1 + (nv - 1) * nu
    for i in range(nu):
        var a = 1 + i
        var b = 1 + (i + 1) % nu
        t.append(0)
        t.append(b)
        t.append(a)
    for j in range(nv - 2):
        for i in range(nu):
            var a = 1 + j * nu + i
            var b = 1 + j * nu + (i + 1) % nu
            var c = a + nu
            var d = b + nu
            t.append(a)
            t.append(b)
            t.append(d)
            t.append(a)
            t.append(d)
            t.append(c)
    for i in range(nu):
        var a = 1 + (nv - 2) * nu + i
        var b = 1 + (nv - 2) * nu + (i + 1) % nu
        t.append(south)
        t.append(a)
        t.append(b)
    return (v^, t^)


def main() raises:
    var s = Suite("tetmesh")
    var sp = _sphere(24, 12)
    var exact = Real(0)
    for f in range(len(sp[1]) // 3):
        var a = Vec3(Real(sp[0][3 * sp[1][3 * f]]), Real(sp[0][3 * sp[1][3 * f] + 1]), Real(sp[0][3 * sp[1][3 * f] + 2]), 0)
        var b = Vec3(Real(sp[0][3 * sp[1][3 * f + 1]]), Real(sp[0][3 * sp[1][3 * f + 1] + 1]), Real(sp[0][3 * sp[1][3 * f + 1] + 2]), 0)
        var c = Vec3(Real(sp[0][3 * sp[1][3 * f + 2]]), Real(sp[0][3 * sp[1][3 * f + 2] + 1]), Real(sp[0][3 * sp[1][3 * f + 2] + 2]), 0)
        exact += dot(a, cross(b, c)) / 6
    print("  faceted sphere volume", exact, " (4/3 pi r^3 =", Real(4.0 / 3.0 * pi) * R * R * R, ")")
    var errs = List[Real]()
    var all_pos = True
    for res in [8, 16, 24]:
        var m = tetrahedralize(sp[0], sp[1], res)
        for t in range(m.tet_count()):
            all_pos = all_pos and m.tet_volume(t) > 0
        var e = abs(m.volume() / exact - 1)
        errs.append(e)
        print("  sphere at", res, "cells: nodes", len(m.pts), " tets", m.tet_count(), " volume", m.volume(), "vs", exact, " error", e)
    s.check(all_pos, "every tet has positive volume")
    s.check(errs[2] < errs[1] and errs[1] < errs[0] and errs[1] < 0.01, "the tet volume converges to the surface's (< 1 % at 16 cells)")

    # ---- embedding --------------------------------------------------------------------------------------
    var m = tetrahedralize(sp[0], sp[1], 16)
    var nverts = len(sp[0]) // 3
    var worst = Real(0)
    var wsum = Real(0)
    var surf = List[Vec3]()
    for i in range(nverts):
        var p = Vec3(Real(sp[0][3 * i]), Real(sp[0][3 * i + 1]), Real(sp[0][3 * i + 2]), 0)
        surf.append(p)
        var e = embed(m, p)
        worst = max(worst, length(place(m, m.pts, e) - p))
        wsum = max(wsum, abs(e.w0 + e.w1 + e.w2 + e.w3 - 1))
    print("  embedding", nverts, "surface vertices: worst reconstruction", worst, "m, weight-sum error", wsum)
    s.check(worst < 1e-5 and wsum < 1e-5, "every surface vertex embeds and evaluates back")
    var q = Quat.from_axis_angle(Vec3(0.3, 1, 0.2, 0) / length(Vec3(0.3, 1, 0.2, 0)), 0.5235988)
    var moved = List[Vec3]()
    for p in m.pts:
        moved.append(q.rotate(p) + Vec3(1, 0, 0, 0))
    var follow = Real(0)
    for i in range(nverts):
        var e = embed(m, surf[i])
        follow = max(follow, length(place(m, moved, e) - (q.rotate(surf[i]) + Vec3(1, 0, 0, 0))))
    print("  rigid motion of the tets: embedded vertices off by at most", follow, "m")
    s.check(follow < 1e-5, "embedded vertices follow a rigid motion of the tets")

    # ---- as an FEM body ---------------------------------------------------------------------------------
    var b = FemBody(5.0e5, 0.3, 4.0)
    var mc = m.copy()
    for i in range(len(mc.pts)):
        mc.pts[i] = mc.pts[i] + Vec3(0, R + 0.3, 0, 0)
    fem_from_tetmesh(b, mc, 1000)
    var v0 = b.total_volume()
    for _ in range(180):
        for _ in range(16):
            b.step(1.0 / 960.0, Vec3(0, -9.8, 0, 0), 0.0)
    var low = Real(1e30)
    var vmax = Real(0)
    for i in range(b.node_count()):
        low = min(low, b.y[i])
        vmax = max(vmax, length(Vec3(b.vx[i], b.vy[i], b.vz[i], 0)))
    print("  meshed sphere dropped 0.3 m, 3 s: lowest node", low, " fastest node", vmax, "m/s  volume", b.total_volume(), "of", v0)
    s.check(abs(b.total_volume() / v0 - 1) < 0.02 and vmax < 0.1 and low >= 0, "it lands, settles and keeps its volume (2 %)")

    # ---- extremes ---------------------------------------------------------------------------------------
    var raised = 0
    try:
        _ = tetrahedralize(sp[0], sp[1], 0)
    except:
        raised += 1
    try:
        _ = tetrahedralize(sp[0], [0, 1], 4)
    except:
        raised += 1
    try:
        var bb = FemBody(1e4, 0.3)
        fem_from_tetmesh(bb, m, 0)
    except:
        raised += 1
    s.check(raised == 3, "res < 1, a malformed mesh and density <= 0 raise")
    var flat_v: List[Float64] = [0, 0, 0, 1, 0, 0, 0, 0, 1]
    var flat = tetrahedralize(flat_v, [0, 1, 2, 0, 2, 1], 4)
    s.check(flat.tet_count() == 0, "a flat mesh gives no tets")
    s.finish()
