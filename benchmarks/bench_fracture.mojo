"""Destruction and fracture (ROADMAP 17.5): what each stage costs.

The decomposition rows are the 17.5 SEAM -- `SplitDecomposer` and
`ClusterDecomposer` on the same voxel grids, with the quality each reaches
printed in the row label (parts, excess = sum of part volumes over solid volume
- 1; both cover 100 % of the solid, `test_convex_decomp` asserts that and the
narrowphase agreement). A concave L slab needs two parts and both find them (k-means spends a third
one for the same 0 % excess); on the U slab the hierarchical split reaches 2 %
excess with 3 parts where k-means needs 4 for 4.5 % -- but the split's plane
search builds a hull per candidate cut and costs ~10x as much. Quality for
build time: split is the offline choice, k-means the quick one.

The fracture rows are the pipeline: Voronoi pre-fracture (exact neighbour
pruning keeps 1000 seeds out of the all-pairs regime), one 27-plane runtime cut
producing 1000 pieces, adding 1000 fragments to a `ContactScene6` as hull
bodies, and the steady cost per solver step of a bonded wall.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable, now
from harness.meshes import MeshData, l_prism, u_prism
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.polytope import Polytope
from geometry.fracture_cut import FragmentSet, scatter_seeds, voronoi_fracture, cut_by_planes
from geometry.convex_decomp import (
    VoxelGrid,
    SplitDecomposer,
    ClusterDecomposer,
    decompose_with,
    voxelize,
)
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fracture import FractureSet

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _fmt(x: Float64) -> String:
    var v = Int(x * 1000.0 + 0.5)
    var s = String(v % 1000)
    while s.byte_length() < 3:
        s = "0" + s
    return String(v // 1000) + "." + s


def decomp_rows(mut t: BenchTable, name: String, m: MeshData, res: Int, tol: Float64) raises:
    var g = voxelize(m.v, m.t, res)
    var vox = g.filled()
    var t0 = now()
    var a = decompose_with(SplitDecomposer(10, tol, 10), g)
    var t1 = now()
    var b = decompose_with(ClusterDecomposer(10, tol, 8), g)
    var t2 = now()
    t.add(
        "split", vox, name + " res " + String(res) + ": " + String(a.count()) + " parts, excess " + _fmt(a.excess(g)),
        t1 - t0, 1,
    )
    t.add(
        "cluster", vox, name + " res " + String(res) + ": " + String(b.count()) + " parts, excess " + _fmt(b.excess(g)),
        t2 - t1, 1,
    )


def main() raises:
    var d = BenchTable("Convex decomposition variants (17.5 seam)")
    decomp_rows(d, "L slab", l_prism(0.5), 24, 0.03)
    decomp_rows(d, "U slab", u_prism(0.5), 30, 0.05)
    d.print_report()

    var f = BenchTable("Fracture pipeline (17.5)")
    var block = Polytope.box(0, 0, 0, 1, 1, 1)
    for n in [100, 1000]:
        var seeds = scatter_seeds(block.bounds(), n, 7, 0.0, 0.0, 0.0, 0.0)
        var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
        var t0 = now()
        voronoi_fracture(block, seeds, 0, 0.0, fs)
        var t1 = now()
        f.add("voronoi", fs.count(), "pre-fracture " + String(n) + " seeds", t1 - t0, fs.count())

    var planes = List[Float64]()
    for ax in range(3):
        for k in range(9):
            var dd = (Float64(k) + 1.0) / 10.0 * 2.0 - 1.0
            for z in range(3):
                planes.append(1.0 if z == ax else 0.0)
            planes.append(dd)
    var c0 = now()
    var pieces = cut_by_planes(block, planes, 0.0)
    var c1 = now()
    f.add("cut", len(pieces), "27 planes -> pieces (geometry)", c1 - c0, len(pieces))

    # 1000 pieces into a scene as hull bodies
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)), Vec3(30, 1, 30, 0), True)
    var fs2 = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    for i in range(len(pieces)):
        fs2.cells.append(pieces[i].copy())
        fs2.seed.append(i)
        fs2.part.append(0)
    var set = FractureSet(800, 0)
    var s0 = now()
    _ = set.spawn(sc, fs2, Vec3(0, 3, 0, 0), Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var s1 = now()
    f.add("spawn", set.fragments(), "fragments -> hull bodies", s1 - s0, set.fragments())

    # a bonded wall: cost per step
    var sc2 = ContactScene6[QuatBody6]()
    var ground = sc2.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)), Vec3(30, 1, 30, 0), True
    )
    var wall = Polytope.box(0, 1.0, 0, 1.5, 1.0, 0.15)
    var seeds2 = scatter_seeds(wall.bounds(), 40, 3, 0.0, 1.0, -0.15, 0.5)
    var fs3 = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(wall, seeds2, 0, 1e-5, fs3)
    var set2 = FractureSet(2000, 0)
    var first = set2.spawn(sc2, fs3, Vec3(0, 0, 0, 0), Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var nb = set2.bond_neighbors(sc2, first, 5e4)
    var na = set2.anchor(sc2, first, ground, Vec3(0, 0, 0, 0), Quat.identity(), 0.0, -1.0, 0.0, 0.0, 1e-6, 5e4)
    for i in range(set2.fragments()):
        sc2.set_can_sleep(set2.bid[i], False)  # measure the awake cost
    for _ in range(30):
        sc2.step_soft(DT, G)
    var w0 = now()
    for _ in range(60):
        sc2.step_soft(DT, G)
    var w1 = now()
    f.add(
        "step", set2.fragments(),
        "bonded wall, " + String(nb + na) + " welds, awake (soft step)", w1 - w0, 60,
    )
    f.print_report()
