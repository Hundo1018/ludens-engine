"""Experiment — Tampubolon volume correction on the MPM Drucker-Prager sand (ROADMAP 17.58).

Each friction angle (30, 60, 85 degrees) is run with `volume_correction` off
and on, on the scenarios of `tests/test_mpm_sand.mojo`:

  column  an 8 x 14 x 8 block on the obstacle floor (mu 0.6), 600 steps; the
          top height above the floor and the x spread of the particles.
  heap    an 8 x 8 x 8 block released on a mu 1.0 floor, 3000 steps; the
          equal-volume cone angle (slope 3 V / (pi R^3)) in degrees.

The same scenario with the flag off is the control: it must reproduce the
numbers `test_mpm_sand` prints. A negative result (the flag changes nothing,
or moves the wrong way) is recorded as measured.
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
comptime FLOOR: Real = 0.2


def _block(mut m: MpmSolver, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int):
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0), vol * 1600.0, vol)


def _solver(mu: Real, phi: Real, vc_on: Bool) raises -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), mu)
    m.set_sand(phi)
    m.volume_correction = vc_on
    return m^


def _det(f: Mat3) -> Real:
    return (
        f.get(0, 0) * (f.get(1, 1) * f.get(2, 2) - f.get(1, 2) * f.get(2, 1))
        - f.get(0, 1) * (f.get(1, 0) * f.get(2, 2) - f.get(1, 2) * f.get(2, 0))
        + f.get(0, 2) * (f.get(1, 0) * f.get(2, 1) - f.get(1, 1) * f.get(2, 0))
    )


def _column(phi: Real, vc_on: Bool) raises -> Tuple[Real, Real]:
    """(top height above the floor, x spread) after 0.3 s."""
    var m = _solver(0.6, phi, vc_on)
    _block(m, 0.68, FLOOR + 0.015, 0.68, 8, 14, 8)
    for _ in range(600):
        m.step_ext(DT, G)
    var t = Real(-1e30)
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for ref q in m.p:
        t = max(t, q.x[1])
        lo = min(lo, q.x[0])
        hi = max(hi, q.x[0])
    return (t - FLOOR, hi - lo)


def _heap(phi: Real, vc_on: Bool) raises -> Real:
    """Equal-volume cone angle in degrees after 1.5 s."""
    var m = _solver(1.0, phi, vc_on)
    _block(m, 0.8 - 0.12, FLOOR + 0.015, 0.8 - 0.12, 8, 8, 8)
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
    var s = Suite("exp_sand_volume_correction")
    for phi in [Real(30), Real(60), Real(85)]:
        var off = _column(phi, False)
        var on = _column(phi, True)
        print("  column friction", phi, "deg: top off", off[0], "on", on[0], "| spread off", off[1], "on", on[1])
        var c_off = _heap(phi, False)
        var c_on = _heap(phi, True)
        print("  heap cone friction", phi, "deg: off", c_off, "on", c_on)
        s.check(on[0] > 0 and on[1] > 0 and c_on > 0, "phi " + String(phi) + ": both runs finite")
    s.finish()
