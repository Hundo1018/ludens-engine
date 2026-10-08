# tier: component
"""Convex decomposition seam (ROADMAP 17.5): two algorithms, one contract.

`SplitDecomposer` (hierarchical axis-plane splits) and `ClusterDecomposer`
(k-means on voxel centres) sit behind `ConvexDecomposer`. They are different
computations, so "parity" is the observable contract, stated with tolerances:

  coverage     every voxel of the solid is inside some part (>= 0.999);
  volume       the parts add up to the solid plus a bounded excess
               (<= 35 % of the solid, overlap included) and the two variants'
               totals are within 25 % of the mesh volume of each other;
  narrowphase  a probe box far inside the solid hits (GJK on the parts), a
               probe far outside -- including in the concave notch -- misses,
               and both variants return the SAME hit/miss for every probe that
               is not grazing the surface (>= `margin` voxels from it).

  ordinary     L- and U-shaped slabs.
  integration  parts become real `HullShape`s and meet a probe box in
               `hull_manifold`, the narrowphase the solver uses: same hit/miss.
  extreme      a convex mesh is ONE part; degenerate (zero-area) triangles are
               skipped, not fatal; a flat (zero-volume) mesh gives no parts; a
               malformed mesh raises; res = 1; an empty mesh.
"""

from harness.runner import Suite
from harness.meshes import MeshData, l_prism, u_prism, box_mesh
from geometry.vec import Real, Vec3
from geometry.gjk import ConvexPoly, gjk_intersect
from geometry.polytope import Polytope
from geometry.convex_decomp import (
    VoxelGrid,
    ConvexParts,
    SplitDecomposer,
    ClusterDecomposer,
    decompose_with,
    voxelize,
    mesh_volume,
)
from collision.hull import HullShape, hull_manifold


def _probe_hit(parts: ConvexParts, cx: Float64, cy: Float64, cz: Float64, h: Float64) -> Bool:
    """Does a small box probe (half extent h) touch any part? GJK per part."""
    var probe = ConvexPoly[3]()
    for k in range(8):
        probe.add(
            Vec3(
                Real(cx + (h if (k & 1) != 0 else -h)),
                Real(cy + (h if (k & 2) != 0 else -h)),
                Real(cz + (h if (k & 4) != 0 else -h)),
                0,
            )
        )
    for i in range(parts.count()):
        var poly = ConvexPoly[3]()
        for v in range(parts.hulls[i].nv()):
            poly.add(
                Vec3(
                    Real(parts.hulls[i].v[3 * v]),
                    Real(parts.hulls[i].v[3 * v + 1]),
                    Real(parts.hulls[i].v[3 * v + 2]),
                    0,
                )
            )
        if gjk_intersect(poly, probe):
            return True
    return False


def _clearance(g: VoxelGrid, x: Float64, y: Float64, z: Float64, cells: Int) -> Int:
    """+1 if the probe point is >= `cells` voxels inside the solid, -1 if >=
    `cells` voxels outside it, 0 if within `cells` of the surface."""
    var i = Int((x - g.ox) / g.h)
    var j = Int((y - g.oy) / g.h)
    var k = Int((z - g.oz) / g.h)
    var inside = g.is_set(i, j, k)
    for di in range(-cells, cells + 1):
        for dj in range(-cells, cells + 1):
            for dk in range(-cells, cells + 1):
                if g.is_set(i + di, j + dj, k + dk) != inside:
                    return 0
    return 1 if inside else -1


