# tier: component
"""Navmesh bake + pathfinding + carving (ROADMAP 17.14).

Ordinary: single agent around a wall, ramp, steps. Integration-style: dynamic
obstacle carve == from-scratch rebuild, off-mesh link joins islands.
Extreme: no path, start off the mesh, start == goal, clearance-blocked
corridor, low ceiling, hole in the floor, bad config / input.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh, dist3
from nav.path import NavPath, PolyFunnel, GridAStar, FlowFieldPath, PATH_OFFMESH


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
        """Up-facing horizontal quad."""
        self.slope(x0, z0, x1, z1, y, y)

    def slope(mut self, x0: Real, z0: Real, x1: Real, z1: Real, y0: Real, y1: Real):
        """Up-facing quad whose height goes y0 at x0 -> y1 at x1."""
        self._tri(_v(x0, y0, z0), _v(x0, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y1, z0), _v(x0, y0, z1), _v(x1, y1, z1))

    def box(mut self, lo: Vec3, hi: Vec3):
        """Closed box with outward normals (sides are walls, top walkable)."""
        var x0 = lo[0]
        var y0 = lo[1]
        var z0 = lo[2]
        var x1 = hi[0]
        var y1 = hi[1]
        var z1 = hi[2]
        self.quad(x0, z0, x1, z1, y1)  # top
        # -x side
        self._tri(_v(x0, y0, z0), _v(x0, y1, z0), _v(x0, y0, z1))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z0), _v(x0, y1, z1))
        # +x side
        self._tri(_v(x1, y0, z0), _v(x1, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y0, z1), _v(x1, y1, z1), _v(x1, y1, z0))
        # -z side
        self._tri(_v(x0, y0, z0), _v(x1, y0, z0), _v(x0, y1, z0))
        self._tri(_v(x1, y0, z0), _v(x1, y1, z0), _v(x0, y1, z0))
        # +z side
        self._tri(_v(x0, y0, z1), _v(x0, y1, z1), _v(x1, y0, z1))
        self._tri(_v(x1, y0, z1), _v(x0, y1, z1), _v(x1, y1, z1))


def _cfg() -> NavBakeConfig:
    return NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)


def _valid(mesh: NavMesh, p: NavPath) -> Bool:
    """Every walking segment stays on the mesh."""
    for i in range(1, len(p.points)):
        if p.flags[i - 1] == PATH_OFFMESH:
            continue
        if not mesh.raycast(p.points[i - 1], p.points[i]):
            return False
    return True


def _has_offmesh(p: NavPath) -> Bool:
    for f in p.flags:
        if f == PATH_OFFMESH:
            return True
    return False


def _same_polys(a: NavMesh, b: NavMesh) -> Bool:
    if a.poly_count() != b.poly_count() or a.link_count() != b.link_count():
        return False
    for i in range(len(a.p_verts)):
        var d = a.p_verts[i] - b.p_verts[i]
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            return False
    for i in range(a.link_count()):
        if a.l_to[i] != b.l_to[i]:
            return False
    return True


def _wall_scene() -> Scene:
    """20 x 20 floor; a wall along x = 10 from z = 0 to z = 16 (gap at z > 16)."""
    var sc = Scene()
    sc.quad(0, 0, 20, 20, 0)
    sc.box(_v(9.75, 0, -0.5), _v(10.25, 2.5, 16))
    return sc^


def main() raises:
    var s = Suite("nav")
    var cfg = _cfg()

    # ---- 1. ordinary: around a wall ----
    var sc = _wall_scene()
    var mesh = bake_navmesh(sc.verts, sc.tris, cfg)
    s.check(mesh.poly_count() > 0, "wall scene bakes polygons")
    s.check(mesh.find_poly(_v(10, 0, 8)) < 0, "wall cell is not walkable")
    s.check(mesh.find_poly(_v(10, 0, 18)) >= 0, "gap above the wall is walkable")
    var a = _v(5, 0, 4)
    var b = _v(15, 0, 4)
    var pf = PolyFunnel()
    var p = pf.find(mesh, a, b)
    s.check(p.found, "path found around the wall")
    s.check(_valid(mesh, p), "funnel path stays on the mesh")
    # erosion keeps ceil(0.3 / 0.25) = 2 cells = 0.5 m from the wall, so the
    # shortest route turns at (9.25, 16.5) and (10.75, 16.5):
    var ideal = dist3(a, _v(9.25, 0, 16.5)) + 1.5 + dist3(_v(10.75, 0, 16.5), b)
    s.check(p.length() > dist3(a, b) + 10, "path detours through the gap")
    s.check(p.length() >= ideal - 1e-3, "no shorter than the eroded-geometry shortest")
    s.check(p.length() < ideal * 1.02, "within 2 % of the eroded-geometry shortest")
    s.check(dist3(p.points[0], a) < 0.01 and dist3(p.points[len(p.points) - 1], b) < 0.01, "path endpoints = query")
    s.check(len(p.points) <= 6, "at most 4 corners (gap ends + chamfer steps)")
    var bake2 = bake_navmesh(sc.verts, sc.tris, cfg)
    s.check(_same_polys(mesh, bake2), "bake is deterministic")

    # ---- 2. clearance: corridor narrower than 2r is closed ----
    var nar = Scene()
    nar.quad(0, 0, 10, 10, 0)
    nar.box(_v(4.75, 0, -0.5), _v(5.25, 2.5, 4.8))
    nar.box(_v(4.75, 0, 5.2), _v(5.25, 2.5, 10.5))  # 0.4 m gap < 0.6 m
    var mn = bake_navmesh(nar.verts, nar.tris, cfg)
    s.check(not pf.find(mn, _v(2, 0, 5), _v(8, 0, 5)).found, "0.4 m gap blocks a 0.3 m-radius agent")
    var wide = Scene()
    wide.quad(0, 0, 10, 10, 0)
    wide.box(_v(4.75, 0, -0.5), _v(5.25, 2.5, 4.25))
    wide.box(_v(4.75, 0, 5.75), _v(5.25, 2.5, 10.5))  # 1.5 m gap
    var mw = bake_navmesh(wide.verts, wide.tris, cfg)
    var pw = pf.find(mw, _v(2, 0, 5), _v(8, 0, 5))
    s.check(pw.found and _valid(mw, pw), "1.5 m gap passes")

    # ---- 3. ramp up to a platform ----
    var rs = Scene()
    rs.quad(0, 0, 6, 6, 0)
    rs.slope(6, 0, 12, 6, 0, 2)  # 18.4 deg
    rs.quad(12, 0, 18, 6, 2)
    var mr = bake_navmesh(rs.verts, rs.tris, cfg)
    var pr = pf.find(mr, _v(2, 0, 3), _v(16, 2, 3))
    s.check(pr.found, "ramp path found")
    s.almost(Float64(pr.points[len(pr.points) - 1][1]), 2.0, "path ends on the platform", tol=0.15)
    s.almost(Float64(mr.height_at(mr.find_poly(_v(9, 1, 3)), _v(9, 1, 3))), 1.0, "ramp mid height", tol=0.15)
    s.check(_valid(mr, pr), "ramp path on mesh")

    # ---- 4. steps: 0.3 m climbs, 0.6 m does not ----
    var st = Scene()
    st.quad(0, 0, 5, 5, 0)
    st.quad(5, 0, 10, 5, 0.3)
    st.quad(10, 0, 15, 5, 0.9)
    var ms = bake_navmesh(st.verts, st.tris, cfg)
    s.check(pf.find(ms, _v(2, 0, 2.5), _v(7, 0.3, 2.5)).found, "0.3 m step is climbable")
    s.check(not pf.find(ms, _v(2, 0, 2.5), _v(12, 0.9, 2.5)).found, "0.6 m step is not")

    # ---- 5. low ceiling: 1.0 m slab removes the floor under it ----
    var lc = Scene()
    lc.quad(0, 0, 10, 10, 0)
    lc.box(_v(3, 1.0, 3), _v(7, 1.2, 7))
    var ml = bake_navmesh(lc.verts, lc.tris, cfg)
    s.check(ml.field.span_at(_v(5, 0, 5), 0.3) < 0, "no floor under a 1.0 m ceiling")
    s.check(ml.find_poly(_v(1, 0, 1)) >= 0, "floor outside the slab")
    var pl = pf.find(ml, _v(1, 0, 5), _v(9, 0, 5))
    s.check(pl.found and _valid(ml, pl), "path goes around the low ceiling")

    # ---- 6. off-mesh link joins two islands ----
    var isl = Scene()
    isl.quad(0, 0, 5, 5, 0)
    isl.quad(8, 0, 13, 5, 0)
    var mi = bake_navmesh(isl.verts, isl.tris, cfg)
    s.check(not pf.find(mi, _v(2, 0, 2), _v(10, 0, 2)).found, "islands: no path")
    var ga = GridAStar()
    var ff = FlowFieldPath()
    s.check(not ga.find(mi, _v(2, 0, 2), _v(10, 0, 2)).found, "islands: grid no path")
    s.check(not ff.find(mi, _v(2, 0, 2), _v(10, 0, 2)).found, "islands: flow no path")
    _ = mi.add_offmesh_link(_v(4.4, 0, 2.5), _v(8.6, 0, 2.5), bidir=False)
    var po = pf.find(mi, _v(2, 0, 2), _v(10, 0, 2))
    s.check(po.found and _has_offmesh(po), "jump link: funnel path uses it")
    s.check(ga.find(mi, _v(2, 0, 2), _v(10, 0, 2)).found, "jump link: grid path")
    var fo = ff.find(mi, _v(2, 0, 2), _v(10, 0, 2))
    s.check(fo.found and _has_offmesh(fo), "jump link: flow path uses it")
    s.check(not pf.find(mi, _v(10, 0, 2), _v(2, 0, 2)).found, "one-way link is one way")
    var raised = False
    try:
        _ = mi.add_offmesh_link(_v(6.5, 0, 2.5), _v(8.6, 0, 2.5))
    except:
        raised = True
    s.check(raised, "off-mesh endpoint in the gap raises")

    # ---- 7. dynamic obstacle carving ----
    var mc = bake_navmesh(sc.verts, sc.tris, cfg)
    var total_tiles = len(mc.tile_rects)
    var ob = mc.add_obstacle(_v(9.5, -0.5, 15.5), _v(10.5, 2.0, 20.5))  # plug the gap
    var rebuilt = mc.update()
    s.check(rebuilt > 0 and rebuilt < total_tiles, "carve rebuilds only nearby tiles")
    s.check(not pf.find(mc, a, b).found, "plugged gap: no path")
    var ref1 = bake_navmesh(sc.verts, sc.tris, cfg)
    _ = ref1.add_obstacle(_v(9.5, -0.5, 15.5), _v(10.5, 2.0, 20.5))
    ref1.rebuild_all()
    s.check(_same_polys(mc, ref1), "incremental carve == full rebuild")
    mc.remove_obstacle(ob)
    _ = mc.update()
    s.check(_same_polys(mc, mesh), "removing the obstacle restores the bake")
    var pr2 = pf.find(mc, a, b)
    s.check(pr2.found and abs(pr2.length() - p.length()) < 1e-4, "path restored after removal")
    s.eqi(mc.update(), 0, "update with nothing pending is a no-op")
    raised = False
    try:
        mc.remove_obstacle(ob)
    except:
        raised = True
    s.check(raised, "removing twice raises")

    # ---- 8. extremes ----
    s.check(not pf.find(mesh, _v(-5, 0, -5), b).found, "start off the mesh: not found")
    var same = pf.find(mesh, a, a)
    s.check(same.found and same.length() < 1e-5, "start == goal")
    var hole = Scene()
    hole.quad(0, 0, 10, 4, 0)
    hole.quad(0, 6, 10, 10, 0)
    hole.quad(0, 4, 4, 6, 0)
    hole.quad(6, 4, 10, 6, 0)  # 2 x 2 hole in the middle
    var mh = bake_navmesh(hole.verts, hole.tris, cfg)
    s.check(mh.find_poly(_v(5, 0, 5)) < 0, "hole is not walkable")
    var ph = pf.find(mh, _v(1, 0, 5), _v(9, 0, 5))
    s.check(ph.found and _valid(mh, ph) and ph.length() > 8.0, "path goes around the hole")
    raised = False
    try:
        var bad = cfg
        bad.cell_size = 0
        _ = bake_navmesh(sc.verts, sc.tris, bad)
    except:
        raised = True
    s.check(raised, "cell_size 0 raises")
    raised = False
    try:
        _ = bake_navmesh(List[Vec3](), List[Int](), cfg)
    except:
        raised = True
    s.check(raised, "empty input raises")
    raised = False
    try:
        var t = sc.tris.copy()
        t.append(0)
        _ = bake_navmesh(sc.verts, t, cfg)
    except:
        raised = True
    s.check(raised, "ragged index list raises")
    s.finish()
