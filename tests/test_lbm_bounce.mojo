# tier: unit
"""Interpolated bounce-back and the second force path (ROADMAP 17.42 b, c).

  seam parity  with no curved solid every link has q = 1/2 and Bouzidi's
               interpolated bounce-back IS half-way bounce-back: a channel
               with box walls evolves bit-identically under both.
  ordinary     a sphere shifted by half a cell: half-way bounce-back sees a
               different staircase and its drag moves by several percent;
               the interpolated wall follows the true surface and moves
               much less.
  integration  the drag from momentum exchange at the boundary links and
               from the momentum flux through a control surface around the
               sphere agree (two independent force paths).
  extreme      a closed periodic box with a sphere keeps its mass (interp
               bounce-back is not exactly conservative: bounded drift); a
               sphere smaller than a cell stays finite.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL, BC_PERIODIC


def _sphere_drag(shift: Real, interp: Bool) -> Tuple[Real, Real]:
    var t = Lbm(48, 24, 24, Real(0.02), BC_TUNNEL)
    t.interp = interp
    t.init_uniform(1.0, 0.05, 0, 0)
    t.inlet_u = 0.05
    t.set_solid_sphere(14 + shift, 11.5 + shift, 11.5, 3.5)
    var avg = Real(0)
    for k in range(900):
        t.step()
        if k >= 800:
            avg += t.fx / 100
    return (avg, t.momentum_flux_force(6, 4, 4, 24, 19, 19)[0])


def main() raises:
    var s = Suite("lbm_bounce")

    # ---- parity: no curved solid -> identical ----------------------------
    var a = Lbm(24, 12, 12, Real(0.03), BC_TUNNEL)
    var b = Lbm(24, 12, 12, Real(0.03), BC_TUNNEL)
    b.interp = True
    for m in [0, 1]:
        ref t = a if m == 0 else b
        t.init_uniform(1.0, 0.04, 0, 0)
        t.inlet_u = 0.04
        t.set_solid_box(Vec3(8, 3, 3, 0), Vec3(11, 8, 8, 0))
    for _ in range(100):
        a.step()
        b.step()
    var same = a.fx == b.fx
    for c in range(len(a.f)):
        if a.f[c] != b.f[c]:
            same = False
    s.check(same, "box solids (q = 1/2 everywhere): interpolated == half-way, bit for bit")

    # ---- ordinary + integration: sphere, sub-cell shift, two force paths --
    var h0 = _sphere_drag(0, False)
    var h5 = _sphere_drag(0.5, False)
    var i0 = _sphere_drag(0, True)
    var i5 = _sphere_drag(0.5, True)
    var spread_h = abs(h5[0] - h0[0]) / ((h5[0] + h0[0]) / 2)
    var spread_i = abs(i5[0] - i0[0]) / ((i5[0] + i0[0]) / 2)
    print("  drag change for a half-cell shift: half-way", spread_h, " interpolated", spread_i)
    s.check(spread_i < spread_h / 2, "interpolated bounce-back is far less sensitive to where the sphere sits in its cell")
    var worst = Real(0)
    for r in [h0, h5, i0, i5]:
        worst = max(worst, abs(r[0] - r[1]) / r[0])
    print("  momentum exchange vs control-surface flux, worst relative difference", worst)
    s.check(worst < 0.03, "the two force paths agree within 3%")

    # ---- extremes -----------------------------------------------------------
    var cl = Lbm(16, 16, 16, Real(0.05), BC_PERIODIC)
    cl.interp = True
    cl.init_uniform(1.0, 0.03, 0.01, 0)
    cl.set_solid_sphere(7.3, 8.1, 7.7, 3.2)
    var m0 = cl.total_mass()
    for _ in range(200):
        cl.step()
    var drift = abs(cl.total_mass() - m0) / m0
    print("  periodic box with an interpolated sphere: relative mass drift", drift)
    s.check(drift < 1e-2, "interpolated bounce-back mass drift stays bounded")
    var tiny = Lbm(16, 12, 12, Real(0.05), BC_TUNNEL)
    tiny.interp = True
    tiny.init_uniform(1.0, 0.05, 0, 0)
    tiny.inlet_u = 0.05
    tiny.set_solid_sphere(6.2, 5.9, 6.1, 0.6)
    for _ in range(100):
        tiny.step()
    s.check(isfinite(tiny.fx) and isfinite(tiny.total_mass()), "a sub-cell sphere stays finite")

    s.finish()
