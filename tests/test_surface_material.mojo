# tier: integration
"""Surface materials on mesh triangles (ROADMAP 17.53) and the snapshot of
kinematic meshes (17.45).

  1. Ordinary: one road mesh, asphalt (id 0) for x < 100 and ice (id 1)
     beyond; rays report the id of the triangle they hit, a box body -1, a
     heightfield its own ids.
  2. Integration: a car braking from 15 m/s on the asphalt part stops in
     the same distance as on a box road of body friction 0.5, and on the ice
     part (material friction 0.05) in the same distance as on a box road of
     friction 0.05 -- the material friction stands in for the body's. Each
     wheel reports the material under it. A scene with a moving kinematic
     platform mesh and materials, saved and restored mid-run, continues bit
     for bit like the uninterrupted one (format 5).
  3. Extreme: wrong id count, an id above 65535 and materials on a box
     raise; a material with no friction set falls back to the body's; a
     negative material friction raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.mesh_bake import active_edges
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_bytes, scene_from_bytes
from collision.world_query import QueryFilter
from gameplay.vehicle import Vehicle, VehicleConfig, VehicleInput, spawn_chassis
from gameplay.vehicle_wheel import RayWheel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime REST_Y: Real = 0.72
comptime ASPHALT = 0
comptime ICE = 1


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _strip(xs: List[Real], z0: Real, z1: Real) -> Tuple[List[Real], List[Int]]:
    """Quads along x between consecutive `xs`, two up-facing triangles each
    (triangles 2k and 2k + 1 belong to quad k)."""
    var v = List[Real]()
    var ix = List[Int]()
    for x in xs:
        v.append(x); v.append(0); v.append(z0)
        v.append(x); v.append(0); v.append(z1)
    for k in range(len(xs) - 1):
        var a = 2 * k  # (x_k, z0)
        var c = a + 1  # (x_k, z1)
        var b = a + 2  # (x_k+1, z0)
        var d = a + 3  # (x_k+1, z1)
        ix.append(a); ix.append(c); ix.append(b)
        ix.append(b); ix.append(c); ix.append(d)
    return (v^, ix^)


def _mesh_road() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var g = _strip([Real(-50), 100, 400], -20, 20)
    var road = sc.add_trimesh(_st(ZERO), g[0], g[1])
    sc.set_friction(road.index(), 0.5)
    sc.set_triangle_materials(road, [ASPHALT, ASPHALT, ICE, ICE])
    sc.set_material_friction(ASPHALT, 0.5)
    sc.set_material_friction(ICE, 0.05)
    return sc^


def _box_road(mu: Real) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(_st(Vec3(0, -1, 0, 0)), Vec3(3000, 1, 3000, 0), True)
    sc.set_friction(f.index(), mu)
    return sc^


def _brake(mut sc: ContactScene6[QuatBody6], x0: Real) raises -> Tuple[Real, Int]:
    """(stopping distance from 15 m/s, material under wheel 0 while braking)."""
    var cfg = VehicleConfig()
    var id = spawn_chassis(sc, cfg, Vec3(x0, REST_Y, 0, 0), Quat.identity())
    var v = Vehicle[RayWheel].attach(sc, id, cfg.copy(), RayWheel())
    for _ in range(120):
        v.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
    sc.set_velocity(v.chassis, Vec3(15, 0, 0, 0), ZERO)
    v.sync_wheels(15)
    var start = sc.bset.bodies[v.chassis.index()].pos[0]
    var mat = -2
    for _ in range(1800):
        v.update(sc, VehicleInput(0, 1, 0, 0), DT)
        sc.step_soft(DT, G)
        mat = v.wheels[0].material
        if v.forward_speed(sc) < 0.1:
            break
    return (sc.bset.bodies[v.chassis.index()].pos[0] - start, mat)


def _quad_grid(n: Int, size: Real) -> Tuple[List[Real], List[Int]]:
    var v = List[Real]()
    var ix = List[Int]()
    for j in range(n + 1):
        for i in range(n + 1):
            v.append(-size / 2 + size * Real(i) / Real(n))
            v.append(0)
            v.append(-size / 2 + size * Real(j) / Real(n))
    for j in range(n):
        for i in range(n):
            var a = j * (n + 1) + i
            var b = a + 1
            var c = a + n + 1
            var d = c + 1
            ix.append(a); ix.append(c); ix.append(b)
            ix.append(b); ix.append(c); ix.append(d)
    return (v^, ix^)


def _platform_scene() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var g = _quad_grid(4, 4)
    var act = active_edges(g[0], g[1], 0.0872664626)
    var pid = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 1, 1, 1)), g[0], g[1], act, True)
    sc.set_kinematic(pid)
    var ids = List[Int]()
    for t in range(32):
        ids.append(t % 3)
    sc.set_triangle_materials(pid, ids)
    sc.set_material_friction(2, 0.9)
    var box = sc.add(QuatBody6.at_rest(Vec3(0.3, 1.25, 0.1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_sleep_thresholds(box, 0, 0)
    return sc^


def main() raises:
    var s = Suite("surface_material")
    var ALL = QueryFilter(0xFFFFFFFF, -1, False)

    # ---- hits report materials ----------------------------------------------------------------------
    var sc = _mesh_road()
    var box = sc.add(_st(Vec3(0, 0.5, 15, 0)), Vec3(0.5, 0.5, 0.5, 0), True)
    var h_asph = sc.ray_cast(Vec3(50, 5, 0, 0), Vec3(0, -1, 0, 0), 10, ALL)
    var h_ice = sc.ray_cast(Vec3(200, 5, 0, 0), Vec3(0, -1, 0, 0), 10, ALL)
    var h_box = sc.ray_cast(Vec3(0, 5, 15, 0), Vec3(0, -1, 0, 0), 10, ALL)
    print("  ray hits: x 50 -> material", sc.hit_material(h_asph), " x 200 ->", sc.hit_material(h_ice), " box ->", sc.hit_material(h_box))
    s.check(sc.hit_material(h_asph) == ASPHALT and sc.hit_material(h_ice) == ICE and h_box.body == box.index() and sc.hit_material(h_box) == -1, "rays report the hit triangle's material; a box has none")

    var hs = ContactScene6[QuatBody6]()
    var hg = List[Real](length=9, fill=0)
    var hf = hs.add_heightfield(_st(ZERO), hg, 3, 3, 1.0)
    hs.set_triangle_materials(hf, [5, 5, 6, 6, 7, 7, 8, 8])
    var hh = hs.ray_cast(Vec3(1.5, 2, 1.5, 0), Vec3(0, -1, 0, 0), 5, ALL)
    print("  heightfield: ray at cell (1, 1) -> triangle", hh.feat, " material", hs.hit_material(hh))
    s.check(hs.hit_material(hh) == 8 and hh.feat // 2 == 3, "heightfield triangles report their material (cell 3 -> 8)")

    # ---- vehicle grip from the triangle's material ----------------------------------------------------
    var m_asph = _mesh_road()
    var ra = _brake(m_asph, 0)
    var b_asph = _box_road(0.5)
    var rb = _brake(b_asph, 0)
    var m_ice = _mesh_road()
    var ri = _brake(m_ice, 150)
    var b_ice = _box_road(0.05)
    var rbi = _brake(b_ice, 0)
    print("  braking from 15 m/s: mesh asphalt", ra[0], "m (wheel material", ra[1], ") vs box road mu 0.5", rb[0], "m")
    print("                       mesh ice    ", ri[0], "m (wheel material", ri[1], ") vs box road mu 0.05", rbi[0], "m")
    s.check(abs(ra[0] / rb[0] - 1) < 0.01 and ra[1] == ASPHALT, "asphalt triangles: same stop as a 0.5 body-friction road")
    s.check(abs(ri[0] / rbi[0] - 1) < 0.01 and ri[1] == ICE and ri[0] > 5 * ra[0], "ice triangles: same stop as a 0.05 road, over 5x the asphalt distance")

    # ---- snapshot: kinematic mesh + materials -----------------------------------------------------------
    var run = _platform_scene()
    for _ in range(20):
        run.step_soft(DT, G)
    run.set_velocity(run.bset.id_of(0), Vec3(0.7, 0.3, 0, 0), Vec3(0, 0.4, 0, 0))
    for _ in range(20):
        run.step_soft(DT, G)
    var back = scene_from_bytes(scene_to_bytes(run))
    for _ in range(40):
        run.step_soft(DT, G)
        back.step_soft(DT, G)
    var same = run.colliders.meshes[0].v == back.colliders.meshes[0].v
    for b in range(len(run.bset.bodies)):
        var p = run.bset.bodies[b].pos
        var q = back.bset.bodies[b].pos
        if p[0] != q[0] or p[1] != q[1] or p[2] != q[2]:
            same = False
    var mats = back.colliders.material(0, 5) == 2 and back.colliders.material(0, 7) == 1 and back.surface_friction(0, 2, 0.5) == 0.9
    print("  restored mid-run: mesh vertex 0 x", back.colliders.meshes[0].v[0], " (uninterrupted", run.colliders.meshes[0].v[0], ")  box y", back.bset.bodies[1].pos[1], " same bits", same)
    s.check(same and run.colliders.meshes[0].v[0] != -2, "a restored kinematic platform keeps moving its mesh, bit for bit")
    s.check(mats, "materials and the friction table survive the snapshot")

    # ---- extremes -----------------------------------------------------------------------------------------
    var ex = _mesh_road()
    var raised = 0
    try:
        ex.set_triangle_materials(ex.bset.id_of(0), [0, 1])
    except:
        raised += 1
    try:
        ex.set_triangle_materials(ex.bset.id_of(0), [0, 0, 70000, 0])
    except:
        raised += 1
    var bx = ex.add(_st(Vec3(0, 3, 0, 0)), Vec3(0.5, 0.5, 0.5, 0), True)
    try:
        ex.set_triangle_materials(bx, [0])
    except:
        raised += 1
    try:
        ex.set_material_friction(3, -1)
    except:
        raised += 1
    s.check(raised == 4, "wrong count, id > 65535, a box body and negative friction raise")
    ex.set_triangle_materials(ex.bset.id_of(0), [0, 0, 9, 9])
    s.check(ex.surface_friction(0, 9, 0.5) == 0.5 and ex.surface_friction(0, ICE, 0.5) == 0.05, "a material without friction falls back to the body's")
    s.finish()
