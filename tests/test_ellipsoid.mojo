# tier: integration
"""Ellipsoid as a solver shape (ROADMAP 17.52): `ContactScene6.add_ellipsoid`.

  1. Ordinary:
     - equal radii 0.5 on a box floor rests where a sphere of radius 0.5
       does (parity, 1e-4);
     - radii (1, 0.5, 0.7) lying on the floor rests at y = 0.5;
     - a prolate ellipsoid (1, 0.4, 0.4) released with its long axis tilted
       45 deg ends lying down (axis horizontal, y = 0.4) under angular
       damping; undamped it rocks without gaining height or sinking.
  2. Integration:
     - equal radii rolling down a 20 deg slope (mu 0.8) tracks a sphere in
       the same scene, and 5/7 g sin(theta) after 1 s;
     - two ellipsoids stacked (angular damping); resting on a trimesh and on
       an SDF plane;
     - ray, point distance and `set_mass_from_density` against closed forms;
     - snapshot round trip bit-identical.
  3. Extreme: a 10:1 disc (radii 1, 0.1, 1) dropped flat rests at y = 0.1.
"""

from std.math import sin, cos, pi, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.sdf_grid import SdfGrid
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)


def _rest(radii: Vec3, y0: Real, q: Quat, steps: Int = 180, damp: Real = 0) raises -> Tuple[Real, Vec3]:
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var b = QuatBody6.at_rest(Vec3(0.1, y0, -0.2, 0), Inertia3.ellipsoid(1, radii[0], radii[1], radii[2]))
    b.q = q
    var id = sc.add_ellipsoid(b^, radii, False)
    sc.set_can_sleep(id, False)
    if damp > 0:
        sc.set_damping(id, 0, damp)
    for _ in range(steps):
        sc.step_soft(DT, G)
    return (sc.pose(id).pos[1], sc.pose(id).rot.rotate(Vec3(1, 0, 0, 0)))


def _roll(ellipsoid: Bool) raises -> Real:
    var th = Real(20) * pi / 180
    var down = Vec3(cos(th), -sin(th), 0, 0)
    var nrm = Vec3(sin(th), cos(th), 0, 0)
    var sc = ContactScene6[QuatBody6]()
    var slope = QuatBody6.at_rest(Vec3(0, 0, 0, 0) - nrm * 0.5, Inertia3.box(1, 30, 0.5, 5))
    slope.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), -th)
    _ = sc.add(slope^, Vec3(30, 0.5, 5, 0), True)
    var c = QuatBody6.at_rest(down * Real(-5) + nrm * 0.5, Inertia3.sphere(1, 0.5))
    var id = sc.add_ellipsoid(c^, Vec3(0.5, 0.5, 0.5, 0), False) if ellipsoid else sc.add_sphere(c^, 0.5, False)
    sc.set_can_sleep(id, False)
    for _ in range(60):
        sc.step_soft(DT, G, mu=0.8)
    var v = sc.velocity(id)
    return v[0] * down[0] + v[1] * down[1]


def _plane(res: Int) -> SdfGrid:
    var g = SdfGrid(res, Vec3(-6, -6, -6, 0), Real(12) / Real(res - 1))
    for k in range(res):
        for j in range(res):
            for i in range(res):
                g.values[(k * res + j) * res + i] = g.node(i, j, k)[1]
    return g^


