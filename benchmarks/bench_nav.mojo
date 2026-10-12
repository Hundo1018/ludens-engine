"""Navigation (ROADMAP 17.14): bake, pathfinder seam, flow field, carving.

Scene: an L x L floor with a seeded wall maze (a wall segment on every 8 m
grid line with one or two gaps per cell side), agent radius 0.3 m, 0.25 m
cells, 16-cell tiles.

Tables:
1. bake cost and output size against L (rasterise + filters + compact +
   erode + rectangles + links);
2. per-query cost of the three `PathFinder` variants on the same 200 seeded
   queries, with mean nodes expanded and mean path length (the any-angle
   funnel is shorter than the octile grid / flow paths);
3. 5000 agents heading to one goal: 5000 funnel queries vs one flow-field
   build + 5000 O(1) direction reads;
4. dynamic obstacle: incremental `update` (dirty tiles only) vs rebuilding
   every tile vs a full re-bake;
5. long queries on the 128 m maze: flat polygon search vs HPA* over tiles
   (abstract graph build cost, per-query cost, nodes expanded, tiles
   searched in detail);
6. 3D volume navigation: octree build and leaf count, then SVO A* vs dense
   26-connected voxel A* on the same seeded queries.

Run: pixi run mojo run -I build benchmarks/bench_nav.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64, Rng
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.path import NavPath, PathFinder, PolyFunnel, GridAStar, FlowFieldPath, FlowField
from nav.hpa import HierFunnel, HpaGraph
from nav.volume import VolumeNav, VolumeConfig, SvoAStar, SmoothedVoxelAStar, VolumeFinder


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


struct Scene(Movable):
    var verts: List[Vec3]
    var tris: List[Int]

    def __init__(out self):
        self.verts = List[Vec3]()
        self.tris = List[Int]()

    def _tri(mut self, a: Vec3, b: Vec3, c: Vec3):
        var n = len(self.verts)
        self.verts.append(a)
        self.verts.append(b)
        self.verts.append(c)
        self.tris.append(n)
        self.tris.append(n + 1)
        self.tris.append(n + 2)

    def quad(mut self, x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
        self._tri(_v(x0, y, z0), _v(x0, y, z1), _v(x1, y, z0))
        self._tri(_v(x1, y, z0), _v(x0, y, z1), _v(x1, y, z1))

    def box(mut self, lo: Vec3, hi: Vec3):
        """Closed box; the bottom face is included so volume voxelisation
        sees floating slabs as solid from below too."""
        var x0 = lo[0]
        var y0 = lo[1]
        var z0 = lo[2]
        var x1 = hi[0]
        var y1 = hi[1]
        var z1 = hi[2]
        self.quad(x0, z0, x1, z1, y1)
        self.quad(x0, z0, x1, z1, y0)
        self._tri(_v(x0, y0, z0), _v(x0, y1, z0), _v(x0, y0, z1))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z0), _v(x0, y1, z1))
        self._tri(_v(x1, y0, z0), _v(x1, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y0, z1), _v(x1, y1, z1), _v(x1, y1, z0))
        self._tri(_v(x0, y0, z0), _v(x1, y0, z0), _v(x0, y1, z0))
        self._tri(_v(x1, y0, z0), _v(x1, y1, z0), _v(x0, y1, z0))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z1), _v(x1, y0, z1))
        self._tri(_v(x1, y0, z1), _v(x0, y1, z1), _v(x1, y1, z1))


def maze(l: Int, seed: UInt64) -> Scene:
    var sc = Scene()
    var L = Real(l)
    sc.quad(0, 0, L, L, 0)
    var rng = SplitMix64.seeded(seed)
    var cells = l // 8
    for i in range(1, cells):
        for j in range(cells):
            # wall on x = 8 i, z in [8 j, 8 j + 8) with a 2 m gap at a random spot
            var g = Real(8 * j) + 1 + rng.next_f32() * 5
            var x = Real(8 * i)
            if g > Real(8 * j) + 0.1:
                sc.box(_v(x, 0, Real(8 * j)), _v(x + 0.5, 2.5, g))
            sc.box(_v(x, 0, g + 2), _v(x + 0.5, 2.5, Real(8 * j + 8)))
            # wall on z = 8 i, x in [8 j, 8 j + 8): solid with probability 0.5
            if rng.next_f32() < 0.5:
                var z = Real(8 * i)
                sc.box(_v(Real(8 * j), 0, z), _v(Real(8 * j) + 5, 2.5, z + 0.5))
    return sc^


def _cfg() -> NavBakeConfig:
    return NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)


def _queries(l: Int, n: Int) -> List[Vec3]:
    var rng = SplitMix64.seeded(1714)
    var q = List[Vec3]()
    for _ in range(2 * n):
        q.append(_v(1 + rng.next_f32() * Real(l - 2), 0, 1 + rng.next_f32() * Real(l - 2)))
    return q^


def _run[P: PathFinder](mut t: BenchTable, var pf: P, name: String, mesh: NavMesh, q: List[Vec3], l: Int):
    var n = len(q) // 2
    var expanded = 0
    var length = Real(0)
    var found = 0
    var t0 = now()
    for i in range(n):
        var p = pf.find(mesh, q[2 * i], q[2 * i + 1])
        expanded += p.expanded
        if p.found:
            found += 1
            length += p.length()
    var dt = now() - t0
    var label = name + " (found " + String(found) + ", mean expanded " + String(expanded // max(n, 1))
    label += ", mean length " + String(Int(length / Real(max(found, 1)) * 100) / 100) + " m)"
    t.add(label, l, "query", dt, n)


def main() raises:
    var cfg = _cfg()

    var tb = BenchTable("Navmesh bake (17.14): voxelise -> compact -> erode -> tile rectangles -> links")
    for l in [32, 64, 128]:
        var sc = maze(l, 7)
        var t0 = now()
        var mesh = bake_navmesh(sc.verts, sc.tris, cfg)
        var dt = now() - t0
        var label = "bake " + String(l) + " m (" + String(len(sc.tris) // 3) + " tris, "
        label += String(mesh.field.span_count()) + " spans, " + String(mesh.poly_count()) + " polys, "
        label += String(mesh.link_count()) + " links)"
        tb.add(label, l, "bake", dt, 1)
    tb.print_report()

    var l = 64
    var sc = maze(l, 7)
    var mesh = bake_navmesh(sc.verts, sc.tris, cfg)
    var q = _queries(l, 200)
    var tq = BenchTable("Pathfinder seam (17.14): 200 seeded queries on the 64 m maze")
    _run(tq, PolyFunnel(), "PolyFunnel (A* polys + funnel + smooth)", mesh, q, l)
    _run(tq, PolyFunnel(smooth=False), "PolyFunnel (no smoothing)", mesh, q, l)
    _run(tq, GridAStar(), "GridAStar (8-conn spans)", mesh, q, l)
    _run(tq, FlowFieldPath(), "FlowFieldPath (field per goal)", mesh, q, l)
    tq.print_report()

    # 5000 agents, one rally point
    var tf = BenchTable("5000 agents to one goal (17.14): per-agent search vs one flow field")
    var rng = SplitMix64.seeded(5000)
    var starts = List[Vec3]()
    var na = 5000
    for _ in range(na):
        starts.append(_v(1 + rng.next_f32() * Real(l - 2), 0, 1 + rng.next_f32() * Real(l - 2)))
    var goal = _v(Real(l) - 3, 0, Real(l) - 3)
    var pf = PolyFunnel()
    var t0 = now()
    var acc = Real(0)
    for i in range(na):
        acc += pf.find(mesh, starts[i], goal).length()
    tf.add("PolyFunnel x 5000", na, "agent", now() - t0, na)
    var ff = FlowField()
    t0 = now()
    _ = ff.build(mesh, goal)
    var tb_ns = now() - t0
    tf.add("FlowField build (once)", mesh.field.span_count(), "span", tb_ns, mesh.field.span_count())
    t0 = now()
    for i in range(na):
        acc += ff.direction(mesh, starts[i])[0]
    tf.add("FlowField direction read", na, "agent", now() - t0, na)
    keep(acc)
    tf.print_report()

    # carving
    var tc = BenchTable("Dynamic obstacle (17.14): 1 x 1 m box on the 64 m maze")
    var reps = 20
    var tiles = 0
    t0 = now()
    for r in range(reps):
        var x = Real(10 + r * 2)
        var id = mesh.add_obstacle(_v(x, -0.5, 20), _v(x + 1, 2, 21))
        tiles += mesh.update()
        mesh.remove_obstacle(id)
        tiles += mesh.update()
    tc.add("incremental update (" + String(tiles // (2 * reps)) + " tiles / update)", l, "update", now() - t0, 2 * reps)
    t0 = now()
    for _ in range(4):
        mesh.rebuild_all()
    tc.add("rebuild every tile (" + String(len(mesh.tile_rects)) + " tiles)", l, "update", now() - t0, 4)
    t0 = now()
    for _ in range(2):
        var m2 = bake_navmesh(sc.verts, sc.tris, cfg)
        keep(m2.poly_count())
    tc.add("full re-bake", l, "update", now() - t0, 2)
    tc.print_report()

    # hierarchical
    var big = maze(128, 7)
    var mb = bake_navmesh(big.verts, big.tris, cfg)
    var th = BenchTable("Hierarchical pathfinding (17.14): 100 long queries on the 128 m maze")
    var hg = HpaGraph()
    t0 = now()
    hg.build(mb)
    th.add("HPA abstract graph build (" + String(hg.entrance_count) + " entrances, " + String(len(hg.ab_to)) + " edges)", len(mb.tile_rects), "tile", now() - t0, len(mb.tile_rects))
    var lq = List[Vec3]()
    var rq = SplitMix64.seeded(128)
    while len(lq) < 200:
        var qa = _v(1 + rq.next_f32() * 126, 0, 1 + rq.next_f32() * 126)
        var qb = _v(1 + rq.next_f32() * 126, 0, 1 + rq.next_f32() * 126)
        if abs(qa[0] - qb[0]) + abs(qa[2] - qb[2]) < 96:
            continue
        lq.append(qa)
        lq.append(qb)
    _run(th, PolyFunnel(), "PolyFunnel (flat)", mb, lq, 128)
    var hfn = HierFunnel()
    _ = hfn.find(mb, lq[0], lq[1])  # build outside the timed loop
    var htiles = 0
    var hexp = 0
    var hlen = Real(0)
    var hfound = 0
    t0 = now()
    for i in range(len(lq) // 2):
        var p = hfn.find(mb, lq[2 * i], lq[2 * i + 1])
        htiles += hfn.last_tiles
        hexp += p.expanded
        if p.found:
            hfound += 1
            hlen += p.length()
    var hl = "HierFunnel (found " + String(hfound) + ", mean expanded " + String(hexp // 100)
    hl += ", mean length " + String(Int(hlen / Real(max(hfound, 1)) * 100) / 100) + " m, tiles searched "
    hl += String(htiles // 100) + " of " + String(len(mb.tile_rects)) + ")"
    th.add(hl, 128, "query", now() - t0, 100)
    th.print_report()

    # volume
    var tv = BenchTable("3D volume navigation (17.14): 64 x 16 x 64 m, 0.25 m voxels, pillars + floating slabs")
    var vs = Scene()
    vs.quad(0, 0, 64, 64, 0)
    var rv = SplitMix64.seeded(3)
    for _ in range(40):
        var x = rv.next_f32() * 60
        var z = rv.next_f32() * 60
        var y = rv.next_f32() * 12
        var w = 1 + rv.next_f32() * 4
        vs.box(_v(x, 0 if y < 4 else y, z), _v(x + w, y + 2, z + w))
    t0 = now()
    var vol = VolumeNav(vs.verts, vs.tris, _v(0, -0.5, 0), _v(64, 16, 64), VolumeConfig(0.25, 0.4))
    var vb = now() - t0
    tv.add("build (" + String(vol.nx * vol.ny * vol.nz) + " voxels, " + String(vol.node_count()) + " octree nodes, " + String(vol.leaf_count()) + " free leaves)", vol.nx * vol.ny * vol.nz, "voxel", vb, vol.nx * vol.ny * vol.nz)
    var vq = List[Vec3]()
    var rr = SplitMix64.seeded(9)
    while len(vq) < 60:
        var p = _v(1 + rr.next_f32() * 62, 0.5 + rr.next_f32() * 14, 1 + rr.next_f32() * 62)
        if vol.point_free(p):
            vq.append(p)
    _vrun(tv, SvoAStar(), "SvoAStar", vol, vq)
    _vrun(tv, SmoothedVoxelAStar(), "SmoothedVoxelAStar", vol, vq)
    tv.print_report()


def _vrun[F: VolumeFinder](mut t: BenchTable, var f: F, name: String, vol: VolumeNav, q: List[Vec3]):
    var n = len(q) // 2
    var expanded = 0
    var length = Real(0)
    var found = 0
    var t0 = now()
    for i in range(n):
        var p = f.find(vol, q[2 * i], q[2 * i + 1])
        expanded += p.expanded
        if p.found:
            found += 1
            length += p.length()
    var dt = now() - t0
    var label = name + " (found " + String(found) + ", mean expanded " + String(expanded // max(n, 1))
    label += ", mean length " + String(Int(length / Real(max(found, 1)) * 100) / 100) + " m)"
    t.add(label, n, "query", dt, n)
