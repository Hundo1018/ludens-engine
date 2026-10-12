# tier: integration
"""Navmesh vs the physics ground (ROADMAP 17.14 integration case).

The same triangle soup goes to `bake_navmesh` and, as a static trimesh, to a
`ContactScene6`. Every path point and every 0.25 m sample along the walking
segments of a path over floor -> ramp -> platform is cast straight down with
`ContactScene6.ray_cast`; the physics ground under it must be within two
voxel heights of the navmesh polygon height there. A box dropped at a path
corner comes to rest on the surface the navmesh reports. Random carving
sequences match a from-scratch rebuild after every step.
"""

from harness.runner import Suite
from std.math import ceil
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64, Rng
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh, dist3
from nav.path import NavPath, PolyFunnel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime DOWN = Vec3(0, -1, 0, 0)
comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)


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

    def slope(mut self, x0: Real, z0: Real, x1: Real, z1: Real, y0: Real, y1: Real):
        self._tri(_v(x0, y0, z0), _v(x0, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y1, z0), _v(x0, y0, z1), _v(x1, y1, z1))

    def flat(self) -> List[Real]:
        var f = List[Real]()
        for v in self.verts:
            f.append(v[0])
            f.append(v[1])
            f.append(v[2])
        return f^


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


def main() raises:
    var s = Suite("nav_world")
    var cfg = NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)
    var sc = Scene()
    sc.slope(0, 0, 10, 10, 0, 0)
    sc.slope(10, 0, 20, 10, 0, 2.5)  # 14 deg ramp
    sc.slope(20, 0, 30, 10, 2.5, 2.5)
    var mesh = bake_navmesh(sc.verts, sc.tris, cfg)

    var world = ContactScene6[QuatBody6]()
    _ = world.add_trimesh(QuatBody6.at_rest(_v(0, 0, 0), Inertia3.box(1, 30, 1, 10)), sc.flat(), sc.tris.copy())

    var pf = PolyFunnel()
    var p = pf.find(mesh, _v(2, 0, 2), _v(28, 2.5, 8))
    s.check(p.found, "path floor -> ramp -> platform")
    var samples = 0
    var agree = 0
    var worst = Real(0)
    for i in range(len(p.points)):
        var a = p.points[i]
        var b = p.points[min(i + 1, len(p.points) - 1)]
        var n = max(1, Int(ceil(dist3(a, b) / 0.25)))
        for k in range(n):
            var q = a + (b - a) * (Real(k) / Real(n))
            var poly = mesh.find_poly(q)
            if poly < 0:
                continue
            var y_nav = mesh.height_at(poly, q)
            var h = world.ray_cast(_v(q[0], y_nav + 3, q[2]), DOWN, 10, ALL)
            samples += 1
            if h.hit:
                var dy = abs(h.point[1] - y_nav)
                worst = max(worst, dy)
                if dy <= 2 * cfg.cell_height:
                    agree += 1
    s.check(samples > 100, "sampled the whole route")
    s.eqi(agree, samples, "navmesh height within 2 voxels of the physics ground")
    print("  nav_world: samples", samples, "worst |dy|", worst)

    # a box dropped at a mid-ramp path sample rests on the navmesh height
    var mid = _v(15, 0, 5)
    var y_mid = mesh.height_at(mesh.find_poly(_v(15, 1.25, 5)), mid)
    var bid = world.add(QuatBody6.at_rest(_v(15, y_mid + 1, 5), Inertia3.box(1, 0.2, 0.2, 0.2)), _v(0.2, 0.2, 0.2), False)
    for _ in range(240):
        world.step_soft(DT, G)
    var rest = world.bset.bodies[bid.index()].position()
    s.check(rest[0] > 13.5 and rest[0] < 15.5, "box stays near the drop point")
    var y_under = mesh.height_at(mesh.find_poly(_v(rest[0], rest[1], rest[2])), rest)
    s.almost(Float64(rest[1] - 0.2), Float64(y_under), "box rests on the navmesh surface", tol=0.25)

    # random carve sequences == from-scratch rebuild after every step
    var flat = Scene()
    flat.slope(0, 0, 24, 24, 0, 0)
    var mc = bake_navmesh(flat.verts, flat.tris, cfg)
    var ids = List[Int]()
    var rng = SplitMix64.seeded(1714)
    var ok = 0
    var steps = 12
    for step in range(steps):
        if step % 3 == 2 and len(ids) > 0:
            mc.remove_obstacle(ids[0])
            _ = ids.pop(0)
        else:
            var x = rng.next_f32() * 22
            var z = rng.next_f32() * 22
            var w = 0.3 + rng.next_f32() * 2
            ids.append(mc.add_obstacle(_v(x, -0.5, z), _v(x + w, 1.5, z + w)))
        _ = mc.update()
        var rf = bake_navmesh(flat.verts, flat.tris, cfg)
        for o in range(len(mc.ob_min)):
            var id = rf.add_obstacle(mc.ob_min[o], mc.ob_max[o])
            if not mc.ob_alive[o]:
                rf.remove_obstacle(id)
        rf.rebuild_all()
        if _same_polys(mc, rf):
            ok += 1
    s.eqi(ok, steps, "incremental carve == rebuild after each of 12 random edits")
    s.finish()
