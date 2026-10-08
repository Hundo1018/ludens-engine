# tier: integration
"""ROADMAP 17.4 seam: wheel-road contact by one ray vs a swept sphere vs a
swept capsule (gameplay/vehicle_wheel.mojo), parity on the same road.

Ordinary: on a flat road, a 20-degree ramp (analytic hub height) and a
heightfield all three variants return the same hub distance, contact point and
normal within the query skin.
Integration: a dynamic body under the wheel is reported by index; the chassis
filter hides the car's own box; a wall beside the tire does not hide the road.
Where they legitimately DIFFER (documented, asserted): at a kerb the sweeps
climb the edge a wheel radius ahead while the ray still sees the low road; over
a narrow pothole the ray falls in (a miss within reach) while the sweeps
bridge it.
Extreme: nothing within reach, ground exactly beyond reach, mount below the
surface (starts solid), a ray grazing a vertical face."""

from harness.runner import Suite
from std.math import tan, cos, sin
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter
from gameplay.vehicle_wheel import (
    WheelCast,
    WheelHit,
    RayWheel,
    SphereWheel,
    CapsuleWheel,
)

comptime R: Real = 0.33
comptime HW: Real = 0.12
comptime REACH: Real = 0.35
comptime DOWN = Vec3(0, -1, 0, 0)
comptime AXLE = Vec3(0, 0, 1, 0)


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _dyn(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(5, 0.5, 0.5, 0.5))


