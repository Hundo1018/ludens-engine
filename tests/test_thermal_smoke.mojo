# tier: integration
"""Smoke over a heated plate (ROADMAP 17.61, `physics.thermal_smoke`
through `physics.coupler.Coupler`).

Gas: `Smoke2` 64^2, 1 m periodic box, air (rho c 1206 J/(m^3 K)),
buoyancy g / 300 K, epsilon 0, 300 K. Plate: copper-like `HeatGrid`
16 x 3 cells under gas row 0, columns 24 .. 39, rho c 3.4e6, alpha 1.1e-4,
600 K with its bottom row held at 600 K; h = 50 W/(m^2 K). The plate steps
0.1 s, the gas 10 substeps of 0.01 s (`INTERP`).

  1. Ordinary: after 3 s the gas above the plate is warmer than 300 K and
     the excess heat's centroid has left the contact row and keeps rising;
     the gas moves up over the plate. Control: buoyancy 0 leaves the
     velocity exactly 0.
  2. Integration: heat bookkeeping. Plate and gas each record the heat
     they received; their sum (the coupler's imbalance) is a small part
     of the heat moved, smaller with `INTERP` than `EXPLICIT`. The gas's
     excess heat sum cap (T - 300) is compared with the heat it received
     (semi-Lagrangian advection does not conserve it exactly; printed).
  3. Extreme: a gas substep with h dx dt / cap >= 1 raises.
"""

from harness.runner import Suite
from geometry.vec import Real
from diag.counters import Counters
from physics.thermal import HeatGrid
from physics.mac_fluid import MacFluid2, Smoke2
from physics.coupler import Coupler, EXPLICIT, INTERP
from physics.thermal_smoke import HeatPlate, SmokeGas

comptime N = 64
comptime DX: Real = 1.0 / 64.0
comptime I0 = 24
comptime W = 16
comptime RHO_C_AIR: Real = 1206.0
comptime H: Real = 50.0


def setup(buoyancy: Real, scheme: Int, ratio: Int = 10) raises -> Coupler[HeatPlate, SmokeGas]:
    var g = HeatGrid(W, 3, 1, DX, 1.1e-4, 600.0)
    for i in range(W):
        g.fix(i, 0, 0, 600.0)
    var plate = HeatPlate(g^, 3.4e6, H, 300.0)
    var s = Smoke2(MacFluid2(N, DX, 1e-4), buoyancy, 0.0)
    for k in range(N * N):
        s.temp[k] = 300.0
    var gas = SmokeGas(s^, I0, W, 0, RHO_C_AIR, H, 600.0)
    return Coupler[HeatPlate, SmokeGas](plate^, gas^, ratio, scheme)


def excess(c: Coupler[HeatPlate, SmokeGas]) -> Tuple[Float64, Float64]:
    """(sum cap (T - 300), centroid height of that excess in m)."""
    var cap = Float64(c.b.cap)
    var e = Float64(0)
    var ey = Float64(0)
    for j in range(N):
        for i in range(N):
            var d = Float64(c.b.smoke.temp[j * N + i]) - 300.0
            if d > 0:
                e += cap * d
                ey += cap * d * (Float64(j) + 0.5) * Float64(DX)
    return (e, ey / e if e > 0 else 0.0)


def mean_v_above(c: Coupler[HeatPlate, SmokeGas]) -> Real:
    var s = Real(0)
    for j in range(1, 16):
        for i in range(I0, I0 + W):
            s += c.b.smoke.fluid.v[j * N + i]
    return s / Real(15 * W)


def main() raises:
    var s = Suite("thermal_smoke")
    var counters = Counters()

    var c = setup(9.81 / 300.0, INTERP)
    var y1 = Float64(0)
    var sum_abs = Float64(0)
    for step in range(30):
        c.step(0.1, counters)
        sum_abs += Float64(abs(c.b.received))
        if step == 14:
            y1 = excess(c)[1]
    var ex = excess(c)
    var vup = mean_v_above(c)
    print("after 3 s: gas excess heat", ex[0], "J/m  centroid y", ex[1], "m (1.5 s:", y1, ")  mean v over plate", vup, "m/s")
    print("  heat into gas", c.b.total_in, " out of plate", -c.a.total_in, " max step imbalance", c.max_imbalance)
    s.check(ex[0] > 0 and ex[1] > y1 and y1 > 1.5 * Float64(DX), "the warm gas leaves the contact row and keeps rising")
    s.check(vup > 0, "gas over the plate moves up")
    var rel = abs(Float64(c.b.total_in) + Float64(c.a.total_in)) / Float64(c.b.total_in)
    print("  cumulative |gas in + plate in| / gas in", rel)
    s.check(rel < 0.05, "partitioned heat exchange loses / makes < 5 % of the heat moved")
    var budget = ex[0] / Float64(c.b.total_in)
    print("  gas excess heat / heat received", budget)
    s.check(budget > 0.8 and budget < 1.2, "gas heat budget within 20 % (advection is not conservative)")

    # explicit vs interpolated: interface imbalance
    var ce = setup(9.81 / 300.0, EXPLICIT)
    for _ in range(30):
        ce.step(0.1, counters)
    var rel_e = abs(Float64(ce.b.total_in) + Float64(ce.a.total_in)) / Float64(ce.b.total_in)
    print("  cumulative imbalance: explicit", rel_e, " interp", rel)
    s.check(rel <= rel_e, "INTERP does not exchange worse than EXPLICIT")

    # control: no buoyancy, no motion
    var c0 = setup(0.0, INTERP)
    for _ in range(10):
        c0.step(0.1, counters)
    var vmax = Real(0)
    for k in range(N * N):
        vmax = max(vmax, abs(c0.b.smoke.fluid.v[k]), abs(c0.b.smoke.fluid.u[k]))
    s.check(vmax == 0 and excess(c0)[0] > 0, "buoyancy 0: gas warms but stays still")

    # gas substep too large for the explicit exchange
    var bad = setup(9.81 / 300.0, INTERP, 1)
    var raised = False
    try:
        bad.step(1.0, counters)
    except:
        raised = True
    s.check(raised, "h dx dt / cap >= 1 raises")
    s.finish()
