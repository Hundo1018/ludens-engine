# tier: component
"""Two-way point drag on the 2-D grid gas (ROADMAP 17.61, `physics.mac_fluid`
`MacFluid2.add_impulse`).

A point of unit mass moves through quiescent air on a 32^2 periodic grid
(dx 1/32, dt 1/120, nu 1e-3). Each step it is dragged toward the local air
velocity with an implicit rate k (k = 0.5 /s), and the impulse it loses is
given to the air with `add_impulse`. Run for 2 s.

Checks, with bounds written before the run:

  1. One impulse changes the total momentum sum(u) dx^2 by exactly the
     impulse (tolerance 1e-6 in f32).
  2. Over the 2 s run, the air's momentum change matches the total impulse
     to 10 %. The bound is for this regime only: the semi-Lagrangian advection
     in `MacFluid2` does not conserve momentum, and the error grows with the
     speed (k = 5, impulse 8.5, drifts by 20 at the same grid). Measured here:
     4.6 %.
  3. The point slows: its final speed is below its initial speed of 1 m/s.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2


def _momentum(f: MacFluid2) -> Tuple[Real, Real]:
    var sx = Real(0)
    var sy = Real(0)
    for k in range(len(f.u)):
        sx += f.u[k]
        sy += f.v[k]
    return (sx * f.dx * f.dx, sy * f.dx * f.dx)


def main() raises:
    var s = Suite("smoke_drag")
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1) / Real(120)
    var f = MacFluid2(n, dx, Real(1e-3))

    var m0 = _momentum(f)
    f.add_impulse(Real(0.5), Real(0.5), Real(0.25), Real(-0.125))
    var m1 = _momentum(f)
    var e1 = max(abs((m1[0] - m0[0]) - Real(0.25)), abs((m1[1] - m0[1]) + Real(0.125)))
    print("  single impulse: momentum change error", e1)
    s.check(e1 < 1e-6, "one impulse changes the total momentum by exactly the impulse")

    var f2 = MacFluid2(n, dx, Real(1e-3))
    var k = Real(0.5)
    var xp = Real(0.5)
    var yp = Real(0.5)
    var vpx = Real(1)
    var vpy = Real(0)
    var imp_x = Real(0)
    var imp_y = Real(0)
    var a0 = _momentum(f2)
    for _ in range(240):
        var ua = f2.velocity(xp, yp)
        var a = k * dt
        var nvx = (vpx + a * ua[0]) / (1 + a)
        var nvy = (vpy + a * ua[1]) / (1 + a)
        var ix = vpx - nvx
        var iy = vpy - nvy
        f2.add_impulse(xp, yp, ix, iy)
        imp_x += ix
        imp_y += iy
        vpx = nvx
        vpy = nvy
        xp += vpx * dt
        yp += vpy * dt
        f2.step(dt)
    var a1 = _momentum(f2)
    var dmx = a1[0] - a0[0]
    var dmy = a1[1] - a0[1]
    var rel = (abs(dmx - imp_x) + abs(dmy - imp_y)) / (abs(imp_x) + abs(imp_y))
    print("  2 s coupled: impulse", imp_x, imp_y, " air momentum change", dmx, dmy, " relative residual", rel, " point speed", vpx)
    s.check(rel < 0.10, "air momentum change matches the impulse within 10 %")
    s.check(vpx * vpx + vpy * vpy < 1, "the point slows toward the quiescent air")
    s.finish()
