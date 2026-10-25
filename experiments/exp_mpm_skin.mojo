"""Experiment — MPM contact skin and node margin (ROADMAP 17.58 'not done':
the skin dx/4 and node range dx/2 are fixed ratios).

A 0.18 x 0.12 x 0.18 m elastic block settles on a mu 0.6 floor, is given
2 m/s, and slides; ideal distance v^2 / (2 mu g) = 0.340 m. Floor tops 0.19,
0.2, 0.2125, 0.225, 0.2375 m on a 0.05 m grid. Per (skin, node margin), in
fractions of dx: worst slide-distance error over the floor tops, and the
resting gap (lowest particle centre minus the floor top, over the floor tops:
min / max). The particle bottom layer sits 0.015 m above the floor when the
contact is exact.

Run: pixi run mojo run -I build experiments/exp_mpm_skin.mojo
"""

from std.math import abs, atan2, sqrt
from physics.fem import det3
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime SP: Real = 0.03


def _run(floor: Real, skin: Real, margin: Real) raises -> Tuple[Real, Real]:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.skin = skin * DX
    m.node_margin = margin * DX
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, floor, 1.0, 0)), 0.6)
    var vol = SP * SP * SP
    for i in range(6):
        for j in range(4):
            for k in range(6):
                m.add(Vec3(0.3 + Real(i) * SP, floor + 0.015 + Real(j) * SP, 0.68 + Real(k) * SP, 0), vol * 1600.0, vol)
    for _ in range(800):
        m.step_ext(DT, G)
    var gap = Real(1)
    for ref q in m.p:
        gap = min(gap, q.x[1] - floor)
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
    return (x1 / Real(m.count()) - x0, gap)


def _heap(floor: Real, margin: Real) raises -> Real:
    """Equal-volume cone angle (degrees) of an 8^3-particle sand block, 20
    degrees of friction, floor mu 1, after 1.5 s."""
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.node_margin = margin * DX
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
        v += q.vol * det3(q.f)
    cx /= Real(m.count())
    cz /= Real(m.count())
    var rmax = Real(0)
    for ref q in m.p:
        rmax = max(rmax, sqrt((q.x[0] - cx) * (q.x[0] - cx) + (q.x[2] - cz) * (q.x[2] - cz)))
    return atan2(3 * v, 3.141592653589793 * rmax * rmax * rmax) * 57.29577951308232


def main() raises:
    print("| skin / dx | node margin / dx | worst slide error (%) | rest gap min (mm) | rest gap max (mm) |")
    print("|---:|---:|---:|---:|---:|")
    for skin in [Real(0.125), Real(0.25), Real(0.5)]:
        for margin in [Real(0.5), Real(0.75), Real(1.0)]:
            var worst = Real(0)
            var gmin = Real(1)
            var gmax = Real(0)
            for floor in [Real(0.19), Real(0.2), Real(0.2125), Real(0.225), Real(0.2375)]:
                var r = _run(floor, skin, margin)
                worst = max(worst, abs(r[0] - 0.340) / 0.340 * 100)
                gmin = min(gmin, r[1])
                gmax = max(gmax, r[1])
            print("|", skin, "|", margin, "|", worst, "|", gmin * 1000, "|", gmax * 1000, "|")

    print()
    print("| node margin / dx | cone angle at floor top 0.19 / 0.2 / 0.2375 m (degrees, phi 20) |")
    print("|---:|---|")
    for margin in [Real(0.5), Real(0.75), Real(1.0)]:
        print("|", margin, "|", _heap(0.19, margin), _heap(0.2, margin), _heap(0.2375, margin), "|")
