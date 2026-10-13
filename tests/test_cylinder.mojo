# tier: integration
"""Cylinder shape and the spread contact reduction (ROADMAP 17.52).

  1. Ordinary: a solid cylinder (r 0.5) lying across a 20 deg slope
     (mu 0.8) rolls without slipping: speed after 1 s = 2/3 g sin(theta)
     within 0.01 %, 8 and 16 segments within 1e-5 (the side contact is the
     capsule manifold with round anchors, not the polygon). Standing on its
     end it stays upright at y = hl; lying on a floor it rests at y = r.
  2. Integration: `Inertia3.cylinder` matches the solid-cylinder formulas;
     the spread reduction picks four points around the whole cap -- the
     support polygon contains the centre of mass, so a tall cylinder on a
     16-gon base does not tip (it did, keeping the first four of the
     clipped polygon).
  3. Extreme: segments clamp to [3, 16] (a 64-segment request builds 16);
     a 3-segment (triangular) prism still stands.
"""

from std.math import sin, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)


def _roll(seg: Int) raises -> Real:
    var th = Real(20) * pi / 180
    var down = Vec3(cos(th), -sin(th), 0, 0)
    var nrm = Vec3(sin(th), cos(th), 0, 0)
    var sc = ContactScene6[QuatBody6]()
    var slope = QuatBody6.at_rest(Vec3(0, 0, 0, 0) - nrm * 0.5, Inertia3.box(1, 30, 0.5, 5))
    slope.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), -th)
    _ = sc.add(slope^, Vec3(30, 0.5, 5, 0), True)
    var c = QuatBody6.at_rest(down * Real(-5) + nrm * 0.5, Inertia3.cylinder(1, 0.5, 0.5))
    c.q = Quat.from_axis_angle(Vec3(1, 0, 0, 0), pi / 2)
    var id = sc.add_cylinder(c^, 0.5, 0.5, False, seg)
    sc.set_can_sleep(id, False)
    for _ in range(60):
        sc.step_soft(DT, G, mu=0.8)
    var v = sc.velocity(id)
    return v[0] * down[0] + v[1] * down[1]


def _stand(seg: Int, r: Real, hl: Real) raises -> Tuple[Real, Real]:
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var cy = sc.add_cylinder(QuatBody6.at_rest(Vec3(0, hl + 0.02, 0, 0), Inertia3.cylinder(1, r, hl)), r, hl, False, seg)
    sc.set_can_sleep(cy, False)
    for _ in range(180):
        sc.step_soft(DT, G)
    var ax = sc.pose(cy).rot.rotate(Vec3(0, 1, 0, 0))
    return (sc.pose(cy).pos[1], ax[1])


def main() raises:
    var s = Suite("cylinder")
    var want = Real(2.0 / 3.0) * Real(9.8) * sin(Real(20) * pi / 180)
    var r8 = _roll(8)
    var r16 = _roll(16)
    print("  rolling down 20 deg: 8 segments", r8, " 16 segments", r16, " analytic 2/3 g sin", want)
    s.check(abs(r16 - want) < 1e-4 * want, "cylinder rolls at 2/3 g sin(theta) (0.01 %)")
    s.check(abs(r8 - r16) < 1e-5 * want, "rolling does not depend on the tessellation (1e-5)")

    var st = _stand(16, 0.3, 0.7)
    print("  standing r 0.3 hl 0.7 on a 16-gon base: y", st[0], " axis y", st[1])
    s.check(abs(st[0] - 0.7) < 2e-3 and st[1] > 0.9999, "tall cylinder stands on its end at y = hl")
    var sl = ContactScene6[QuatBody6]()
    _floor(sl)
    var lc = QuatBody6.at_rest(Vec3(0, 0.32, 0, 0), Inertia3.cylinder(1, 0.3, 0.7))
    lc.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 2)
    var li = sl.add_cylinder(lc^, 0.3, 0.7, False)
    for _ in range(120):
        sl.step_soft(DT, G)
    print("  lying on the floor: y", sl.pose(li).pos[1])
    s.check(abs(sl.pose(li).pos[1] - 0.3) < 2e-3, "lying cylinder rests at y = r")

    var ic = Inertia3.cylinder(2, 0.5, 1.0)
    s.check(abs(ic.iy - 0.25) < 1e-6 and abs(ic.ix - 2 * (3 * 0.25 + 4) / 12) < 1e-6, "Inertia3.cylinder: m r^2 / 2 and m (3 r^2 + (2 hl)^2) / 12")

    var big = ContactScene6[QuatBody6]()
    var bid = big.add_cylinder(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.cylinder(1, 0.3, 0.7)), 0.3, 0.7, True, 64)
    s.eqi(big.colliders.hulls[big.colliders.hull_id[bid.index()]].nv(), 32, "64 segments requested: clamped to 16 (32 vertices)")
    var tri = _stand(3, 0.4, 0.3)
    s.check(abs(tri[0] - 0.3) < 2e-3 and tri[1] > 0.9999, "a 3-segment prism still stands")
    s.finish()
