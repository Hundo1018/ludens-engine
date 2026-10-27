# tier: integration
"""Momentum restoration after semi-Lagrangian advection (ROADMAP 17.61 / 17.60,
`physics.mac_fluid` `MacFluid2.use_momentum_fix`).

The point-drag setup of `test_smoke_drag` (32^2 periodic grid, dx 1/32,
dt 1/120, nu 1e-3, 240 steps = 2 s), at two drag rates. Each step the point
gives the air its lost momentum with `add_impulse`. The air's total momentum
should then change by exactly the total impulse. The semi-Lagrangian advection
does not conserve it, so the default path leaves a residual.

Predictions, written before the run:

  * k = 0.5, default path: relative residual 4.6 % (measured in
    `test_smoke_drag`, same loop). Bound: between 3 % and 6 %, which is the
    reproduction check.
  * k = 5, default path: relative residual above 10 %. The residual grows with
    the speed of the point, so this regime must show it clearly.
  * k = 5 with `use_momentum_fix`: relative residual below 1e-4 (f32
    accumulation over 240 steps and 2 x 1024 faces). The fix shifts every face
    by a constant, so the total is restored exactly up to rounding.

The fix restores only the total. It does not repair the local advection error;
the point velocity field is unchanged by it in the default test, and the
booked correction is printed.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2


def _momentum(f: MacFluid2) -> Tuple[Real, Real]:
    return f.momentum()


def _coupled(k: Real, fix: Bool) raises -> Tuple[Real, Real, Real]:
    """Returns (relative residual, total impulse magnitude, momentum booked)."""
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1) / Real(120)
    var f = MacFluid2(n, dx, Real(1e-3))
    if fix:
        f.use_momentum_fix()
    var xp = Real(0.5)
    var yp = Real(0.5)
    var vpx = Real(1)
    var vpy = Real(0)
    var imp_x = Real(0)
    var imp_y = Real(0)
    var a0 = _momentum(f)
    for _ in range(240):
        var ua = f.velocity(xp, yp)
        var a = k * dt
        var nvx = (vpx + a * ua[0]) / (1 + a)
        var nvy = (vpy + a * ua[1]) / (1 + a)
        var ix = vpx - nvx
        var iy = vpy - nvy
        f.add_impulse(xp, yp, ix, iy)
        imp_x += ix
        imp_y += iy
        vpx = nvx
        vpy = nvy
        xp += vpx * dt
        yp += vpy * dt
        f.step(dt)
    var a1 = _momentum(f)
    var dmx = a1[0] - a0[0]
    var dmy = a1[1] - a0[1]
    var mag = abs(imp_x) + abs(imp_y)
    var rel = (abs(dmx - imp_x) + abs(dmy - imp_y)) / mag
    return (rel, mag, f.momentum_booked)


def main() raises:
    var s = Suite("fluid_momentum")
    var k_soft = Real(0.5)
    var k_hard = Real(5)
    var r_soft = _coupled(k_soft, False)
    var r_hard = _coupled(k_hard, False)
    var r_fix = _coupled(k_hard, True)
    print("  k 0.5 default: residual", r_soft[0], " k 5 default:", r_hard[0], " k 5 fixed:", r_fix[0], " booked", r_fix[2], " impulse", r_fix[1])
    s.check(r_soft[0] > 0.03 and r_soft[0] < 0.06, "default path reproduces the 4.6 % residual at k = 0.5")
    s.check(r_hard[0] > 0.10, "default path leaves a residual above 10 % at k = 5")
    s.check(r_fix[0] < 1e-4, "with the momentum fix, the total change matches the impulse to 1e-4 at k = 5")
    s.finish()
