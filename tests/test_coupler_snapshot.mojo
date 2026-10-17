# tier: integration
"""`Coupler` on real solvers: snapshot round trip and the iterated scheme
(ROADMAP 17.61 integration; the heated plate under smoke of
`test_thermal_smoke`, 32^2 gas here to keep it short).

  1. Snapshot: run 5 coupled steps, `save()` both parts, run 5 more and
     record the state, `restore()`, run the same 5 again: plate
     temperatures, gas temperatures and velocities are bit-identical.
  2. `ITERATED` on the pair converges (passes per step printed) and its
     plume stays within 1 % of `INTERP`'s excess heat (the plate's huge
     heat capacity makes the coupling weak, so the schemes agree).
"""

from harness.runner import Suite
from geometry.vec import Real
from diag.counters import Counters
from physics.thermal import HeatGrid
from physics.mac_fluid import MacFluid2, Smoke2
from physics.coupler import Coupler, INTERP, ITERATED
from physics.thermal_smoke import HeatPlate, SmokeGas

comptime N = 32
comptime DX: Real = 1.0 / 32.0


def setup(scheme: Int) raises -> Coupler[HeatPlate, SmokeGas]:
    var g = HeatGrid(8, 3, 1, DX, 1.1e-4, 600.0)
    for i in range(8):
        g.fix(i, 0, 0, 600.0)
    var plate = HeatPlate(g^, 3.4e6, 50.0, 300.0)
    var s = Smoke2(MacFluid2(N, DX, 1e-4), 9.81 / 300.0, 0.0)
    for k in range(N * N):
        s.temp[k] = 300.0
    var gas = SmokeGas(s^, 12, 8, 0, 1206.0, 50.0, 600.0)
    return Coupler[HeatPlate, SmokeGas](plate^, gas^, 5, scheme)


def gas_excess(c: Coupler[HeatPlate, SmokeGas]) -> Float64:
    var e = Float64(0)
    for k in range(N * N):
        e += Float64(c.b.smoke.temp[k]) - 300.0
    return e * Float64(c.b.cap)


def main() raises:
    var s = Suite("coupler_snapshot")
    var counters = Counters()
    var c = setup(INTERP)
    for _ in range(5):
        c.step(0.05, counters)
    c.a.save()
    c.b.save()
    for _ in range(5):
        c.step(0.05, counters)
    var t_plate = c.a.grid.t.copy()
    var t_gas = c.b.smoke.temp.copy()
    var u = c.b.smoke.fluid.u.copy()
    var v = c.b.smoke.fluid.v.copy()
    c.a.restore()
    c.b.restore()
    for _ in range(5):
        c.step(0.05, counters)
    var same = True
    for i in range(len(t_plate)):
        same = same and c.a.grid.t[i] == t_plate[i]
    for k in range(len(t_gas)):
        same = same and c.b.smoke.temp[k] == t_gas[k] and c.b.smoke.fluid.u[k] == u[k] and c.b.smoke.fluid.v[k] == v[k]
    s.check(same, "restore + the same 5 steps: plate and gas bit-identical")

    var ci = setup(INTERP)
    var cr = setup(ITERATED)
    var most = 0
    for _ in range(20):
        ci.step(0.05, counters)
        cr.step(0.05, counters)
        most = max(most, cr.iterations)
    var ei = gas_excess(ci)
    var er = gas_excess(cr)
    print("1 s: gas excess heat INTERP", ei, " ITERATED", er, " rel. diff", abs(er / ei - 1), "  ITERATED passes per step <=", most)
    s.check(most < cr.max_iters, "ITERATED converges on the plate / smoke pair")
    s.check(abs(er / ei - 1) < 0.01, "weakly coupled pair: ITERATED within 1 % of INTERP")
    s.finish()
