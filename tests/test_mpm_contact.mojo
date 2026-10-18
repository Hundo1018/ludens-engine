# tier: component
"""MPM obstacle contact does not depend on where the floor falls between grid
nodes (ROADMAP 17.58). The grid is 0.05 m; the floor top is moved by up to a
cell around the node plane at 0.2 m.

  1. A 0.18 x 0.12 x 0.18 m elastic block given 2 m/s on a mu 0.6 floor slides
     v^2 / (2 mu g) = 0.340 m. With floor tops 0.19, 0.2125, 0.225, 0.2375 and
     0.2 m the distance stays within 5 % of that (measured 0.3385 to 0.3394 m with node_margin 3 dx / 4; 0.329 to 0.339 m with dx / 2).
     When only nodes strictly inside the obstacle were projected the same
     block slid 0.444 m at 0.19 and 0.310 m at 0.2375.
  2. A 0.24 m block of sand (20 degrees of friction, floor mu 1) settles to a
     heap whose equal-volume cone is the same for floor tops 0.19, 0.2 and
     0.2375 m (measured 22.9, 24.6, 24.7 degrees; under two degrees of spread). With
     only inside-node projection it spread to a 2 degree film at 0.19 and
     0.2375 m.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from geometry.sdf3 import Sdf3
from std.math import atan2, sqrt
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime SP: Real = 0.03


def _slide(floor: Real) raises -> Real:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, floor, 1.0, 0)), 0.6)
    var vol = SP * SP * SP
    for i in range(6):
        for j in range(4):
            for k in range(6):
                m.add(Vec3(0.3 + Real(i) * SP, floor + 0.015 + Real(j) * SP, 0.68 + Real(k) * SP, 0), vol * 1600.0, vol)
    for _ in range(800):
        m.step_ext(DT, G)
    var x0 = Real(0)
    for ref q in m.p:
        x0 += q.x[0]
    x0 /= Real(m.count())
    for pi in range(m.count()):
        m.p[pi].v = Vec3(2, m.p[pi].v[1], 0, 0)
    for _ in range(1200):
        m.step_ext(DT, G)
    var x1 = Real(0)
    for ref q in m.p:
        x1 += q.x[0]
    return x1 / Real(m.count()) - x0


def _det(f: Mat3) -> Real:
    return (
        f.get(0, 0) * (f.get(1, 1) * f.get(2, 2) - f.get(1, 2) * f.get(2, 1))
        - f.get(0, 1) * (f.get(1, 0) * f.get(2, 2) - f.get(1, 2) * f.get(2, 0))
        + f.get(0, 2) * (f.get(1, 0) * f.get(2, 1) - f.get(1, 1) * f.get(2, 0))
    )


def _heap(floor: Real) raises -> Real:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, floor, 1.0, 0)), 1.0)
    m.set_sand(20)
    var vol = SP * SP * SP
    for i in range(8):
        for j in range(8):
            for k in range(8):
                m.add(Vec3(0.68 + Real(i) * SP, floor + 0.015 + Real(j) * SP, 0.68 + Real(k) * SP, 0), vol * 1600.0, vol)
    for _ in range(3000):
        m.step_ext(DT, G)
    var cx = Real(0)
    var cz = Real(0)
    var v = Real(0)
    for ref q in m.p:
        cx += q.x[0]
        cz += q.x[2]
        v += q.vol * _det(q.f)
    cx /= Real(m.count())
    cz /= Real(m.count())
    var rmax = Real(0)
    for ref q in m.p:
        rmax = max(rmax, sqrt((q.x[0] - cx) * (q.x[0] - cx) + (q.x[2] - cz) * (q.x[2] - cz)))
    return atan2(3 * v, 3.141592653589793 * rmax * rmax * rmax) * 57.29577951308232


def main() raises:
    var s = Suite("mpm_contact")
    var worst = Real(0)
    var line = String("")
    for fl in [Real(0.2), Real(0.19), Real(0.2125), Real(0.225), Real(0.2375)]:
        var d = _slide(fl)
        worst = max(worst, abs(d - 0.340))
        line += String(fl) + " -> " + String(d) + "; "
    print("  slide with mu 0.6 by floor top (Coulomb 0.340):", line)
    s.check(worst < 0.05 * 0.340, "the sliding distance matches Coulomb within 5 % at every floor height")
    var a = _heap(0.2)
    var b = _heap(0.19)
    var c = _heap(0.2375)
    print("  heap cone angle at 20 degrees of friction, floor top 0.2 / 0.19 / 0.2375 m:", a, b, c)
    s.check(abs(b - a) < 3 and abs(c - a) < 3, "the heap angle does not depend on the floor height (within 3 degrees)")
    s.check(a > 15 and b > 15 and c > 15 and a < 26 and b < 26 and c < 26, "and it is a cone near the 20 degree friction angle")
    s.finish()
