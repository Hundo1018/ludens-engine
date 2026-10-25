# tier: integration
"""Nonlinear shallow water, finite volume (ROADMAP 17.60,
`physics.water.ShallowWaterFV`).

  1. Ordinary (Stoker's wet dam break): a 400 m channel of 1 m cells, depth
     1 m left of x = 200 and 0.5 m right of it, after 20 s: the plateau
     between the rarefaction and the bore matches Stoker's analytic depth
     h_m and velocity u_m (solved here by bisection) within 2 % and the
     bore's position within 4 cells (first-order Rusanov smears it, so it
     is located where h crosses (h_m + h_R) / 2). Volume is conserved to
     1e-5 (reflective walls).
  2. Integration (Ritter's dry dam break, h_R = 0): after 10 s the depth
     crosses h_L / 4 near where Ritter's profile (2 sqrt(g h_L) - x/t)^2 / 9g
     does: 2.7 m off with 1 m cells (first-order smearing), and the error
     shrinks by more than 1.5x with 0.5 m cells (asserted; 1.66 m
     measured); the thin tip
     lags further (1 mm reached at 246 m against 259.6 with 1 m cells,
     printed: the known lag of first-order schemes at a dry front). A lake at rest
     stays exactly at rest; the surface works through `WaterSurface`
     (height = bed + h, velocity = depth-averaged u).
  3. Extreme: dt past `max_dt` and a zero-size grid raise; a dry grid
     stays dry.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.water import ShallowWaterFV

comptime G: Real = 9.8


def _stoker(hl: Real, hr: Real) -> Tuple[Real, Real, Real]:
    """(h_m, u_m, bore speed) for a wet dam break."""
    var lo = hr
    var hi = hl
    for _ in range(100):
        var hm = 0.5 * (lo + hi)
        var u_raref = 2 * (sqrt(G * hl) - sqrt(G * hm))
        var u_shock = (hm - hr) * sqrt(G * (hm + hr) / (2 * hm * hr))
        if u_raref > u_shock:
            lo = hm
        else:
            hi = hm
    var hm = 0.5 * (lo + hi)
    var um = 2 * (sqrt(G * hl) - sqrt(G * hm))
    return (hm, um, hm * um / (hm - hr))


def _channel(hr: Real) raises -> ShallowWaterFV:
    var w = ShallowWaterFV(400, 1, 1.0, 0, 0, 0, G)
    for i in range(400):
        w.h[i] = 1.0 if i < 200 else hr
    return w^


def _run(mut w: ShallowWaterFV, secs: Real) raises:
    var t = Real(0)
    while t < secs:
        var dt = min(w.max_dt(), secs - t)
        w.step(dt)
        t += dt


def main() raises:
    var s = Suite("shallow_fv")
    var st = _stoker(1.0, 0.5)
    var w = _channel(0.5)
    var v0 = w.total_volume()
    _run(w, 20)
    # plateau: just behind the bore, ahead of the rarefaction tail
    var xs = 200 + st[2] * 20
    var probe = Int(xs) - 12
    var hm = w.h[probe]
    var um = w.hu[probe] / w.h[probe]
    var cross = -1
    for i in range(200, 400):
        if w.h[i] < 0.5 * (st[0] + 0.5):
            cross = i
            break
    print("  Stoker 1 / 0.5 m, 20 s: plateau h", hm, "u", um, " analytic", st[0], st[1], ";  bore at", cross, " analytic", xs, ";  volume", v0, "->", w.total_volume())
    s.check(abs(hm / st[0] - 1) < 0.02 and abs(um / st[1] - 1) < 0.02, "plateau depth and velocity as Stoker's (2 %)")
    s.check(abs(Real(cross) - xs) < 4 and abs(w.total_volume() / v0 - 1) < 1e-5, "bore position within 4 cells; volume conserved")

    var errs = List[Real]()
    var tips = List[Real]()
    var c0 = sqrt(G * 1.0)
    var want_q = 200 + 0.5 * c0 * 10  # h = (2 c0 - x / t)^2 / (9 g) = h0 / 4
    var want_f = 200 + (2 * c0 - 3 * sqrt(G * 1e-3)) * 10  # where h = 1 mm
    for cells in [400, 800]:
        var dx = Real(400) / Real(cells)
        var d = ShallowWaterFV(cells, 1, dx, 0, 0, 0, G)
        for i in range(cells):
            d.h[i] = 1.0 if Real(i) * dx < 200 else Real(0)
        _run(d, 10)
        var front = Real(0)
        var quarter = Real(-1)
        for i in range(cells // 2, cells):
            if d.h[i] > 1e-3:
                front = (Real(i) + 0.5) * dx
            if quarter < 0 and d.h[i] < 0.25:
                # between the centres of cells i - 1 and i
                var a = (d.h[i - 1] - 0.25) / (d.h[i - 1] - d.h[i])
                quarter = (Real(i) - 0.5 + a) * dx
        errs.append(abs(quarter - want_q))
        tips.append(front)
        print("  Ritter dry dam break, 10 s,", dx, "m cells: quarter-depth point at", quarter, " analytic", want_q, ";  1 mm tip at", front, " analytic", want_f)
    s.check(errs[1] < errs[0] / 1.5 and errs[0] < 0.05 * (want_f - 200), "the Ritter profile at quarter depth converges with the cell size")

    var lake = ShallowWaterFV(16, 16, 0.5, 0, 0, -2, G)
    for k in range(256):
        lake.h[k] = 2
    for _ in range(50):
        lake.step(lake.max_dt())
    var moved = Real(0)
    for k in range(256):
        moved = max(moved, abs(lake.h[k] - 2) + abs(lake.hu[k]) + abs(lake.hv[k]))
    print("  lake at rest, 50 steps: max deviation", moved, " surface", lake.height(3, 3, 0), " velocity", lake.velocity(3, 3, 0))
    s.check(moved == 0 and lake.height(3, 3, 0) == 0, "a lake at rest stays at rest; the surface is bed + h")

    var raised = 0
    try:
        w.step(10)
    except:
        raised += 1
    try:
        _ = ShallowWaterFV(0, 4, 1, 0, 0, 0)
    except:
        raised += 1
    var dry = ShallowWaterFV(8, 8, 1, 0, 0, 0)
    dry.step(0.1)
    var any_ = Real(0)
    for k in range(64):
        any_ = max(any_, dry.h[k])
    s.check(raised == 2 and any_ == 0, "bad dt or size raises; a dry grid stays dry")
    s.finish()
