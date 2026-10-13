# tier: integration
"""Spheres and capsules on triangle meshes, analytically (ROADMAP 17.45).

Before: `try_mesh_pair` gave a sphere or capsule to the hull narrowphase as a
box (`ColliderSet.as_hull`), so a ball on a 20-degree mesh slope (mu = 0.8)
did not move at all: speed after 1 s -0.0006 m/s where rolling gives
5/7 g sin(20 deg) t = 2.394. Now `sphere_triangle_manifold` /
`capsule_triangle_manifold` meet each triangle exactly.

  1. Ordinary: the ball rolls down the 80-triangle slope (baked active
     edges) at 5/7 g sin(theta) within 0.1 % (2.3941434 vs 2.3941412; without
     the flags the seams cost 1.5 %) and stays on the surface; a ball resting on a triangle's
     middle sits at height r (the parity point with the old box path, which
     also rests at r there).
  2. Integration: a capsule laid flat on a 400-quad floor rests at height r
     with its axis horizontal; a ball rolling across that floor (baked
     active edges) keeps its speed. Without the flags it does not: the
     neighbour ahead touches it at the shared edge with a forward-down
     normal and the speculative contact brakes it (control check).
  3. Extreme: a ball centred exactly over a shared vertex rests at r; a ball
     behind a single-sided triangle is not pushed through it.
"""

from std.math import sin, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.mesh_bake import active_edges
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _strip(n: Int, length: Real, dirx: Vec3) -> Tuple[List[Real], List[Int]]:
    """n x 2 quads along `dirx` (through the origin), z in [-3, 3], normal
    = cross(z, dirx) side up (CCW seen from above for dirx = +x)."""
    var v = List[Real]()
    var ix = List[Int]()
    for j in range(3):
        for i in range(n + 1):
            var s = -length / 2 + length * Real(i) / Real(n)
            v.append(dirx[0] * s)
            v.append(dirx[1] * s)
            v.append(-3 + 3 * Real(j))
    for j in range(2):
        for i in range(n):
            var a = j * (n + 1) + i
            var b = a + 1
            var c = a + n + 1
            var d = c + 1
            ix.append(a); ix.append(c); ix.append(b)
            ix.append(b); ix.append(c); ix.append(d)
    return (v^, ix^)


def _mesh_body() -> QuatBody6:
    return QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1))


