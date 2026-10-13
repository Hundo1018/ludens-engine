# tier: integration
"""SDF as a solver shape (ROADMAP 17.52): `ContactScene6.add_sdf`.

The ground is a `SdfGrid` holding the plane y = 0 (values = y, exact under
trilinear interpolation) or a bowl.

  1. Ordinary: a sphere (r 0.5) rests at y = 0.5 and a box (half 0.25) at
     y = 0.25, flat, on a four-point manifold.
  2. Integration: the box's contact count and rest height are the same on a
     13^3 and a 49^3 grid (the patch comes from the box, not the cells);
     20 boxes dropped into a bowl come to rest above its surface; a ray down
     onto the ground hits at the height; a snapshot round trip is bit-identical.
  3. Extreme: a sphere falling at 8 m/s does not tunnel; a capsule lying on
     the ground rests at y = r.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.sdf_grid import SdfGrid
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from collision.world_query import QueryFilter
from std.math import pi

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)


def _plane(res: Int) -> SdfGrid:
    var g = SdfGrid(res, Vec3(-6, -6, -6, 0), Real(12) / Real(res - 1))
    for k in range(res):
        for j in range(res):
            for i in range(res):
                g.values[(k * res + j) * res + i] = g.node(i, j, k)[1]
    return g^


def _bowl(res: Int) -> SdfGrid:
    var g = SdfGrid(res, Vec3(-6, -3, -6, 0), Real(12) / Real(res - 1))
    for k in range(res):
        for j in range(res):
            for i in range(res):
                var p = g.node(i, j, k)
                g.values[(k * res + j) * res + i] = (p[1] - Real(0.08) * (p[0] * p[0] + p[2] * p[2])) / Real(1.2)
    return g^


def _st() -> QuatBody6:
    return QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1))


def _box_on(res: Int) raises -> Tuple[Real, Int, Real]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_sdf(_st(), _plane(res))
    var b = sc.add(QuatBody6.at_rest(Vec3(0.13, 0.3, -0.21, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_can_sleep(b, False)
    for _ in range(120):
        sc.step_soft(DT, G)
    var ax = sc.pose(b).rot.rotate(Vec3(0, 1, 0, 0))
    return (sc.pose(b).pos[1], sc.cache[0].m.count if len(sc.cache) > 0 else 0, ax[1])


def main() raises:
    var s = Suite("sdf_shape")

    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_sdf(_st(), _plane(25))
    var ball = sc.add_sphere(QuatBody6.at_rest(Vec3(0.3, 1.0, 0.1, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    sc.set_can_sleep(ball, False)
    for _ in range(120):
        sc.step_soft(DT, G)
    print("  sphere on the SDF plane: y", sc.pose(ball).pos[1])
    s.check(abs(sc.pose(ball).pos[1] - 0.5) < 2e-3, "sphere rests at y = r on the SDF plane")

    var coarse = _box_on(13)
    var fine = _box_on(49)
    print("  box on 13^3 grid: y", coarse[0], " contacts", coarse[1], " | 49^3: y", fine[0], " contacts", fine[1])
    s.check(abs(coarse[0] - 0.25) < 2e-3 and coarse[2] > 0.9999, "box rests flat at y = half")
    s.check(coarse[1] == 4 and fine[1] == 4, "four-point manifold on both grids")
    s.check(abs(coarse[0] - fine[0]) < 1e-4, "rest height independent of the grid resolution")
    var ref_sc = ContactScene6[QuatBody6]()
    _ = ref_sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    var rb = ref_sc.add(QuatBody6.at_rest(Vec3(0.13, 0.3, -0.21, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    ref_sc.set_can_sleep(rb, False)
    for _ in range(120):
        ref_sc.step_soft(DT, G)
    print("  same box on an analytic box floor: y", ref_sc.pose(rb).pos[1])
    s.check(abs(coarse[0] - ref_sc.pose(rb).pos[1]) < 1e-4, "parity: SDF plane vs box floor rest height (1e-4)")

    var bw = ContactScene6[QuatBody6]()
    var bowl_id = bw.add_sdf(_st(), _bowl(41))
    var ids = List[Int]()
    for k in range(20):
        var x = Real(k % 5) * 0.9 - 1.8
        var z = Real(k // 5) * 0.9 - 1.35
        var id = bw.add(QuatBody6.at_rest(Vec3(x, 1.5 + 0.3 * Real(k % 3), z, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        ids.append(id.index())
    for _ in range(300):
        bw.step_soft(DT, G)
    var vmax = Real(0)
    var lowest = Real(1e9)
    for k in range(len(ids)):
        var v = bw.bset.bodies[ids[k]].vel
        vmax = max(vmax, abs(v[0]) + abs(v[1]) + abs(v[2]))
        lowest = min(lowest, bw.closest_point(bowl_id.index(), bw.bset.bodies[ids[k]].pos).dist)
    print("  20 boxes in an SDF bowl after 5 s: max speed", vmax, " lowest centre above the surface", lowest)
    s.check(vmax < 0.05, "20 boxes come to rest in the bowl")
    s.check(lowest > 0.1, "none sinks into the bowl (centres stay above the surface)")

    var h = sc.ray_cast(Vec3(2, 5, 1, 0), Vec3(0, -1, 0, 0), 20, ALL)
    print("  ray down onto the SDF plane from y = 5: t", h.t)
    s.check(h.hit and abs(h.t - 5) < 1e-3, "ray hits the SDF plane at its height")

    var blob = scene_to_string(sc)
    var rs = scene_from_string(blob)
    s.check(scene_to_string(rs) == blob, "snapshot with an SDF: re-serialised blob identical")
    for _ in range(30):
        sc.step_soft(DT, G)
        rs.step_soft(DT, G)
    s.check(sc.bset.bodies[ball.index()].pos[1] == rs.bset.bodies[ball.index()].pos[1], "restored SDF scene steps bit-identically")

    var sf = ContactScene6[QuatBody6]()
    _ = sf.add_sdf(_st(), _plane(25))
    var fast = QuatBody6.at_rest(Vec3(0, 1.2, 0, 0), Inertia3.sphere(1, 0.3))
    fast.vel = Vec3(0, -8, 0, 0)
    var fid = sf.add_sphere(fast^, 0.3, False)
    var cap = QuatBody6.at_rest(Vec3(3, 0.5, 0, 0), Inertia3.capsule(1, 0.3, 0.6))
    cap.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 2)
    var cid = sf.add_capsule(cap^, 0.3, 0.6, False)
    sf.set_can_sleep(cid, False)
    var low = Real(1e9)
    for _ in range(120):
        sf.step_soft(DT, G)
        low = min(low, sf.pose(fid).pos[1])
    print("  8 m/s sphere: lowest y", low, " capsule lying: y", sf.pose(cid).pos[1])
    s.check(low > 0.1, "fast sphere does not tunnel through the SDF")
    s.check(abs(sf.pose(cid).pos[1] - 0.3) < 2e-3, "capsule lying on the SDF rests at y = r")
    s.finish()
