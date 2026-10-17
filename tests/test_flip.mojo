# tier: integration
"""FLIP free-surface water with walls (ROADMAP 17.60, `physics.flip`).

  1. Ordinary: still water, 0.3 m deep in a 1 m box (40 x 24 cells of
     2.5 cm), stays at rest for 1 s (particle speeds < 1e-5 m/s) with a
     hydrostatic pressure p / rho = g (0.3 + dx/2 - y) at every water cell
     centre within 1e-4 g -- the free surface sits at the first air cell's
     centre, half a cell above the water (first-order p = 0).
  2. Integration (dam break): a 0.25 x 0.5 m column released in a 2 m box
     runs out along the floor behind Ritter's inviscid shallow-water front
     x = 0.25 + 2 sqrt(g h0) t at every sampled time, at a speed (between
     0.3 and 0.5 s) of 1.2 to 2 sqrt(g h0) (1.5 measured; real dam
     breaks run below Ritter's 2), and every particle stays in the box;
     the pressure solves converge.
  3. Extreme: fewer than 2 cells per axis, dx <= 0 and dt <= 0 raise; an
     empty box steps (nothing to solve).
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.flip import FlipWater2

comptime G: Real = 9.8


def main() raises:
    var s = Suite("flip")
    var w = FlipWater2(40, 24, 0.025)
    w.fill_box(0, 0, 1.0, 0.3)
    var n0 = w.count()
    var t = Real(0)
    while t < 1.0:
        var dt = min(Real(0.005), w.max_dt())
        w.step(dt)
        t += dt
    var vmax = Real(0)
    for k in range(w.count()):
        vmax = max(vmax, abs(w.pu[k]) + abs(w.pv[k]))
    var perr = Real(0)
    for j in range(12):
        var y = (Real(j) + 0.5) * 0.025
        perr = max(perr, abs(w.pressure(20, j) / G - (0.3 + 0.0125 - y)))
    print("  still tank 1 s:", n0, "particles, max speed", vmax, " worst |p/g - (h + dx/2 - y)|", perr)
    s.check(vmax < 1e-5 and perr < 1e-4 and w.count() == n0, "still water stays still, hydrostatic")

    var d = FlipWater2(80, 24, 0.025)
    d.fill_box(0, 0, 0.25, 0.5)
    var c0 = Real(sqrt(G * 0.5))
    t = 0
    var k = 0
    var behind = True
    var conv = True
    var f03 = Real(0)
    var f05 = Real(0)
    while t < 0.5 - 1e-6:
        var dt = min(Real(0.004), d.max_dt())
        dt = min(dt, 0.5 - t)
        d.step(dt)
        t += dt
        k += 1
        conv = conv and d.last.converged
        var front = Real(0)
        for q in range(d.count()):
            front = max(front, d.px[q])
        behind = behind and front < 0.25 + 2 * c0 * t
        if f03 == 0 and t >= 0.3:
            f03 = front
    for q in range(d.count()):
        f05 = max(f05, d.px[q])
    var inside = True
    for q in range(d.count()):
        inside = inside and d.px[q] > 0 and d.px[q] < 2.0 and d.py[q] > 0 and d.py[q] < 0.6
    var speed = (f05 - f03) / 0.2 / c0
    print("  dam break 0.25 x 0.5 m: front at 0.3 s", f03, " 0.5 s", f05, " speed / sqrt(g h0)", speed, " (Ritter 2)")
    s.check(behind and speed > 1.2 and speed < 2.0 and inside and conv, "the dam-break front runs behind Ritter's, at 1.2 to 2 sqrt(g h0)")

    var raised = 0
    try:
        _ = FlipWater2(1, 4, 0.1)
    except:
        raised += 1
    try:
        _ = FlipWater2(4, 4, 0)
    except:
        raised += 1
    var e = FlipWater2(4, 4, 0.1)
    try:
        e.step(0)
    except:
        raised += 1
    e.step(0.01)
    s.check(raised == 3 and e.count() == 0, "bad sizes / dt raise; an empty box steps")
    s.finish()
