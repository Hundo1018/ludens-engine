# tier: integration
"""3-D FLIP water (ROADMAP 17.60, `physics.flip3.FlipWater3`).

  1. Ordinary: a 1 x 0.3 x 0.3 m pool in a 20 x 12 x 6 box (dx 5 cm) stays
     still for 0.5 s (max particle speed < 1e-5 m/s) and its pressure is
     hydrostatic, p / g = h + dx/2 - y in the middle column within 1e-4.
  2. Integration (parity with 2-D): the 0.25 x 0.5 m dam break of
     test_flip in a slab two cells thick (80 x 24 x 2, dx 2.5 cm): every
     pressure solve converges, the front stays behind Ritter's
     2 sqrt(g h0) t, and at 0.5 s it is within 5 % of the 2-D solver's.
     Measured: the slab's front equals the 2-D one bit for bit (no motion
     along z, so the 3-D solver reduces to the 2-D one). Genuinely 3-D: a
     0.3 x 0.6 x 0.3 m column in the corner of a square 1.2 m tank spreads
     along x and z alike (fronts within one cell after 0.4 s, by symmetry).
  3. Extreme: fewer than 2 cells on an axis or dx <= 0 raises; particles
     stay inside the box.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.flip import FlipWater2
from physics.flip3 import FlipWater3

comptime G: Real = 9.8


def main() raises:
    var s = Suite("flip3")
    var w = FlipWater3(20, 12, 6, 0.05)
    w.fill_box(0, 0, 0, 1.0, 0.3, 0.3)
    var n0 = w.count()
    var t = Real(0)
    while t < 0.5:
        var dt = min(Real(0.01), w.max_dt())
        w.step(dt)
        t += dt
    var vmax = Real(0)
    for k in range(w.count()):
        vmax = max(vmax, abs(w.pu[k]) + abs(w.pv[k]) + abs(w.pw[k]))
    var perr = Real(0)
    for j in range(6):
        var y = (Real(j) + 0.5) * 0.05
        perr = max(perr, abs(w.pressure(10, j, 3) / G - (0.3 + 0.025 - y)))
    print("still pool 0.5 s:", n0, "particles, max speed", vmax, " worst |p/g - (h + dx/2 - y)|", perr)
    s.check(vmax < 1e-5 and perr < 1e-4 and w.count() == n0, "still water stays still, hydrostatic")

    var d3 = FlipWater3(80, 24, 2, 0.025)
    d3.fill_box(0, 0, 0, 0.25, 0.5, 0.05)
    var d2 = FlipWater2(80, 24, 0.025)
    d2.fill_box(0, 0, 0.25, 0.5)
    var c0 = Real(sqrt(G * 0.5))
    t = 0
    var behind = True
    var conv = True
    while t < 0.5 - 1e-6:
        var dt = min(Real(0.004), min(d3.max_dt(), d2.max_dt()))
        dt = min(dt, 0.5 - t)
        d3.step(dt)
        d2.step(dt)
        t += dt
        conv = conv and d3.last.converged
        var f = Real(0)
        for q in range(d3.count()):
            f = max(f, d3.px[q])
        behind = behind and f < 0.25 + 2 * c0 * t
    var f3 = Real(0)
    var f2 = Real(0)
    var inside = True
    for q in range(d3.count()):
        f3 = max(f3, d3.px[q])
        inside = inside and d3.px[q] > 0 and d3.px[q] < 2.0 and d3.py[q] > 0 and d3.py[q] < 0.6 and d3.pz[q] > 0 and d3.pz[q] < 0.05
    for q in range(d2.count()):
        f2 = max(f2, d2.px[q])
    print("dam break slab 0.5 s: front 3-D", f3, " 2-D", f2, " ratio", f3 / f2)
    s.check(conv and behind and abs(f3 / f2 - 1) < 0.05 and inside, "the slab dam break follows the 2-D front (5 %), behind Ritter, converged, inside")

    var cc = FlipWater3(24, 16, 24, 0.05)
    cc.fill_box(0, 0, 0, 0.3, 0.6, 0.3)
    t = 0
    while t < 0.4 - 1e-6:
        var dt = min(Real(0.005), cc.max_dt())
        dt = min(dt, 0.4 - t)
        cc.step(dt)
        t += dt
    var fx = Real(0)
    var fz = Real(0)
    for q in range(cc.count()):
        fx = max(fx, cc.px[q])
        fz = max(fz, cc.pz[q])
    print("corner column 0.4 s: front along x", fx, " along z", fz)
    s.check(abs(fx - fz) < 0.05 and fx > 0.5, "the corner column spreads along x and z alike")

    var raised = 0
    try:
        _ = FlipWater3(1, 4, 4, 0.1)
    except:
        raised += 1
    try:
        _ = FlipWater3(4, 4, 4, 0)
    except:
        raised += 1
    s.check(raised == 2, "a degenerate grid raises")
    s.finish()
