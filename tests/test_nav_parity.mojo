# tier: component
"""Pathfinder seam parity (ROADMAP 17.14): PolyFunnel / GridAStar / FlowFieldPath /
HierFunnel.

Same baked mesh, 300 seeded random queries (some endpoints off the mesh, some
in a walled-off room, one off-mesh link):
- all four agree on reachability;
- GridAStar and FlowFieldPath return the same octile length (both are exact
  shortest paths on the same 8-connected span graph);
- every walking segment of every path passes `NavMesh.raycast`;
- PolyFunnel (any-angle, but searched over a polygon corridor that is not
  always the shortest) is at most 2 % plus one cell longer than the exact
  octile path; the octile path is at most 8.24 % (the octile / Euclidean
  worst case for one straight segment) plus one cell per funnel point longer
  than the funnel path (staircasing around each corner, start / end cells).
  Both bounds are empirical on this scene, not theorems. HierFunnel (HPA*
  over tiles, refined by a tile-masked PolyFunnel) meets the same bounds.
After carving an obstacle (mesh.version changes, HPA rebuilds its abstract
graph) the four still agree on 100 more queries.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64, Rng
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.path import NavPath, PathFinder, PolyFunnel, GridAStar, FlowFieldPath, PATH_OFFMESH
from nav.hpa import HierFunnel


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
        var x0 = lo[0]
        var y0 = lo[1]
        var z0 = lo[2]
        var x1 = hi[0]
        var y1 = hi[1]
        var z1 = hi[2]
        self.quad(x0, z0, x1, z1, y1)
        self._tri(_v(x0, y0, z0), _v(x0, y1, z0), _v(x0, y0, z1))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z0), _v(x0, y1, z1))
        self._tri(_v(x1, y0, z0), _v(x1, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y0, z1), _v(x1, y1, z1), _v(x1, y1, z0))
        self._tri(_v(x0, y0, z0), _v(x1, y0, z0), _v(x0, y1, z0))
        self._tri(_v(x1, y0, z0), _v(x1, y1, z0), _v(x0, y1, z0))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z1), _v(x1, y0, z1))
        self._tri(_v(x1, y0, z1), _v(x0, y1, z1), _v(x1, y1, z1))


def maze_scene() -> Scene:
    """30 x 30 floor; staggered walls; a closed 5 x 5 room in one corner;
    a separate 6 x 6 island east of the floor."""
    var sc = Scene()
    sc.quad(0, 0, 30, 30, 0)
    var h = Real(2.5)
    sc.box(_v(6, 0, 0), _v(6.5, h, 22))
    sc.box(_v(12, 0, 8), _v(12.5, h, 30))
    sc.box(_v(18, 0, 0), _v(18.5, h, 20))
    sc.box(_v(18.5, 0, 12), _v(26, h, 12.5))
    sc.box(_v(21, 0, 17), _v(23, h, 25))  # pillar
    # closed room at (24..29.5, 24..29.5)
    sc.box(_v(24, 0, 24), _v(29.5, h, 24.5))
    sc.box(_v(24, 0, 24), _v(24.5, h, 29.5))
    sc.box(_v(29, 0, 24), _v(29.5, h, 29.5))
    sc.box(_v(24, 0, 29), _v(29.5, h, 29.5))
    sc.quad(33, 0, 39, 6, 0)  # island
    return sc^


def _valid(mesh: NavMesh, p: NavPath) -> Bool:
    for i in range(1, len(p.points)):
        if p.flags[i - 1] == PATH_OFFMESH:
            continue
        if not mesh.raycast(p.points[i - 1], p.points[i]):
            return False
    return True


def main() raises:
    var s = Suite("nav_parity")
    var cfg = NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)
    var sc = maze_scene()
    var mesh = bake_navmesh(sc.verts, sc.tris, cfg)
    _ = mesh.add_offmesh_link(_v(29, 0, 3), _v(34, 0, 3), bidir=True, cost_mul=1.5)

    var pf = PolyFunnel()
    var ga = GridAStar()
    var ff = FlowFieldPath()
    var hf = HierFunnel()
    var rng = SplitMix64.seeded(17014)
    var n = 300
    var agree = 0
    var found = 0
    var grid_eq_flow = 0
    var valid = 0
    var bounds = 0
    var worst_ratio = Real(0)
    var sum_ratio = Real(0)
    var fewer_tiles = 0
    var long_q = 0
    for q in range(n + 100):
        if q == n:
            # carve a block into the open middle: every variant must follow
            _ = mesh.add_obstacle(_v(14, -0.5, 2), _v(16, 2, 6))
            _ = mesh.update()
        var a = _v(rng.next_f32() * 40 - 0.5, 0, rng.next_f32() * 31 - 0.5)
        var b = _v(rng.next_f32() * 40 - 0.5, 0, rng.next_f32() * 31 - 0.5)
        var p1 = pf.find(mesh, a, b)
        var p2 = ga.find(mesh, a, b)
        var p3 = ff.find(mesh, a, b)
        var p4 = hf.find(mesh, a, b)
        if p1.found == p2.found and p2.found == p3.found and p3.found == p4.found:
            agree += 1
        if not p2.found:
            continue
        found += 1
        if abs(p2.length() - p3.length()) <= 1e-3 * max(Real(1), p2.length()):
            grid_eq_flow += 1
        if _valid(mesh, p1) and _valid(mesh, p2) and _valid(mesh, p3) and _valid(mesh, p4):
            valid += 1
        var lg = p2.length()
        var ok = True
        for k in range(2):
            var lp = p1.length() if k == 0 else p4.length()
            var corners = Real(len(p1.points) if k == 0 else len(p4.points))
            if not (lp <= lg * Real(1.02) + cfg.cell_size and lg <= lp * Real(1.0824) + corners * cfg.cell_size):
                ok = False
        if ok:
            bounds += 1
        var lp1 = p1.length()
        if lp1 > 0:
            var r = lg / lp1
            worst_ratio = max(worst_ratio, r)
            sum_ratio += r
        if (b - a)[0] > 20 or (a - b)[0] > 20:
            long_q += 1
            if hf.last_tiles < len(mesh.tile_rects):
                fewer_tiles += 1
    s.eqi(agree, n + 100, "reachability: all four agree (300 + 100 after a carve)")
    s.check(found > (n + 100) // 4 and found < n + 100, "query mix has both reachable and unreachable pairs")
    s.eqi(grid_eq_flow, found, "grid A* length == flow-field length")
    s.eqi(valid, found, "every walking segment passes raycast")
    s.eqi(bounds, found, "funnel / hier <= 1.02 octile + 1 cell; octile <= 1.0824 funnel + (points) cells")
    s.eqi(fewer_tiles, long_q, "HPA refines only the tiles on the coarse route")
    print("  nav_parity: found", found, "of", n + 100, "| octile/funnel mean", sum_ratio / Real(max(found, 1)), "worst", worst_ratio)
    s.finish()
