# tier: integration
"""Two-way drag coupling of a square to the 2-D grid gas (ROADMAP 17.61,
`physics.mac_body.DragBody2` with `square_samples`).

Same setup as `test_body_drag` (32^2 periodic grid, dx 1/32, dt 1/120, nu 1e-3,
kappa 20 /s, density 2, gravity 1, gas friction gamma 1 /s booked as a sink),
with a square of half side 4 dx (64 cells, side 0.25 m) in place of the disk.
The square is still a set of cell-centred points; it does not block grid faces.

Bounds are the disk test's bounds, fixed before the run:

  1. One coupling step from rest: momentum error below 1e-6.
  2. Over 8 s of fall, body + gas + sink momentum equals -m g t to 10 %.
  3. Steady fall: speed change over the last 0.5 s below 1 %.
  4. Steady force balance: drag / weight within 5 % of 1.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_body import DragBody2, square_samples
from physics.mac_fluid import MacFluid2


def _gas_momentum(f: MacFluid2) -> Tuple[Real, Real]:
    var sx = Real(0)
    var sy = Real(0)
    for k in range(len(f.u)):
        sx += f.u[k]
        sy += f.v[k]
    return (sx * f.dx * f.dx, sy * f.dx * f.dx)


def _friction(mut f: MacFluid2, dt: Real, gamma: Real) -> Tuple[Real, Real]:
    """Applies -gamma u to every face and returns the momentum it removed."""
    var p = _gas_momentum(f)
    var keep = 1 - gamma * dt
    for k in range(len(f.u)):
        f.u[k] *= keep
        f.v[k] *= keep
    return (p[0] * gamma * dt, p[1] * gamma * dt)


def main() raises:
    var s = Suite("body_square")
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1) / Real(120)
    var kappa = Real(20)
    var gamma = Real(1)
    var g = Real(1)
    var density = Real(2)
    var samples = square_samples(4 * dx, dx)
    var count = len(samples[0])
    var area = dx * dx
    var mass = density * Real(count) * area

    # 1. One step from rest: the body impulse equals the gas momentum loss.
    var f1 = MacFluid2(n, dx, Real(1e-3))
    var b1 = DragBody2(samples[0].copy(), samples[1].copy(), area, mass, kappa, Real(0.5), Real(0.5))
    var g0 = _gas_momentum(f1)
    b1.couple(f1, dt, g)
    var g1 = _gas_momentum(f1)
    var ex = abs((g1[0] - g0[0]) + mass * b1.vx)
    var ey = abs((g1[1] - g0[1]) + mass * (b1.vy + g * dt))
    var e1 = max(ex, ey)
    print("  one step: samples", count, " momentum error", e1)
    s.check(e1 < 1e-6, "square: one coupling step conserves body plus gas momentum to 1e-6")

    # 2 to 4. Eight seconds of falling, then the steady-state balance.
    var f = MacFluid2(n, dx, Real(1e-3))
    var b = DragBody2(samples[0].copy(), samples[1].copy(), area, mass, kappa, Real(0.5), Real(0.5))
    var sink_x = Real(0)
    var sink_y = Real(0)
    var steps = 960
    var v_mid = Real(0)
    for step in range(steps):
        b.couple(f, dt, g)
        f.step(dt)
        var removed = _friction(f, dt, gamma)
        sink_x += removed[0]
        sink_y += removed[1]
        if step == steps - 60:
            v_mid = sqrt(b.vx * b.vx + b.vy * b.vy)
    var t = Real(steps) * dt
    var gp = _gas_momentum(f)
    var book_x = mass * b.vx + gp[0] + sink_x
    var book_y = mass * b.vy + gp[1] + sink_y
    var want_y = -mass * g * t
    var rel = (abs(book_x) + abs(book_y - want_y)) / abs(want_y)
    var speed = sqrt(b.vx * b.vx + b.vy * b.vy)
    var steady = abs(speed - v_mid) / speed
    var us = Real(0)
    for k in range(count):
        us += f.velocity(b.x + b.ox[k], b.y + b.oy[k])[1]
    us /= Real(count)
    var balance = kappa * area * Real(count) * (-b.vy + us) / (mass * g)
    print("  8 s fall: body vy", b.vy, " gas vy at samples", us, " rho g / kappa", density * g / kappa)
    print("  momentum book residual (relative to m g t)", rel, " speed change over last 0.5 s", steady, " drag / weight", balance)
    s.check(rel < 0.10, "body plus gas plus sink momentum matches -m g t within 10 %")
    s.check(steady < 0.01, "the body reaches a steady fall: speed changes by under 1 % over 0.5 s")
    s.check(abs(balance - 1) < 0.05, "at steady fall the drag balances the weight within 5 %")
    s.finish()
