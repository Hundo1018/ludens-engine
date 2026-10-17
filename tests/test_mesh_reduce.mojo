# tier: integration
"""Mesh contact reduction (ROADMAP 17.19, `SolverConfig.reduce_mesh_contacts`).

A box on a fine heightfield gets one manifold per triangle it overlaps;
with reduction on, the coplanar ones of equal material merge into one of
at most 4 points.

  1. 100 boxes (0.8 x 0.6 x 0.8 m) sliding at 2 m/s on a flat heightfield
     of 0.25 m cells for 2 s, off vs on: manifolds per box drop from tens
     to 1; rest height equal within 1 mm; slide distance equal within 2 %
     and within 2 % of v^2 / (2 mu g) = 0.408 m. The heightfield's
     active-edge guard is on (`set_active_angle`): without it a triangle
     overlapping the footprint in a sliver at an edge gets SAT's box-side
     axis as its normal, and those side contacts stop the slide after
     0.099 m (with or without reduction; measured in 17.19).
  2. A box in a V valley (two 30-degree slopes) keeps one manifold per
     slope plus the crease edge's (at most 3, from 22) and rests where it
     rests without reduction (1 mm).
  3. A box straddling a material boundary (left half friction 0.05, right
     1.0) keeps one up-facing manifold per material.
  4. The guard on a trimesh (`set_mesh_active_angle`, computed from shared
     vertex indices): the same 0.25 m grid as a trimesh, without the guard
     the box stops early like on the heightfield, with it slides 0.408 m.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.body_set import BodyId
from collision.trimesh import HeightField

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def flat(mut sc: ContactScene6[QuatBody6]) raises -> BodyId:
    var hs = List[Real]()
    for _ in range(81 * 81):
        hs.append(0)
    var id = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs^, 81, 81, 0.25, -10, -10)
    sc.set_mesh_active_angle(id, 0.1)
    return id


def up_count(sc: ContactScene6[QuatBody6]) -> Int:
    var n = 0
    for ref pr in sc.cache:
        if abs(pr.m.normal[1]) > 0.99:
            n += 1
    return n


def sliding(reduce: Bool) raises -> Tuple[Real, Real, Real, Real]:
    """(manifolds per box at 1 s, up-facing ones per box, mean rest height,
    mean x travelled)."""
    var sc = ContactScene6[QuatBody6]()
    _ = flat(sc)
    var ids = List[BodyId]()
    for i in range(10):
        for j in range(10):
            var b = QuatBody6.at_rest(Vec3(Real(i) * 1.5 - 7, 0.3, Real(j) * 1.5 - 7, 0), Inertia3.box(1, 0.4, 0.3, 0.4))
            b.set_velocity(Vec3(2, 0, 0, 0), Vec3(0, 0, 0, 0))
            ids.append(sc.add(b^, Vec3(0.4, 0.3, 0.4, 0), False))
    var cfg = SolverConfig()
    cfg.broadphase = True
    cfg.reduce_mesh_contacts = reduce
    var per = Real(0)
    var up = Real(0)
    for k in range(120):
        sc.step(DT, G, cfg)
        if k == 59:
            per = Real(len(sc.cache)) / 100
            up = Real(up_count(sc)) / 100
    var y = Real(0)
    var x = Real(0)
    for i in range(100):
        var p = sc.pose(ids[i]).pos
        y += p[1] / 100
        x += (p[0] - (Real(i // 10) * 1.5 - 7)) / 100
    return (per, up, y, x)


def valley(reduce: Bool) raises -> Tuple[Int, Real]:
    """V valley along z: height = |x| tan 30; (manifolds at the end, rest x)."""
    var sc = ContactScene6[QuatBody6]()
    var hs = List[Real]()
    for _ in range(41):
        for i in range(41):
            hs.append(abs(Real(i) * 0.25 - 5) * 0.57735)
    var vid = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs^, 41, 41, 0.25, -5, -5)
    sc.set_mesh_active_angle(vid, 0.1)
    var b = sc.add(QuatBody6.at_rest(Vec3(0.3, 1.2, 0.1, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    var cfg = SolverConfig()
    cfg.reduce_mesh_contacts = reduce
    for _ in range(180):
        sc.step(DT, G, cfg)
    return (len(sc.cache), sc.pose(b).pos[0])


def boundary() raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    var hf = flat(sc)
    var nt = 2 * 80 * 80
    var mats = List[Int]()
    for t in range(nt):
        var tri = sc.colliders.mesh_tri(hf.index(), t)
        var cx = (tri.points[0][0] + tri.points[1][0] + tri.points[2][0]) / 3
        mats.append(0 if cx < 0 else 1)
    sc.set_triangle_materials(hf, mats)
    sc.set_material_friction(0, 0.05)
    sc.set_material_friction(1, 1.0)
    _ = sc.add(QuatBody6.at_rest(Vec3(0.1, 0.3, 0.1, 0), Inertia3.box(1, 0.4, 0.3, 0.4)), Vec3(0.4, 0.3, 0.4, 0), False)
    var cfg = SolverConfig()
    cfg.reduce_mesh_contacts = True
    for _ in range(30):
        sc.step(DT, G, cfg)
    return up_count(sc)


def trimesh_slide(guard: Bool) raises -> Real:
    var f = HeightField(zeros(81 * 81), 81, 81, 0.25, -10, -10)
    var m = f.to_trimesh()
    var vv = List[Real]()
    for i in range(len(m.v)):
        vv.append(m.v[i])
    var ii = List[Int]()
    for i in range(len(m.idx)):
        ii.append(m.idx[i])
    var sc = ContactScene6[QuatBody6]()
    var mid = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), vv^, ii^)
    if guard:
        sc.set_mesh_active_angle(mid, 0.1)
    var b = QuatBody6.at_rest(Vec3(-3, 0.3, 0.13, 0), Inertia3.box(1, 0.4, 0.3, 0.4))
    b.set_velocity(Vec3(2, 0, 0, 0), Vec3(0, 0, 0, 0))
    var id = sc.add(b^, Vec3(0.4, 0.3, 0.4, 0), False)
    var cfg = SolverConfig()
    for _ in range(120):
        sc.step(DT, G, cfg)
    return sc.pose(id).pos[0] + 3


def zeros(n: Int) -> List[Real]:
    var z = List[Real]()
    for _ in range(n):
        z.append(0)
    return z^


def main() raises:
    var s = Suite("mesh_reduce")
    var off = sliding(False)
    var on = sliding(True)
    print("sliding on 0.25 m heightfield: manifolds per box off", off[0], " on", on[0], "  up-facing off", off[1], " on", on[1], "  rest y", off[2], on[2], "  travel", off[3], on[3])
    s.check(off[0] > 8 and on[0] == 1 and on[1] == 1, "tens of triangle manifolds per box become one")
    s.check(abs(off[2] - on[2]) < 0.001 and abs(on[3] / off[3] - 1) < 0.02 and abs(on[3] / 0.408 - 1) < 0.02, "same rest height (1 mm) and slide distance (2 %), = v^2 / (2 mu g)")
    var v0 = valley(False)
    var v1 = valley(True)
    print("V valley: manifolds off", v0[0], " on", v1[0], "  rest x", v0[1], v1[1])
    s.check(v1[0] >= 2 and v1[0] <= 3 and abs(v1[1] - v0[1]) < 0.001, "a box in a V valley keeps one manifold per slope (+ crease) and rests where it did")
    var nb = boundary()
    print("material boundary: up-facing manifolds", nb)
    s.check(nb == 2, "one up-facing manifold per material across a boundary")
    var t0 = trimesh_slide(False)
    var t1 = trimesh_slide(True)
    print("trimesh 0.25 m grid slide: no guard", t0, " guard", t1)
    s.check(t0 < 0.3 and abs(t1 / 0.408 - 1) < 0.02, "trimesh guard from shared vertices: slides v^2 / (2 mu g)")
    s.finish()
