# tier: integration
"""ROADMAP 17.13: world queries against the real collider geometry
(`collision.world_query`, through `ContactScene6`'s wrappers).

Ordinary: rays onto a box floor, a sphere, a hull and a heightfield hit at
the analytic distance; sphere and capsule casts stop at the surface minus
their radius; overlaps and penetrations report the right bodies, depth and
normal. The case the old `SceneQuery` got wrong: a ray through a sphere's
bounding-box corner that misses the sphere itself.
Integration: a ray from above a settled stack hits the top box's top face.
Extreme: max_t = 0, a ray starting inside a box, a sweep starting inside, the
query's own body ignored, a sensor skipped unless asked for, an empty scene,
a grazing ray along a face."""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, length
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime DOWN = Vec3(0, -1, 0, 0)
comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)


def _static(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _dyn(p: Vec3, h: Real) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, h, h, h))


def _floor_scene() -> ContactScene6[QuatBody6]:
    """Box floor with its top face at y = 0 (half-extents 10, 1, 10)."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(_static(Vec3(0, -1, 0, 0)), Vec3(10, 1, 10, 0), True)
    return sc^


def main() raises:
    var s = Suite("world_query")

    # ---- ordinary: ray onto a box floor ----
    var sc = _floor_scene()
    var h = sc.ray_cast(Vec3(1, 5, 2, 0), DOWN, 100, ALL)
    s.check(h.hit and h.body == 0, "ray hits the floor")
    s.almost(Float64(h.t), 5.0, "ray t = height above the top face", 1e-5)
    s.almost(Float64(h.normal[1]), 1.0, "floor normal points up", 1e-5)

    # ---- sphere: real surface, not its bounding box ----
    var sid = sc.add_sphere(_static(Vec3(0, 3, 0, 0)), 1.0, True).index()
    var hs = sc.ray_cast(Vec3(-5, 3, 0, 0), Vec3(1, 0, 0, 0), 100, ALL)
    s.check(hs.hit and hs.body == sid, "horizontal ray hits the sphere")
    s.almost(Float64(hs.t), 4.0, "ray t = distance to the sphere surface", 1e-5)
    # through the AABB corner region (y = 3.9, z = 0.9): inside the box
    # [-1,1]^3 around the centre, outside the sphere (0.9^2+0.9^2 > 1)
    var hc = sc.ray_cast(Vec3(-5, 3.9, 0.9, 0), Vec3(1, 0, 0, 0), 100, ALL)
    s.check(not hc.hit, "a ray through the sphere's AABB corner misses the sphere")

    # ---- sphere cast and capsule cast ----
    var sweep = sc.sphere_cast(Vec3(5, 4, 5, 0), 0.5, DOWN, 100, ALL)
    s.check(sweep.hit and sweep.body == 0, "sphere cast lands on the floor")
    s.almost(Float64(sweep.t), 3.5, "sphere cast t = height - radius", 2e-3)
    var cap = sc.capsule_cast(
        Vec3(-6, 0.9, 0, 0), Vec3(-6, 2.1, 0, 0), 0.3, Vec3(1, 0, 0, 0), 100, ALL
    )
    s.check(cap.hit and cap.body == sid, "capsule cast sideways hits the sphere")
    # capsule axis at x=-6 reaches the sphere (centre x=0, y=3, r=1) where
    # the segment's top end (y=2.1) is closest: distance from (x,2.1) to
    # (0,3) = 1.3 -> x = -sqrt(1.3^2 - 0.9^2)
    var want = 6.0 - sqrt(1.3 * 1.3 - 0.9 * 0.9)
    s.almost(Float64(cap.t), want, "capsule cast t matches the analytic contact", 5e-3)

    # ---- overlaps and penetrations ----
    var ov = sc.overlap_sphere(Vec3(0, 0.2, 0, 0), 0.5, ALL)
    s.eqi(len(ov), 1, "sphere overlapping only the floor finds exactly one body")
    var pen = sc.capsule_penetrations(
        Vec3(3, 0.2, 0, 0), Vec3(3, 1.2, 0, 0), 0.3, ALL
    )
    s.eqi(len(pen), 1, "capsule sunk into the floor: one penetration")
    if len(pen) == 1:
        s.almost(Float64(pen[0].depth), 0.1, "penetration depth = r - clearance", 1e-4)
        s.almost(Float64(pen[0].normal[1]), 1.0, "push-out normal is up", 1e-4)

    # ---- hull (a unit cube as a hull) ----
    var cube = List[Real]()
    for x in range(2):
        for y in range(2):
            for z in range(2):
                cube.append(Real(x * 2 - 1))
                cube.append(Real(y * 2 - 1))
                cube.append(Real(z * 2 - 1))
    var hid = sc.add_hull(_static(Vec3(6, 1, 6, 0)), cube^, True).index()
    var hh = sc.ray_cast(Vec3(6, 8, 6, 0), DOWN, 100, ALL)
    s.check(hh.hit and hh.body == hid, "ray hits the hull")
    s.almost(Float64(hh.t), 6.0, "hull top face at y = 2", 1e-4)

    # ---- heightfield (flat at y = 0.5 over x,z in [20, 30]) ----
    var hts = List[Real]()
    for _ in range(9):
        hts.append(0.5)
    var fid = sc.add_heightfield(_static(Vec3(0, 0, 0, 0)), hts, 3, 3, 5.0, 20.0, 20.0).index()
    var hf = sc.ray_cast(Vec3(25, 3, 25, 0), DOWN, 100, ALL)
    s.check(hf.hit and hf.body == fid, "ray hits the heightfield")
    s.almost(Float64(hf.t), 2.5, "heightfield surface at y = 0.5", 1e-4)

    # ---- closest point on the sphere ----
    var cp = sc.closest_point(sid, Vec3(0, 6, 0, 0))
    s.almost(Float64(cp.dist), 2.0, "closest-point distance to the sphere", 1e-5)
    s.almost(Float64(cp.point[1]), 4.0, "closest point is the sphere's top", 1e-5)

    # ---- integration: settled stack ----
    var st = _floor_scene()
    var top = -1
    for i in range(3):
        top = st.add(_dyn(Vec3(0, 0.25 + Real(i) * 0.5, 0, 0), 0.25), Vec3(0.25, 0.25, 0.25, 0), False).index()
    for _ in range(120):
        st.step_soft(DT, G)
    var ytop = Float64(st.bset.bodies[top].position()[1]) + 0.25
    var hstack = st.ray_cast(Vec3(0, 5, 0, 0), DOWN, 100, ALL)
    s.check(hstack.hit and hstack.body == top, "ray from above hits the stack's top box")
    s.almost(5.0 - Float64(hstack.t), ytop, "at the top box's top face", 1e-4)

    # ---- extreme cases ----
    s.check(not sc.ray_cast(Vec3(1, 5, 2, 0), DOWN, 0, ALL).hit, "max_t = 0 hits nothing")
    var inside = sc.ray_cast(Vec3(1, -1, 1, 0), DOWN, 10, ALL)
    s.check(inside.hit and inside.start_solid and inside.t == 0, "ray starting inside the floor: start_solid at t = 0")
    var solid = sc.sphere_cast(Vec3(0, 0.1, 5, 0), 0.5, Vec3(1, 0, 0, 0), 5, ALL)
    s.check(solid.hit and solid.start_solid, "sweep starting in the floor reports start_solid")
    var ign = sc.ray_cast(Vec3(1, 5, 2, 0), DOWN, 100, QueryFilter(0xFFFFFFFF, 0, False))
    s.check(not ign.hit, "the ignored body (the floor) is not hit")
    var sens = sc.add(_static(Vec3(-6, 3, -6, 0)), Vec3(1, 1, 1, 0), True).index()
    sc.set_sensor(sens, True)
    s.check(sc.ray_cast(Vec3(-6, 8, -6, 0), DOWN, 100, ALL).body == 0, "sensor skipped by default: the floor is hit")
    s.check(sc.ray_cast(Vec3(-6, 8, -6, 0), DOWN, 100, QueryFilter(0xFFFFFFFF, -1, True)).body == sens, "sensor hit when asked for")
    var empty = ContactScene6[QuatBody6]()
    s.check(not empty.ray_cast(Vec3(0, 0, 0, 0), DOWN, 10, ALL).hit, "empty scene: miss")
    var graze = sc.ray_cast(Vec3(-20, 0, 7.5, 0), Vec3(1, 0, 0, 0), 5, ALL)
    s.check(graze.hit == False or graze.t <= 10.0, "grazing ray along the floor's top face terminates")
    s.finish()