def main() raises:
    var s = Suite("mesh_round")

    # ---- 1. rolling down a slope -----------------------------------------
    var th = Real(20) * pi / 180
    var down = Vec3(cos(th), -sin(th), 0, 0)
    var nrm = Vec3(sin(th), cos(th), 0, 0)
    var slope = _strip(40, 30, down)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_mesh_body(), slope[0], slope[1], active_edges(slope[0], slope[1], 0.0872664626))
    var p0 = down * Real(-5) + nrm * Real(0.5)
    var id = sc.add_sphere(QuatBody6.at_rest(p0, Inertia3.sphere(1, 0.5)), 0.5, False)
    sc.set_can_sleep(id, False)
    for _ in range(60):
        sc.step_soft(DT, G, mu=0.8)
    var vel = sc.bset.bodies[1].vel
    var along = vel[0] * down[0] + vel[1] * down[1]
    var want = Real(5.0 / 7.0) * Real(9.8) * sin(th)
    var dp = sc.bset.bodies[1].pos - p0
    var off = dp[0] * nrm[0] + dp[1] * nrm[1]
    print("  slope: speed after 1 s", along, " analytic", want, " normal offset", off)
    s.check(abs(along - want) < 1e-3 * want, "ball rolls down the mesh slope at 5/7 g sin(theta) (0.1 %)")
    s.check(abs(off) < 2e-3, "ball stays on the slope surface")

    # ---- parity: resting on a triangle's middle --------------------------
    var flat = _strip(1, 10, Vec3(1, 0, 0, 0))
    var rest = ContactScene6[QuatBody6]()
    _ = rest.add_trimesh(_mesh_body(), flat[0], flat[1])
    _ = rest.add_sphere(QuatBody6.at_rest(Vec3(1.5, 0.6, -1.5, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    for _ in range(120):
        rest.step_soft(DT, G)
    print("  ball on a triangle's middle: y", rest.bset.bodies[1].pos[1])
    s.check(abs(rest.bset.bodies[1].pos[1] - 0.5) < 2e-3, "ball rests at height r on a face")

    # ---- 2. capsule lying flat; ball across a fine floor -----------------
    var fine = _strip(400, 40, Vec3(1, 0, 0, 0))
    var cs = ContactScene6[QuatBody6]()
    _ = cs.add_trimesh(_mesh_body(), fine[0], fine[1])
    var cap = QuatBody6.at_rest(Vec3(0, 0.35, 0, 0), Inertia3.capsule(1, 0.3, 0.6))
    cap.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 2)  # axis along x
    var cid = cs.add_capsule(cap^, 0.3, 0.6, False)
    cs.set_can_sleep(cid, False)
    for _ in range(120):
        cs.step_soft(DT, G)
    var ax = cs.bset.bodies[1].q.rotate(Vec3(0, 1, 0, 0))
    print("  capsule on 400-quad floor: y", cs.bset.bodies[1].pos[1], " axis y-component", ax[1])
    s.check(abs(cs.bset.bodies[1].pos[1] - 0.3) < 2e-3, "flat capsule rests at height r")
    s.check(abs(ax[1]) < 1e-2, "flat capsule stays horizontal (two contact points)")

    var bs = ContactScene6[QuatBody6]()
    _ = bs.add_trimesh(_mesh_body(), fine[0], fine[1], active_edges(fine[0], fine[1], 0.0872664626))
    var ball = QuatBody6.at_rest(Vec3(-10, 0.5, 0.1, 0), Inertia3.sphere(1, 0.5))
    ball.vel = Vec3(3, 0, 0, 0)
    ball.omega = Vec3(0, 0, -6, 0)  # already rolling: v = omega r
    var bid = bs.add_sphere(ball^, 0.5, False)
    bs.set_can_sleep(bid, False)
    var maxvy = Real(0)
    for _ in range(90):
        bs.step_soft(DT, G)
        maxvy = max(maxvy, abs(bs.bset.bodies[1].vel[1]))
    print("  ball rolling across 400 quads: vx", bs.bset.bodies[1].vel[0], " max|vy|", maxvy)
    s.check(abs(bs.bset.bodies[1].vel[0] - 3) < 1e-2, "rolling ball keeps its speed across the seams")
    s.check(maxvy < 1e-2, "no seam kick")
    var ctl = ContactScene6[QuatBody6]()
    _ = ctl.add_trimesh(_mesh_body(), fine[0], fine[1])
    var ball2 = QuatBody6.at_rest(Vec3(-10, 0.5, 0.1, 0), Inertia3.sphere(1, 0.5))
    ball2.vel = Vec3(3, 0, 0, 0)
    ball2.omega = Vec3(0, 0, -6, 0)
    var cid2 = ctl.add_sphere(ball2^, 0.5, False)
    ctl.set_can_sleep(cid2, False)
    for _ in range(90):
        ctl.step_soft(DT, G)
    print("  control, no flags: vx", ctl.bset.bodies[1].vel[0])
    s.check(ctl.bset.bodies[1].vel[0] < 2.9, "control: without active edges the seams brake the ball")

    # ---- 3. extremes ---------------------------------------------------
    var vtx = ContactScene6[QuatBody6]()
    var g4 = _strip(4, 4, Vec3(1, 0, 0, 0))
    _ = vtx.add_trimesh(_mesh_body(), g4[0], g4[1])
    _ = vtx.add_sphere(QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    for _ in range(120):
        vtx.step_soft(DT, G)
    s.check(abs(vtx.bset.bodies[1].pos[1] - 0.5) < 2e-3, "ball over a shared vertex rests at r")

    var back = ContactScene6[QuatBody6]()
    _ = back.add_trimesh(_mesh_body(), flat[0], flat[1])
    var under = QuatBody6.at_rest(Vec3(1.5, -0.3, -1.5, 0), Inertia3.sphere(1, 0.5))
    under.vel = Vec3(0, 1, 0, 0)
    _ = back.add_sphere(under^, 0.5, False)
    back.step_soft(DT, Vec3(0, 0, 0, 0))
    s.check(back.bset.bodies[1].vel[1] > 0.99, "ball behind the single-sided face passes up untouched")

    # ---- instancing: one local-space mesh at two poses (17.45) ---------
    var inst = ContactScene6[QuatBody6]()
    var tile = _strip(2, 4, Vec3(1, 0, 0, 0))  # local frame, centred on the origin
    var pose_b = QuatBody6.at_rest(Vec3(20, 1, 0, 0), Inertia3.box(1, 1, 1, 1))
    pose_b.q = Quat.from_axis_angle(Vec3(0, 1, 0, 0), pi / 2)
    _ = inst.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), tile[0], tile[1], local=True)
    _ = inst.add_trimesh(pose_b^, tile[0], tile[1], local=True)
    _ = inst.add_sphere(QuatBody6.at_rest(Vec3(0.3, 0.6, 0.4, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    _ = inst.add_sphere(QuatBody6.at_rest(Vec3(20.4, 1.6, 0.3, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    for _ in range(120):
        inst.step_soft(DT, G)
    print("  instanced tiles: ball heights", inst.bset.bodies[2].pos[1], inst.bset.bodies[3].pos[1])
    s.check(abs(inst.bset.bodies[2].pos[1] - 0.5) < 2e-3, "instance at the origin: ball rests at r")
    s.check(abs(inst.bset.bodies[3].pos[1] - 1.5) < 2e-3, "instance moved to (20, 1, 0) and turned 90 deg: ball rests at 1 + r")
    s.finish()
