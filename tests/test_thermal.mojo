# tier: integration
"""Heat conduction and thermal expansion (ROADMAP 17.61).

  1. Ordinary: a 1D bar (alpha = 1e-5 m^2/s, 300 K, the end held at 400 K)
     after 10 s matches T0 + (Ts - T0) erfc(x / (2 sqrt(alpha t))) within
     0.1 K on the finite-difference grid and on the FEM tet bar; the two
     discretisations agree with each other within 0.1 K (parity).
  2. Integration: a free FEM bar heated by 100 K with alpha_L = 1.2e-3
     (exaggerated so f32 positions resolve it) lengthens by alpha_L dT L
     within 5 % after relaxing.
  3. Extreme: insulated domains keep their heat (grid sum T, tet sum C T)
     to 1e-5 (f32 rounding over 200 steps); temperatures <= 0 K or NaN raise; a step above the stability
     limit raises on both; a single tet conducts and stays finite.
"""

from std.math import erf, sqrt, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam
from physics.thermal import HeatGrid, HeatTets


def _erf_sol(x: Real, t: Real, alpha: Real) -> Real:
    return 300 + 100 * (1 - Real(erf(Float64(x / (2 * sqrt(alpha * t))))))


def main() raises:
    var s = Suite("thermal")
    var alpha = Real(1e-5)

    # ---- grid ---------------------------------------------------------------------------------------
    var g = HeatGrid(200, 1, 1, 1e-3, alpha, 300)
    g.fix(0, 0, 0, 400)
    var dt = Real(0.01)
    for _ in range(1000):
        g.step(dt)
    var eg = Real(0)
    for i in range(60):
        eg = max(eg, abs(g.t[i] - _erf_sol(Real(i) * 1e-3, 10, alpha)))
    print("  grid bar after 10 s: max |T - erf solution|", eg, "K   T at 10 mm", g.t[10], "(exact", _erf_sol(0.01, 10, alpha), ")")
    s.check(eg < 0.1, "finite differences match the erf solution within 0.1 K")

    # ---- tets ---------------------------------------------------------------------------------------
    var b = FemBody(1e5, 0.3)
    make_beam(b, 60, 1, 1, 1e-3, 1e-6)
    var ht = HeatTets(b, alpha, 300)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-9:
            ht.fix(i, 400)
    var tdt = min(Real(0.01), 0.9 * ht.max_dt())
    var steps = Int(10 / tdt + 0.5)
    for _ in range(steps):
        ht.step(tdt)
    var et = Real(0)
    var ep = Real(0)
    for i in range(b.node_count()):
        var x = b.pos(i)[0]
        if x > 0.0595:
            continue
        et = max(et, abs(ht.t[i] - _erf_sol(x, Real(steps) * tdt, alpha)))
        var gi = Int(x / 1e-3 + 0.5)
        ep = max(ep, abs(ht.t[i] - g.t[gi]))
    print("  tet bar (", len(b.tets), "tets, dt", tdt, "): max |T - erf|", et, "K   max |T_tet - T_grid|", ep, "K")
    s.check(et < 0.1, "linear tets match the erf solution within 0.1 K")
    s.check(ep < 0.1, "grid and tets agree within 0.1 K (parity)")

    # ---- expansion ----------------------------------------------------------------------------------
    var bar = FemBody(1e5, 0.3, 50)
    make_beam(bar, 10, 1, 1, 0.01, 0.001)
    var hot = HeatTets(bar, alpha, 400)
    var aL = Real(1.2e-3)
    hot.expand(bar, 300, aL)
    for _ in range(4000):
        bar.step(2e-4, Vec3(0, 0, 0, 0))
    var xmin = Real(1e9)
    var xmax = Real(-1e9)
    for i in range(bar.node_count()):
        xmin = min(xmin, bar.x[i])
        xmax = max(xmax, bar.x[i])
    var grow = (xmax - xmin) - 0.1
    var want = aL * 100 * 0.1
    print("  heated bar: length change", grow, " alpha_L dT L", want)
    s.check(abs(grow / want - 1) < 0.05, "thermal expansion within 5 %")

    # ---- extremes -------------------------------------------------------------------------------------
    var ins = HeatGrid(10, 10, 10, 0.01, alpha, 300)
    for c in range(len(ins.t)):
        ins.t[c] = 300 + Real((c * 37) % 50)
    var h0 = ins.heat()
    for _ in range(200):
        ins.step(0.9 * ins.max_dt())
    var tb = FemBody(1e5, 0.3)
    make_beam(tb, 4, 2, 2, 0.01, 0.001)
    var tins = HeatTets(tb, alpha, 300)
    for i in range(len(tins.t)):
        tins.t[i] = 300 + Real((i * 13) % 40)
    var th0 = tins.heat()
    for _ in range(200):
        tins.step(0.9 * tins.max_dt())
    print("  insulated: grid heat drift", abs(ins.heat() / h0 - 1), " tet heat drift", abs(tins.heat() / th0 - 1))
    s.check(abs(ins.heat() / h0 - 1) < 1e-5 and abs(tins.heat() / th0 - 1) < 1e-5, "insulated domains keep their heat")
    var errs = 0
    try:
        g.fix(3, 0, 0, 0)
    except:
        errs += 1
    try:
        ht.fix(3, Real(0) / Real(0))
    except:
        errs += 1
    try:
        _ = HeatGrid(4, 4, 4, 0.01, alpha, -5)
    except:
        errs += 1
    try:
        g.step(2 * g.max_dt())
    except:
        errs += 1
    try:
        ht.step(2 * ht.max_dt())
    except:
        errs += 1
    s.check(errs == 5, "<= 0 K, NaN, negative initial and unstable steps raise")
    var one = FemBody(1e5, 0.3)
    one.add_node(Vec3(0, 0, 0, 0), 1)
    one.add_node(Vec3(0.01, 0, 0, 0), 1)
    one.add_node(Vec3(0, 0.01, 0, 0), 1)
    one.add_node(Vec3(0, 0, 0.01, 0), 1)
    one.add_tet(0, 1, 2, 3)
    var h1 = HeatTets(one, alpha, 300)
    h1.fix(0, 500)
    for _ in range(100):
        h1.step(0.5 * h1.max_dt())
    s.check(isfinite(h1.t[3]) and h1.t[3] > 300 and h1.t[3] <= 500, "a single tet conducts and stays bounded")
    s.finish()