def run_shape(
    mut s: Suite, name: String, m: MeshData, res: Int, tol: Float64, max_parts: Int, margin: Int
) raises:
    var g = voxelize(m.v, m.t, res)
    var mv = mesh_volume(m.v, m.t)
    s.almost(g.solid_volume() / mv, 1.0, name + ": voxel volume ~ mesh volume", 0.06)
    var a = decompose_with(SplitDecomposer(max_parts, tol, 10), g)
    var b = decompose_with(ClusterDecomposer(max_parts, tol, 8), g)
    print(
        " ", name, "split:", a.count(), "parts excess", a.excess(g), "| cluster:", b.count(),
        "parts excess", b.excess(g),
    )
    s.check(a.count() >= 2 and b.count() >= 2, name + ": concave solid -> several parts")
    s.check(a.coverage(g) >= 0.999, name + ": split coverage")
    s.check(b.coverage(g) >= 0.999, name + ": cluster coverage")
    s.check(a.excess(g) <= 0.35, name + ": split excess bounded")
    s.check(b.excess(g) <= 0.35, name + ": cluster excess bounded")
    s.check(abs(a.total_volume() - b.total_volume()) <= 0.25 * mv, name + ": variants' volumes agree")
    # narrowphase agreement over a lattice of probes
    var agree = 0
    var graded = 0
    var wrong = 0
    var bd_lo = List[Float64]()
    bd_lo.append(g.ox)
    bd_lo.append(g.oy)
    bd_lo.append(g.oz)
    for ix in range(9):
        for iy in range(9):
            for iz in range(3):
                var x = g.ox + (Float64(ix) + 0.5) / 9.0 * Float64(g.nx) * g.h
                var y = g.oy + (Float64(iy) + 0.5) / 9.0 * Float64(g.ny) * g.h
                var z = g.oz + (Float64(iz) + 0.5) / 3.0 * Float64(g.nz) * g.h
                var cl = _clearance(g, x, y, z, margin)
                if cl == 0:
                    continue
                graded += 1
                var ha = _probe_hit(a, x, y, z, g.h * 0.3)
                var hb = _probe_hit(b, x, y, z, g.h * 0.3)
                if ha == hb:
                    agree += 1
                if cl > 0 and not (ha and hb):
                    wrong += 1
                if cl < 0 and (ha or hb):
                    wrong += 1
    print("   probes graded", graded, "variants agree", agree, "contradict the solid", wrong)
    s.check(graded > 20, name + ": enough graded probes")
    s.eqi(agree, graded, name + ": split and cluster narrowphase agree on every graded probe")
    s.eqi(wrong, 0, name + ": no graded probe contradicts the solid")


def case_hull_manifold(mut s: Suite) raises:
    """Parts as solver hulls: a probe box dropped into the L's long leg."""
    var m = l_prism(0.5)
    var g = voxelize(m.v, m.t, 20)
    var a = decompose_with(SplitDecomposer(6, 0.03, 10), g)
    var b = decompose_with(ClusterDecomposer(6, 0.03, 8), g)
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var probe = HullShape.box(Vec3(0.2, 0.2, 0.2, 0))
    var cases = List[Float64]()
    # probe centres: inside the leg, in the notch, past the end, on the corner
    for q in [1.5, 0.5, 0.25, 1.5, 1.5, 0.25, 3.0, 0.5, 0.25, 0.5, 1.5, 0.25, 1.35, 1.35, 0.25]:
        cases.append(q)
    var expect = List[Int]()
    for q in [1, 0, 0, 1, 0]:
        expect.append(q)
    for c in range(len(expect)):
        var results = List[Int]()
        for which in range(2):
            var hit = False
            ref parts = a if which == 0 else b
            for i in range(parts.count()):
                var hv = parts.hulls[i].hull_vertices(0, 0, 0, 1e-9)
                var hr = List[Real](capacity=len(hv))
                for k in range(len(hv)):
                    hr.append(Real(hv[k]))
                var hs = HullShape(hr^)
                var pc = Vec3(Real(cases[3 * c]), Real(cases[3 * c + 1]), Real(cases[3 * c + 2]), 0)
                var man = hull_manifold(
                    hs.world(Vec3(0, 0, 0, 0), ex, ey, ez),
                    probe.world(pc, ex, ey, ez),
                    hs.world_normals(ex, ey, ez),
                    probe.world_normals(ex, ey, ez),
                )
                if man.hit:
                    hit = True
            results.append(1 if hit else 0)
        s.eqi(results[0], results[1], "hull_manifold agrees across variants, probe " + String(c))
        s.eqi(results[0], expect[c], "hull_manifold matches the solid, probe " + String(c))