def _floor() -> ContactScene6[QuatBody6]:
    """Road top at y = 0."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(_st(Vec3(0, -1, 0, 0)), Vec3(30, 1, 30, 0), True)
    return sc^


def _wedge(x0: Real, length_x: Real, rise: Real) -> List[Real]:
    var v = List[Real]()
    for z in range(2):
        var zz = Real(z * 8 - 4)
        for p in [(x0, Real(0)), (x0 + length_x, Real(0)), (x0 + length_x, rise)]:
            v.append(p[0])
            v.append(p[1])
            v.append(zz)
    return v^


def _all[B: WheelCast](
    sc: ContactScene6[QuatBody6], c: B, mount: Vec3, f: QueryFilter
) -> WheelHit:
    return c.cast(sc.colliders, sc.query_poses(), mount, DOWN, AXLE, REACH, R, HW, f)


def _agree(mut s: Suite, name: String, a: WheelHit, b: WheelHit, tol: Real):
    s.check(a.hit == b.hit, name + ": same hit/miss")
    if a.hit and b.hit:
        s.almost(Float64(a.hub), Float64(b.hub), name + ": hub distance", Float64(tol))
        s.almost(Float64(a.point[1]), Float64(b.point[1]), name + ": contact height", Float64(tol) * 2)
        s.almost(Float64(a.point[0]), Float64(b.point[0]), name + ": contact x", Float64(tol) * 2)
        s.almost(Float64(dot(a.normal, b.normal)), 1.0, name + ": normal", 2e-3)
        s.eqi(a.body, b.body, name + ": same body")


def main() raises:
    var s = Suite("vehicle_wheel")
    var ray = RayWheel()
    var sph = SphereWheel()
    var cap = CapsuleWheel()
    var all = QueryFilter.all()

    # ---- flat road ----
    var fl = _floor()
    for x in [Real(-3), Real(0), Real(4.7)]:
        var m = Vec3(x, 0.6, 1.3, 0)
        var a = _all(fl, ray, m, all)
        var b = _all(fl, sph, m, all)
        var c = _all(fl, cap, m, all)
        s.check(a.hit, "flat: ray hits")
        s.almost(Float64(a.hub), Float64(0.6 - R), "flat: hub = mount height - radius", 1e-3)
        s.almost(Float64(a.point[1]), 0.0, "flat: contact on the road surface", 1e-3)
        _agree(s, "flat ray/sphere", a, b, 2e-3)
        _agree(s, "flat ray/capsule", a, c, 2e-3)

    # ---- 20 degree ramp: analytic hub height ----
    var ang = Real(0.349066)
    var ramp = _floor()
    _ = ramp.add_hull(_st(Vec3(0, 0, 0, 0)), _wedge(1, 6, 6 * tan(ang)), True)
    for x in [Real(2.5), Real(4.0), Real(5.5)]:
        var ym = Real(0.5) + (x - 1) * tan(ang)
        var m = Vec3(x, ym + 0.1, 0.2, 0)
        var want = (ym + 0.1) - (x - 1) * tan(ang) - R / cos(ang)  # mount height above the plane, less R / cos
        var a = _all(ramp, ray, m, all)
        var b = _all(ramp, sph, m, all)
        var c = _all(ramp, cap, m, all)
        s.check(a.hit and b.hit and c.hit, "ramp: all variants hit")
        s.almost(Float64(a.hub), Float64(want), "ramp: ray hub matches the plane analytically", 3e-3)
        s.almost(Float64(b.hub), Float64(want), "ramp: sphere hub matches the plane analytically", 6e-3)
        s.almost(Float64(dot(a.normal, Vec3(-sin(ang), cos(ang), 0, 0))), 1.0, "ramp: ray normal is the ramp's", 2e-3)
        _agree(s, "ramp ray/sphere", a, b, 6e-3)
        _agree(s, "ramp ray/capsule", a, c, 6e-3)

    # ---- heightfield (flat at y = 0.5) ----
    var hf = ContactScene6[QuatBody6]()
    var hts = List[Real]()
    for _ in range(9):
        hts.append(0.5)
    var hid = hf.add_heightfield(_st(Vec3(0, 0, 0, 0)), hts, 3, 3, 5.0, 0.0, 0.0)
    var mh = Vec3(5, 1.1, 5, 0)
    var ha = _all(hf, ray, mh, all)
    s.check(ha.hit and ha.body == hid.index(), "heightfield: ray hits it")
    s.almost(Float64(ha.hub), 0.6 - Float64(R), "heightfield: hub", 1e-3)
    _agree(s, "heightfield ray/sphere", ha, _all(hf, sph, mh, all), 2e-3)
    _agree(s, "heightfield ray/capsule", ha, _all(hf, cap, mh, all), 2e-3)

    # ---- dynamic body under the wheel, and the chassis filter ----
    var dy = _floor()
    var bid = dy.add(_dyn(Vec3(0, 0.25, 0, 0)), Vec3(0.5, 0.25, 0.5, 0), False)
    var md = Vec3(0, 0.9, 0, 0)
    var da = _all(dy, ray, md, all)
    s.check(da.hit and da.body == bid.index(), "dynamic body is reported as the ground")
    s.almost(Float64(da.hub), 0.9 - 0.5 - Float64(R), "its top is the contact", 1e-3)
    var ignoring = _all(dy, ray, md, QueryFilter.ignoring(bid.index()))
    s.check(not ignoring.hit, "filter hides the car's own chassis (road is beyond reach)")
    s.check(_all(dy, sph, md, all).body == bid.index() and _all(dy, cap, md, all).body == bid.index(), "sweeps agree on the body")

    # ---- kerb: the documented difference ----
    var kerb = _floor()
    _ = kerb.add(_st(Vec3(5, 0.075, 0, 0)), Vec3(3, 0.075, 5, 0), True)  # raised road, x in [2, 8], top y = 0.15
    var mk = Vec3(1.9, 0.6, 0, 0)
    var ka = _all(kerb, ray, mk, all)
    var kb = _all(kerb, sph, mk, all)
    var kc = _all(kerb, cap, mk, all)
    s.almost(Float64(ka.hub), 0.6 - Float64(R), "kerb: ray still sees the low road under the mount", 1e-3)
    s.check(kb.hit and kb.hub < ka.hub - 0.01, "kerb: sphere meets the edge ahead and rides higher (" + String(kb.hub) + " vs " + String(ka.hub) + ")")
    s.check(kb.normal[0] < -0.2, "kerb: sphere normal leans back off the edge")
    s.almost(Float64(kc.hub), Float64(kb.hub), "kerb: capsule matches the sphere along a straight edge", 2e-3)
    var far = Vec3(-3, 0.6, 0, 0)
    _agree(s, "far from the kerb", _all(kerb, ray, far, all), _all(kerb, sph, far, all), 2e-3)
    var top = Vec3(5, 0.6, 0, 0)
    s.almost(Float64(_all(kerb, ray, top, all).hub), 0.6 - 0.15 - Float64(R), "on top of the kerb", 1e-3)

    # ---- pothole narrower than the wheel ----
    var hole = ContactScene6[QuatBody6]()
    _ = hole.add(_st(Vec3(-3.05, -1, 0, 0)), Vec3(5, 1, 5, 0), True)  # x in [-8.05, 1.95]
    _ = hole.add(_st(Vec3(7.05, -1, 0, 0)), Vec3(5, 1, 5, 0), True)  # x in [2.05, 12.05]
    var mp = Vec3(2.0, 0.6, 0, 0)
    var pa = _all(hole, ray, mp, all)
    var pb = _all(hole, sph, mp, all)
    var pc = _all(hole, cap, mp, all)
    s.check(not pa.hit, "pothole: the ray falls into the 0.1 m gap and finds no road within reach")
    s.check(pb.hit and pc.hit, "pothole: the sweeps bridge it")
    s.check(pb.hub > 0.0 and pb.hub < REACH, "pothole: bridged wheel rides inside the stroke (" + String(pb.hub) + ")")

    # ---- wall beside the tire does not hide the road ----
    var wall = _floor()
    _ = wall.add(_st(Vec3(0, 1, 0.3, 0)), Vec3(5, 1, 0.1, 0), True)  # a wall 0.2 m off the wheel's centre line
    var mw = Vec3(0, 0.6, 0, 0)
    var wa = _all(wall, ray, mw, all)
    var wb = _all(wall, sph, mw, all)
    s.check(wa.hit and wb.hit, "wall: both still find the road")
    s.almost(Float64(wb.hub), Float64(wa.hub), "wall: sphere falls back to the ray result", 2e-3)
    s.check(wb.normal[1] > 0.9, "wall: the road's normal, not the wall's")

    # ---- extremes ----
    var e = _floor()
    var up_high = Vec3(0, 5, 0, 0)
    s.check(not _all(e, ray, up_high, all).hit and not _all(e, sph, up_high, all).hit and not _all(e, cap, up_high, all).hit, "nothing within reach: all miss")
    var beyond = Vec3(0, REACH + R + 0.05, 0, 0)
    s.check(not _all(e, ray, beyond, all).hit and not _all(e, sph, beyond, all).hit, "ground just beyond full droop: miss")
    var inside = Vec3(0, -0.2, 0, 0)
    var ia = _all(e, ray, inside, all)
    var ib = _all(e, sph, inside, all)
    s.check(ib.hit and ib.hub <= 0.01, "mount below the road: the sweep reports full compression")
    s.check(not ia.hit or ia.hub <= 0.0, "mount below the road: the ray (inside the box) gives no usable hub")
    var empty = ContactScene6[QuatBody6]()
    s.check(not _all(empty, ray, Vec3(0, 1, 0, 0), all).hit and not _all(empty, sph, Vec3(0, 1, 0, 0), all).hit, "empty scene: miss")

    s.finish()
