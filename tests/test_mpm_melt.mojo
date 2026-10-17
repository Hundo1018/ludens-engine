# tier: component
"""Melting MPM material (ROADMAP 17.61, `physics.mpm_melt.MpmMelt`).

Wax-like block: 8 x 6 x 8 particles 2.5 cm apart, 900 kg/m^3, E 2e4 Pa,
c 2000 J/(kg K), L 2e5 J/kg, melting at 330 K, alpha 1e-3 m^2/s (raised
from wax's 1e-7 so a test-length run melts more than one layer). MPM grid
32^3 of 5 cm, dt 5e-4 s.

  1. Unit: `melt_state` on the plateau: T stays at Tm while phi goes 0 -> 1.
  2. Ordinary: a solid block (300 K) keeps its height; the same block
     liquid (340 K) slumps and spreads; heated from a 600 K floor
     (h 1e5) the solid block's bottom melts and the block loses height,
     while the unheated control does not.
  3. Integration: enthalpy budget -- sum m H changes by the floor's heat to
     1e-5 (conduction moves enthalpy without creating it, through the
     latent plateau too).
  4. Extreme: no particles / c <= 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.mpm import MpmSolver
from physics.mpm_melt import MpmMelt, melt_state

comptime DX: Real = 0.05
comptime N = 32
comptime SP: Real = 0.025
comptime DT: Real = 5e-4
comptime G = Vec3(0, -9.8, 0, 0)


def block() -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2e4, 0.3)
    var vol = SP * SP * SP
    for i in range(8):
        for j in range(6):
            for k in range(8):
                m.add(Vec3(0.7 + Real(i) * SP, 0.16 + Real(j) * SP, 0.7 + Real(k) * SP, 0), vol * 900.0, vol)
    return m^


def height(m: MpmSolver) -> Real:
    var h = Real(-1e30)
    for ref q in m.p:
        h = max(h, q.x[1])
    return h


def bottom(m: MpmSolver) -> Real:
    var b = Real(1e30)
    for ref q in m.p:
        b = min(b, q.x[1])
    return b


def width(m: MpmSolver) -> Real:
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for ref q in m.p:
        lo = min(lo, q.x[0])
        hi = max(hi, q.x[0])
    return hi - lo


def run(mut m: MpmSolver, mut w: MpmMelt, steps: Int) raises:
    for _ in range(steps):
        w.step(m, DT, G)


def main() raises:
    var s = Suite("mpm_melt")

    # 1. the latent plateau
    var c = Real(2000)
    var lat = Real(2e5)
    var a0 = melt_state(Float64(c) * 330.0 - 2000.0, c, lat, 330.0)
    var a1 = melt_state(Float64(c) * 330.0 + 1e5, c, lat, 330.0)
    var a2 = melt_state(Float64(c) * 330.0 + 2e5 + 4000.0, c, lat, 330.0)
    s.check(abs(a0[0] - 329.0) < 1e-3 and a0[1] == 0, "below the plateau: T = H / c, solid")
    s.check(a1[0] == 330.0 and abs(a1[1] - 0.5) < 1e-6, "on the plateau: T = Tm, phi = 0.5")
    s.check(abs(a2[0] - 332.0) < 1e-3 and a2[1] == 1, "above: T = (H - L) / c, liquid")

    # 2. solid vs liquid vs heated
    var ms = block()
    var ws = MpmMelt(ms, SP, 1e-3, c, lat, 330.0, 300.0)
    var ml = block()
    var wl = MpmMelt(ml, SP, 1e-3, c, lat, 330.0, 340.0)
    var mh = block()
    var wh = MpmMelt(mh, SP, 1e-3, c, lat, 330.0, 300.0)
    var h0 = height(ms) - bottom(ms)
    var w0 = width(ms)
    # settle, then heat the bottom layer of the heated copy
    run(ms, ws, 400)
    run(ml, wl, 400)
    run(mh, wh, 400)
    wh.heat_floor(bottom(mh) + 0.5 * SP, 600.0, 1e5)
    var e0 = wh.total_enthalpy(mh)
    run(ms, ws, 2000)
    run(ml, wl, 2000)
    run(mh, wh, 2000)
    var hs = height(ms) - bottom(ms)
    var hl = height(ml) - bottom(ml)
    var hh = height(mh) - bottom(mh)
    print("after 1.2 s: height solid", hs, " liquid", hl, " heated", hh, " (start", h0, ")")
    print("  width solid", width(ms), " liquid", width(ml), " heated", width(mh), " (start", w0, ")")
    print("  melted fraction: solid", ws.melted(), " liquid", wl.melted(), " heated", wh.melted())
    s.check(ws.melted() == 0 and hs > 0.9 * h0, "solid block keeps its height (> 90 %)")
    s.check(wl.melted() == 1 and hl < 0.7 * h0 and width(ml) > 1.2 * w0, "liquid block slumps and spreads")
    s.check(wh.melted() > 0.1 and hh < 0.95 * hs, "heated block melts from below and loses height")

    # 3. enthalpy budget
    var e1 = wh.total_enthalpy(mh)
    var rel = abs((e1 - e0) - wh.heat_in) / wh.heat_in
    print("  enthalpy change", e1 - e0, "J  floor heat", wh.heat_in, "J  rel. error", rel)
    s.check(rel < 1e-5, "enthalpy changes by the floor's heat (1e-5)")

    # 4. bad input
    var raised = 0
    try:
        _ = MpmMelt(MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2e4, 0.3), SP, 1e-3, c, lat, 330.0, 300.0)
    except:
        raised += 1
    try:
        _ = MpmMelt(ms, SP, 1e-3, 0.0, lat, 330.0, 300.0)
    except:
        raised += 1
    s.check(raised == 2, "no particles / c <= 0 raise")
    s.finish()