def main() raises:
    var s = Suite("ellipsoid")
    var ident = Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0)

    # ---- parity with the sphere ----------------------------------------------
    var eq = _rest(Vec3(0.5, 0.5, 0.5, 0), 0.6, ident)
    var sp = ContactScene6[QuatBody6]()
    _floor(sp)
    var sid = sp.add_sphere(QuatBody6.at_rest(Vec3(0.1, 0.6, -0.2, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    sp.set_can_sleep(sid, False)
    for _ in range(180):
        sp.step_soft(DT, G)
    print("  equal radii 0.5 on a box floor: y", eq[0], " sphere r 0.5: y", sp.pose(sid).pos[1])
    s.check(abs(eq[0] - sp.pose(sid).pos[1]) < 1e-4, "equal-axis ellipsoid rests where the sphere does (1e-4)")

    var lying = _rest(Vec3(1, 0.5, 0.7, 0), 0.6, ident)
    print("  radii (1, 0.5, 0.7) lying: y", lying[0])
    s.check(abs(lying[0] - 0.5) < 2e-3, "ellipsoid rests on its short axis at y = 0.5")

    # rolling without slipping loses no energy: undamped it rocks for ever,
    # so the equilibrium is checked with angular damping 2 / s
    var tilt = _rest(Vec3(1, 0.4, 0.4, 0), 1.2, Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 4), 600, 2)
    print("  prolate (1, 0.4, 0.4) from 45 deg, angular damping 2: y", tilt[0], " long axis . up", tilt[1][1])
    s.check(abs(tilt[1][1]) < 0.02 and abs(tilt[0] - 0.4) < 3e-3, "prolate ellipsoid falls to lying (axis horizontal, y = 0.4)")
    # undamped rocking: released lying with its long axis tilted 10 deg, the
    # centre never rises above the release height (no energy gained) and
    # never sinks below the short radius (no penetration)
    var rk = ContactScene6[QuatBody6]()
    _floor(rk)
    var rb = QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.ellipsoid(1, 1, 0.4, 0.4))
    var a10 = Real(10) * pi / 180
    rb.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), a10)
    # height of the lowest point of the tilted ellipsoid: sqrt(a^2 sin^2 + b^2 cos^2)
    var y_rel = sqrt(Real(1) * sin(a10) ** 2 + Real(0.16) * cos(a10) ** 2)
    rb.pos = Vec3(0, y_rel, 0, 0)
    var rid = rk.add_ellipsoid(rb^, Vec3(1, 0.4, 0.4, 0), False)
    rk.set_can_sleep(rid, False)
    var ymin = Real(1e9)
    var ymax = Real(-1e9)
    for _ in range(600):
        rk.step_soft(DT, G, mu=0.8)
        ymin = min(ymin, rk.pose(rid).pos[1])
        ymax = max(ymax, rk.pose(rid).pos[1])
    print("  undamped rocking from 10 deg: release y", y_rel, " centre y range", ymin, "..", ymax)
    s.check(ymax < y_rel + 1e-3 and ymin > 0.4 - 3e-3, "undamped rocking: no energy gained, no penetration")

    # ---- rolling ------------------------------------------------------------
    var re = _roll(True)
    var rs = _roll(False)
    var want = Real(5.0 / 7.0) * Real(9.8) * sin(Real(20) * pi / 180)
    print("  rolling down 20 deg after 1 s: ellipsoid", re, " sphere", rs, " 5/7 g sin", want)
    s.check(abs(re - rs) < 1e-3 * want, "equal-axis ellipsoid rolls like the sphere (0.1 %)")
    s.check(abs(re - want) < 0.01 * want, "and at 5/7 g sin(theta) (1 %)")

    # ---- stack, mesh, SDF -----------------------------------------------------
    var st = ContactScene6[QuatBody6]()
    _floor(st)
    var lo = st.add_ellipsoid(QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.ellipsoid(1, 0.8, 0.5, 0.6)), Vec3(0.8, 0.5, 0.6, 0), False)
    var hi = st.add_ellipsoid(QuatBody6.at_rest(Vec3(0.02, 1.35, 0, 0), Inertia3.ellipsoid(1, 0.6, 0.3, 0.6)), Vec3(0.6, 0.3, 0.6, 0), False)
    st.set_can_sleep(lo, False)
    st.set_can_sleep(hi, False)
    st.set_damping(lo, 0, 2)
    st.set_damping(hi, 0, 2)
    for _ in range(240):
        st.step_soft(DT, G)
    print("  stack: lower y", st.pose(lo).pos[1], " upper y", st.pose(hi).pos[1], " (0.5 and 1.3)")
    s.check(abs(st.pose(lo).pos[1] - 0.5) < 3e-3 and abs(st.pose(hi).pos[1] - 1.3) < 6e-3, "two ellipsoids stack at 0.5 and 1.3")

    var v = List[Real]()
    for x in [Real(-10), Real(10)]:
        for z in [Real(-10), Real(10)]:
            v.append(x)
            v.append(0)
            v.append(z)
    var idx: List[Int] = [0, 1, 3, 0, 3, 2]
    var ms = ContactScene6[QuatBody6]()
    _ = ms.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 10, 1, 10)), v^, idx^)
    var me = ms.add_ellipsoid(QuatBody6.at_rest(Vec3(0.3, 0.6, 0.1, 0), Inertia3.ellipsoid(1, 1, 0.5, 0.7)), Vec3(1, 0.5, 0.7, 0), False)
    ms.set_can_sleep(me, False)
    var sd = ContactScene6[QuatBody6]()
    var gid = sd.add_sdf(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), _plane(25))
    var se = sd.add_ellipsoid(QuatBody6.at_rest(Vec3(0.3, 0.6, 0.1, 0), Inertia3.ellipsoid(1, 1, 0.5, 0.7)), Vec3(1, 0.5, 0.7, 0), False)
    sd.set_can_sleep(se, False)
    for _ in range(180):
        ms.step_soft(DT, G)
        sd.step_soft(DT, G)
    print("  on a trimesh floor: y", ms.pose(me).pos[1], " on an SDF plane: y", sd.pose(se).pos[1])
    s.check(abs(ms.pose(me).pos[1] - 0.5) < 2e-3, "ellipsoid rests on a trimesh at y = 0.5")
    s.check(abs(sd.pose(se).pos[1] - 0.5) < 2e-3, "ellipsoid rests on an SDF at y = 0.5")
    _ = gid

    # ---- queries and mass ---------------------------------------------------
    var qs = ContactScene6[QuatBody6]()
    var qe = qs.add_ellipsoid(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.ellipsoid(1, 1, 0.5, 0.7)), Vec3(1, 0.5, 0.7, 0), True)
    var h = qs.ray_cast(Vec3(0, 5, 0, 0), Vec3(0, -1, 0, 0), 20, ALL)
    var h2 = qs.ray_cast(Vec3(-5, 0, 0, 0), Vec3(1, 0, 0, 0), 20, ALL)
    var pd = qs.closest_point(qe.index(), Vec3(0, 2, 0, 0))
    var pin = qs.closest_point(qe.index(), Vec3(0.9, 0, 0, 0))
    print("  ray down t", h.t, " ray along x t", h2.t, " distance from (0, 2, 0)", pd.dist, " from (0.9, 0, 0)", pin.dist)
    s.check(h.hit and abs(h.t - 4.5) < 1e-5 and h.normal[1] > 0.9999, "ray down hits the top at t = 4.5, normal up")
    s.check(h2.hit and abs(h2.t - 4) < 1e-5, "ray along x hits at t = 4")
    s.check(abs(pd.dist - 1.5) < 1e-4, "point distance from (0, 2, 0) is 1.5")
    s.check(abs(pin.dist + 0.1) < 2e-3, "point inside at (0.9, 0, 0): signed distance -0.1")
    qs.set_mass_from_density(qe, 2)
    var mass = 1 / qs.bset.bodies[qe.index()].inv_mass()
    var wm = Real(2) * Real(4.0 / 3.0) * pi * Real(1 * 0.5 * 0.7)
    print("  density 2: mass", mass, " 2 * 4/3 pi a b c", wm)
    s.check(abs(mass - wm) < 1e-4 * wm, "set_mass_from_density: rho 4/3 pi a b c")

    # ---- snapshot -------------------------------------------------------------
    var sn = ContactScene6[QuatBody6]()
    _floor(sn)
    var sb = QuatBody6.at_rest(Vec3(0, 1.2, 0, 0), Inertia3.ellipsoid(1, 1, 0.4, 0.6))
    sb.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.6)
    var sid2 = sn.add_ellipsoid(sb^, Vec3(1, 0.4, 0.6, 0), False)
    for _ in range(30):
        sn.step_soft(DT, G)
    var blob = scene_to_string(sn)
    var rsn = scene_from_string(blob)
    s.check(scene_to_string(rsn) == blob, "snapshot with an ellipsoid: re-serialised blob identical")
    var same = True
    for _ in range(60):
        sn.step_soft(DT, G)
        rsn.step_soft(DT, G)
        if sn.bset.bodies[sid2.index()].pos[1] != rsn.bset.bodies[sid2.index()].pos[1]:
            same = False
    s.check(same, "restored ellipsoid scene steps bit-identically")

    # ---- extreme --------------------------------------------------------------
    var disc = _rest(Vec3(1, 0.1, 1, 0), 0.3, ident)
    print("  disc (1, 0.1, 1): y", disc[0])
    s.check(abs(disc[0] - 0.1) < 2e-3, "10:1 disc rests flat at y = 0.1")
    s.finish()
