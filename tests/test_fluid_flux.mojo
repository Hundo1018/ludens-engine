# tier: integration
"""Flux-form (conservative) advection on `MacFluid2` (ROADMAP 17.61,
`MacFluid2.use_flux_advection`, first-order upwind finite volume).

The point-drag setup of `test_fluid_momentum` (32^2 periodic grid, dx 1/32,
dt 1/120, nu 1e-3, 240 steps = 2 s) at two drag rates. A point gives the air
momentum with `add_impulse` each step; the air's total momentum should then
change by exactly the total impulse.

CFL: the point's own speed (1 m/s, so 0.27) is the wrong number to check. The
fluid's face speed is what the upwind update sees, and the point impulse
produces face speeds far above the point's. A first attempt with one explicit
step per dt went to NaN at k = 5 within 3 steps (face speed 1075 m/s, against
dx / dt = 3.75). `_advect_flux` therefore sub-cycles: ceil(2 |u|max dt / dx)
sub-steps per step. Every sub-step is still a conservative flux update.

Predictions, written before the run:

  * k = 5, flux path, no momentum fix: relative residual below 1e-4. Flux
    form conserves the total by construction (each side's flux is computed
    once and enters its neighbour), so the total change equals the impulse up
    to f32 accumulation.
  * momentum_booked is exactly 0 on the flux path: no correction was applied.
    This is the discriminating check. The semi-Lagrangian path with
    `use_momentum_fix` reaches the same total by booking a correction
    (2.3e2 in the 17.61 measurement); flux form reaches it with none.
  * k = 0.5, flux path: relative residual below 1e-4 as well.
  * Kinetic energy at k = 5 is printed for the semi-Lagrangian and flux paths.
    No bound is committed: first-order upwind is diffusive, so its energy is
    expected to be lower, and the size of the gap is what the run records.

Measured (one run): k 5 flux residual 9.3e-8, booked 0; k 0.5 flux residual
8.0e-8. All three checks pass. Kinetic energy at k = 5: flux 3.53,
semi-Lagrangian 80.97. The semi-Lagrangian figure is not a reference: its face
speeds reach 130 m/s in this setup (the point impulse makes local speeds far
above the point's own), so its energy is inflated, and the flux figure is
diffusive by construction. The ratio is recorded, not used as a bound.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2


def _ke(f: MacFluid2) -> Real:
    var e = Real(0)
    for k in range(f.n * f.n):
        e += 0.5 * (f.u[k] * f.u[k] + f.v[k] * f.v[k])
    return e * f.dx * f.dx


def _coupled(k: Real, flux: Bool) raises -> Tuple[Real, Real, Real]:
    """Returns (relative residual, total impulse magnitude, kinetic energy at
    the end). The momentum_booked count is read from the fluid by the caller."""
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1) / Real(120)
    var f = MacFluid2(n, dx, Real(1e-3))
    if flux:
        f.use_flux_advection()
    var xp = Real(0.5)
    var yp = Real(0.5)
    var vpx = Real(1)
    var vpy = Real(0)
    var imp_x = Real(0)
    var imp_y = Real(0)
    var a0 = f.momentum()
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
    var a1 = f.momentum()
    var dmx = a1[0] - a0[0]
    var dmy = a1[1] - a0[1]
    var mag = abs(imp_x) + abs(imp_y)
    var rel = (abs(dmx - imp_x) + abs(dmy - imp_y)) / mag
    if flux:
        print("  flux k", k, " booked", f.momentum_booked)
    return (rel, f.momentum_booked, _ke(f))


def main() raises:
    var s = Suite("fluid_flux")
    var f5 = _coupled(Real(5), True)
    var f05 = _coupled(Real(0.5), True)
    var sl5 = _coupled(Real(5), False)
    print("  k 5 flux residual", f5[0], " booked", f5[1], " KE flux", f5[2], " | k 0.5 flux residual", f05[0], " | k 5 semi-Lagrangian KE", sl5[2])
    s.check(f5[0] < 1e-4, "flux form at k = 5 conserves the total to 1e-4 with no fix")
    s.check(f5[1] == 0, "flux path books no momentum correction at k = 5")
    s.check(f05[0] < 1e-4, "flux form at k = 0.5 conserves the total to 1e-4")
    s.finish()
