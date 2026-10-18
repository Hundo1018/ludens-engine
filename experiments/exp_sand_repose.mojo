"""Experiment — angle of repose of the MPM Drucker-Prager sand (ROADMAP 17.58).

A 0.30 x 0.30 x 0.30 m block of sand (10 x 10 x 10 particles at dx 0.05) is
released on an obstacle floor (mu 1.0) and left for 1.5 s. The heap is
summarised by the cone of equal volume and equal outer radius, whose slope is
3 V / (pi R^3). (A fit of the flank line from binned surface heights was tried
first and was too noisy: 5 to 13 degrees for 20 to 50 degrees of friction,
while the heaps are visibly 20 to 30 degree cones.) A low block is used
because a tall column keeps spreading on inertia and ends far below the repose
angle (Lube et al. 2004).

A second table gives the criterion that does not depend on the dynamics: a
cone of slope theta built from particles must stand for theta below the
friction angle and flow for theta above it. Its figure of merit is the peak
height after 1 s over the initial one.

Run: pixi run mojo run -I build experiments/exp_sand_repose.mojo
"""

from std.math import atan2, sqrt, tan
from geometry.vec import Real, Vec3

from geometry.sdf3 import Sdf3
from physics.fem import det3
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime FLOOR: Real = 0.2
comptime SP: Real = 0.03


def _heap(phi: Real, side: Int) raises -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), 1.0)
    m.set_sand(phi)
    var vol = SP * SP * SP
    var o = 0.8 - Real(side) * SP * 0.5
    for i in range(side):
        for j in range(side):
            for k in range(side):
                m.add(
                    Vec3(o + Real(i) * SP, FLOOR + 0.5 * SP + Real(j) * SP, o + Real(k) * SP, 0),
                    vol * 1600.0,
                    vol,
                )
    return m^


def _cone(phi: Real, theta_deg: Real, radius: Real) raises -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), 1.0)
    m.set_sand(phi)
    var vol = SP * SP * SP
    var t = Real(tan(theta_deg * 0.017453292519943295))
    var nxy = Int(radius / SP) + 1
    for i in range(-nxy, nxy + 1):
        for k in range(-nxy, nxy + 1):
            var r = sqrt(Real(i * i + k * k)) * SP
            if r >= radius:
                continue
            var hmax = (radius - r) * t
            var j = 0
            while Real(j + 1) * SP <= hmax:
                m.add(
                    Vec3(0.8 + Real(i) * SP, FLOOR + 0.5 * SP + Real(j) * SP, 0.8 + Real(k) * SP, 0),
                    vol * 1600.0,
                    vol,
                )
                j += 1
    return m^


def _peak(m: MpmSolver) -> Real:
    var t = Real(0)
    for ref q in m.p:
        t = max(t, q.x[1] + 0.5 * SP - FLOOR)
    return t


def _kinetic(m: MpmSolver) -> Real:
    var ke = Real(0)
    for ref q in m.p:
        ke += 0.5 * q.mass * (q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2])
    return ke


def _cone_deg(m: MpmSolver) -> Tuple[Real, Real, Real]:
    """(equal-volume cone angle in degrees, peak height, outer radius): the
    cone of the heap's volume and outer radius has slope 3 V / (pi R^3)."""
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
    var peak = Real(0)
    for ref q in m.p:
        rmax = max(rmax, sqrt((q.x[0] - cx) * (q.x[0] - cx) + (q.x[2] - cz) * (q.x[2] - cz)))
        peak = max(peak, q.x[1] + 0.5 * SP - FLOOR)
    return (atan2(3 * v, 3.141592653589793 * rmax * rmax * rmax) * 57.29577951308232, peak, rmax)


def main() raises:
    print("| friction angle | equal-volume cone angle | peak height (m) | outer radius (m) | KE at 1.5 s / PE released |")
    print("|---:|---:|---:|---:|---:|")
    for phi in [Real(20), Real(30), Real(40), Real(50)]:
        var m = _heap(phi, 10)
        for _ in range(3000):
            m.step_ext(DT, G)
        var r = _cone_deg(m)
        var pe = m.total_mass() * 9.8 * (0.5 * 10 * SP)
        print("|", phi, "|", r[0], "|", r[1], "|", r[2], "|", _kinetic(m) / pe, "|")

    print()
    print("| friction angle | cone slope | peak after 1 s / initial |")
    print("|---:|---:|---:|")
    for dtheta in [Real(-12), Real(6), Real(24)]:
        var phi = Real(35)
        var m = _cone(phi, phi + dtheta, 0.36)
        var p0 = _peak(m)
        for _ in range(2000):
            m.step_ext(DT, G)
        print("|", phi, "|", phi + dtheta, "|", _peak(m) / p0, "|")
