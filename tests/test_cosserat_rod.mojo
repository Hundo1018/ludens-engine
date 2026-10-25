# tier: component
"""Cosserat rods with a twist degree of freedom (ROADMAP 17.57,
`physics.cosserat_rod`).

A 1 m rod of 20 segments (0.1 kg) along z, no gravity unless stated.

  1. Ordinary: both ends clamped (two points and the end segment each),
     the last segment turned by pi about the axis over 5 s and held: the
     twist spreads evenly -- every joint within 1 % of pi / 19 -- and the
     rod stays on its axis.
  2. Integration: the turned end then let go (its segment free again)
     untwists: the total twist falls below 5 % of pi within 5 s.
  3. Bending: a horizontal cantilever under gravity, clamped at one end,
     sags less with a stiffer bend compliance (0.01 vs 1); finite.
  4. Extreme: one point, zero mass, negative compliance raise.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.cosserat_rod import CosseratRod


def straight(dir: Vec3) -> List[Vec3]:
    var pts = List[Vec3]()
    for i in range(21):
        pts.append(dir * (Real(i) * 0.05))
    return pts^


def clamp_ends(mut r: CosseratRod):
    var ns = r.segments()
    r.fix_point(0)
    r.fix_point(1)
    r.fix_segment(0)
    r.fix_point(20)
    r.fix_point(19)
    r.fix_segment(ns - 1)


def total_twist(r: CosseratRod) -> Real:
    var t = Real(0)
    for j in range(r.segments() - 1):
        t += r.twist_angle(j)
    return t


def main() raises:
    var s = Suite("cosserat_rod")
    var zero = Vec3(0, 0, 0, 0)

    var r = CosseratRod(straight(Vec3(0, 0, 1, 0)), 0.1)
    r.damping = 0.98
    clamp_ends(r)
    var ns = r.segments()
    var q0 = r.q[ns - 1]
    var phi = Real(pi)
    for k in range(600):
        var f = min(Real(k + 1) / 300, Real(1))
        r.set_segment(ns - 1, Quat.from_axis_angle(Vec3(0, 0, 1, 0), phi * f) * q0)
        r.step(1.0 / 60.0, zero)
    var want = phi / Real(ns - 1)
    var worst = Real(0)
    var lat = Real(0)
    for j in range(ns - 1):
        worst = max(worst, abs(r.twist_angle(j) / want - 1))
    for p in r.x:
        lat = max(lat, (p[0] * p[0] + p[1] * p[1]) ** 0.5)
    print("  clamped, end turned by pi: total twist", total_twist(r), " per joint", want, " worst relative deviation", worst, " max off-axis", lat)
    s.check(worst < 0.01, "twist spread evenly: every joint within 1 % of pi / 19")
    s.check(lat < 1e-5, "the rod stays on its axis")

    r.wq[ns - 1] = r.wq[ns - 2]
    for _ in range(300):
        r.step(1.0 / 60.0, zero)
    var left = total_twist(r)
    print("  end released: total twist after 5 s", left)
    s.check(abs(left) < 0.05 * phi, "released end untwists: below 5 % of pi in 5 s")

    var sags = List[Real]()
    for comp in [Real(1), Real(0.01)]:
        var c = CosseratRod(straight(Vec3(1, 0, 0, 0)), 0.1, comp, comp)
        c.damping = 0.98
        c.fix_point(0)
        c.fix_point(1)
        c.fix_segment(0)
        for _ in range(300):
            c.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
        sags.append(-c.x[20][1])
    print("  cantilever tip sag: bend compliance 1", sags[0], " 0.01", sags[1])
    s.check(sags[1] < sags[0] and sags[0] < 1.0 and sags[1] > 0, "stiffer bending sags less; finite")

    var raised = 0
    try:
        var one: List[Vec3] = [zero]
        _ = CosseratRod(one, 1)
    except:
        raised += 1
    try:
        _ = CosseratRod(straight(Vec3(0, 0, 1, 0)), 0)
    except:
        raised += 1
    try:
        _ = CosseratRod(straight(Vec3(0, 0, 1, 0)), 1, -1, 1)
    except:
        raised += 1
    s.check(raised == 3, "one point, zero mass, negative compliance raise")
    s.finish()