def case_extreme(mut s: Suite) raises:
    # a convex mesh is one part, in both algorithms
    var bx = box_mesh(1.0, 0.7, 0.4)
    var g = voxelize(bx.v, bx.t, 16)
    var a = decompose_with(SplitDecomposer(8, 0.03, 10), g)
    var b = decompose_with(ClusterDecomposer(8, 0.03, 8), g)
    s.eqi(a.count(), 1, "box: one part (split)")
    s.eqi(b.count(), 1, "box: one part (cluster)")

    # degenerate triangles are skipped
    var d = l_prism(0.5)
    var clean_g = voxelize(d.v, d.t, 16)
    var v0 = d.vert(0.3, 0.3, 0.1)
    d.tri(v0, v0, v0)  # three equal vertices
    var v1 = d.vert(0.5, 0.5, 0.1)
    var v2 = d.vert(0.9, 0.9, 0.1)
    d.tri(v0, v1, v2)  # collinear
    var dg = voxelize(d.v, d.t, 16)
    s.eqi(dg.filled(), clean_g.filled(), "degenerate triangles change nothing")
    var da = decompose_with(SplitDecomposer(8, 0.03, 10), dg)
    s.check(da.count() >= 2 and da.coverage(dg) >= 0.999, "decomposition survives degenerate triangles")

    # a flat mesh (all z = 0) encloses nothing
    var flat = MeshData()
    var f0 = flat.vert(0, 0, 0)
    var f1 = flat.vert(1, 0, 0)
    var f2 = flat.vert(1, 1, 0)
    var f3 = flat.vert(0, 1, 0)
    flat.tri(f0, f1, f2)
    flat.tri(f0, f2, f3)
    var fg = voxelize(flat.v, flat.t, 8)
    s.eqi(fg.filled(), 0, "coplanar mesh: no voxels")
    s.eqi(decompose_with(SplitDecomposer(8, 0.03, 10), fg).count(), 0, "coplanar mesh: no parts (split)")
    s.eqi(decompose_with(ClusterDecomposer(8, 0.03, 8), fg).count(), 0, "coplanar mesh: no parts (cluster)")

    # res = 1: a single voxel
    var g1 = voxelize(box_mesh(1, 1, 1).v, box_mesh(1, 1, 1).t, 1)
    s.check(g1.filled() >= 1, "res 1 still voxelises")
    s.eqi(decompose_with(SplitDecomposer(8, 0.03, 10), g1).count(), 1, "res 1: one part")

    # empty mesh
    var empty = MeshData()
    var eg = voxelize(empty.v, empty.t, 8)
    s.eqi(eg.filled(), 0, "empty mesh: empty grid")
    s.eqi(decompose_with(ClusterDecomposer(8, 0.03, 8), eg).count(), 0, "empty mesh: no parts")

    # malformed input raises at the boundary
    var bad = 0
    var m2 = box_mesh(1, 1, 1)
    m2.t[3] = 99
    try:
        _ = voxelize(m2.v, m2.t, 8)
    except:
        bad += 1
    try:
        _ = voxelize(box_mesh(1, 1, 1).v, box_mesh(1, 1, 1).t, 0)
    except:
        bad += 1
    var m3 = box_mesh(1, 1, 1)
    m3.t.append(0)
    try:
        _ = voxelize(m3.v, m3.t, 4)
    except:
        bad += 1
    s.eqi(bad, 3, "bad index, res 0 and ragged index list all raise")

    # max_parts is a hard cap
    var u = u_prism(0.5)
    var ug = voxelize(u.v, u.t, 20)
    s.check(decompose_with(SplitDecomposer(2, 0.0, 10), ug).count() <= 2, "split honours max_parts")
    s.check(decompose_with(ClusterDecomposer(2, 0.0, 8), ug).count() <= 2, "cluster honours max_parts")


def main() raises:
    var s = Suite("convex_decomp")
    run_shape(s, "L", l_prism(0.5), 24, 0.03, 8, 2)
    run_shape(s, "U", u_prism(0.5), 30, 0.05, 10, 2)
    case_hull_manifold(s)
    case_extreme(s)
    s.finish()
