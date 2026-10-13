# tier: integration
"""Kinematic triangle meshes (ROADMAP 17.45).

`add_trimesh` stores world-space vertices; `set_kinematic` on a mesh body
now records them in the body frame, and each step re-places the mesh at
the body's pose before and after it (vertices, BVH, world AABB; active-edge
flags kept), skipping a mesh whose body did not move.

  1. Ordinary: a 4 x 4 m mesh platform (8 x 8 quads) rising at 1 m/s
     carries a box up: after 2 s the box sits on it (gap within 2 cm).
  2. Integration: the platform sliding at 1 m/s along x carries a box by
     friction to within 2 % of its speed; the mesh's active-edge flags are
     the same after 120 re-placements.
  3. Extreme: the same mesh left static does not move with a set velocity
     (only kinematic meshes follow their body); a teleported kinematic
     platform takes its mesh along.
  4. Regression (collision.hull): a box resting across two cells of the
     8 x 8 grid at nine offsets x = -0.2 .. 0.2 stays put. Before the
     `hull_manifold` fix, contacts whose SAT axis came from the triangle
     got one depth for every point, so the box could not see its own tilt:
     at x = -0.05 it tipped off the left cells after ~70 steps and wandered
     (x -0.05 -> -0.07, y 1.2476 after 2 s).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.mesh_bake import active_edges
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


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


def _scene(kinematic: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var g = _quad_grid(8, 4)
    var act = active_edges(g[0], g[1], 0.0872664626)
    var pid = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 1, 1, 1)), g[0], g[1], act, True)
    if kinematic:
        sc.set_kinematic(pid)
    var box = sc.add(QuatBody6.at_rest(Vec3(0, 1.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_sleep_thresholds(box, 0, 0)
    return sc^


def main() raises:
    var s = Suite("kinematic_mesh")

    var up = _scene(True)
    var pid = up.bset.id_of(0)
    var bid = up.bset.id_of(1)
    for _ in range(30):
        up.step_soft(DT, G)
    up.set_velocity(pid, Vec3(0, 1, 0, 0), Vec3(0, 0, 0, 0))
    var act0 = up.colliders.meshes[0].active.copy()
    for _ in range(120):
        up.step_soft(DT, G)
    var py = up.pose(pid).pos[1]
    var by = up.pose(bid).pos[1]
    var mesh_y = up.colliders.meshes[0].v[1]
    print("  rising platform after 2 s: body y", py, " mesh vertex y", mesh_y, " box y", by, " gap", by - 0.25 - py)
    s.check(abs(mesh_y - py) < 1e-4 and abs(by - 0.25 - py) < 0.02, "the box rides the rising mesh (gap within 2 cm); the mesh is where its body is")
    s.check(up.colliders.meshes[0].active == act0, "active-edge flags kept through 120 re-placements")

    var slide = _scene(True)
    for _ in range(30):
        slide.step_soft(DT, G)
    slide.set_velocity(slide.bset.id_of(0), Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0))
    for _ in range(90):
        slide.step_soft(DT, G)
    var vx = slide.velocity(slide.bset.id_of(1))[0]
    print("  platform sliding at 1 m/s: box vx after 1.5 s", vx, " box x", slide.pose(slide.bset.id_of(1)).pos[0])
    s.check(abs(vx - 1) < 0.02, "friction carries the box at the platform's speed")

    var st = _scene(False)
    for _ in range(30):
        st.step_soft(DT, G)
    var v0 = st.colliders.meshes[0].v[0]
    for _ in range(30):
        st.step_soft(DT, G)
    s.check(st.colliders.meshes[0].v[0] == v0 and abs(st.pose(st.bset.id_of(1)).pos[1] - 1.25) < 0.02, "a static mesh stays put")

    var tp = _scene(True)
    tp.teleport(tp.bset.id_of(0), Pose6(Vec3(10, 1, 0, 0), Quat(0, 0, 0, 1)))
    tp.step_soft(DT, G)
    var vxm = tp.colliders.meshes[0].v[0]
    print("  teleported platform: first mesh vertex x", vxm, "(body at x = 10, vertex local x = -2)")
    s.check(abs(vxm - 8) < 1e-4, "a teleported kinematic platform takes its mesh along")

    var worst = Real(0)
    for k in range(9):
        var x0 = Real(-0.2) + Real(0.05) * Real(k)
        var r = ContactScene6[QuatBody6]()
        var g = _quad_grid(8, 4)
        var act = active_edges(g[0], g[1], 0.0872664626)
        _ = r.add_trimesh(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 1, 1, 1)), g[0], g[1], act, True)
        var b = r.add(QuatBody6.at_rest(Vec3(x0, 1.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        r.set_sleep_thresholds(b, 0, 0)
        for _ in range(120):
            r.step_soft(DT, G)
        var p = r.pose(b).pos
        worst = max(worst, max(abs(p[0] - x0), abs(p[1] - 1.25)))
    print("  box resting across two cells at 9 offsets, 2 s: worst drift", worst)
    s.check(worst < 1e-3, "a box resting across mesh cells stays put at every offset")
    s.finish()
