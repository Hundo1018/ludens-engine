# tier: component
"""Water whose density follows its temperature (ROADMAP 17.61,
`physics.thermal_float`). Only the glue is tested here. The float
integration (a box whose draft tracks the density) is blocked by the float
solver's rest-height error, recorded in ROADMAP 17.61.

  1. Equation of state: at t_ref the density is rho0; at t_ref + 30 K it is
     rho0 (1 - beta 30); a column held uniformly reports the held value as
     its mean temperature.
  2. Direction: a column with its top cell held hot warms by conduction, so
     its mean temperature rises over every block of 1 s and its density
     falls with it. A cold column is denser than rho0.
  3. Isolation passes through: a non-finite cell is counted by the grid and
     the column density stays finite.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real
from physics.thermal import HeatGrid
from physics.thermal_float import HeatedWater

comptime RHO0: Real = 998.2
comptime T0: Real = 293.15
comptime BETA: Real = 2.07e-4


def column(t0: Real, alpha: Real) raises -> HeatedWater:
    return HeatedWater(HeatGrid(1, 1, 7, 1.0, alpha, t0), RHO0, T0, BETA)


def main() raises:
    var s = Suite("thermal_float")

    var w = column(T0, 1e-5)
    s.check(w.density() == RHO0, "density at t_ref is rho0")

    for k in range(7):
        w.grid.fix(0, 0, k, T0 + 30)
    var want = RHO0 * (1 - BETA * 30)
    s.almost(Float64(w.density()), Float64(want), "uniform +30 K column: density is rho0 (1 - beta 30)", tol=1e-3)
    s.almost(Float64(w.mean_temperature()), Float64(T0 + 30), "uniform column: mean temperature is the held value", tol=1e-4)

    var cold = column(T0 - 20, 1e-5)
    s.check(cold.density() > RHO0, "a column colder than t_ref is denser than rho0")

    var hot = column(T0, 1e-2)
    hot.grid.fix(0, 0, 6, 353.15)
    var last = hot.mean_temperature()
    var last_rho = hot.density()
    var rising = True
    var falling = True
    for _ in range(60):
        for _ in range(60):
            hot.step(1.0 / 60.0)
        var m = hot.mean_temperature()
        if m <= last:
            rising = False
        last = m
        var r = hot.density()
        if r >= last_rho:
            falling = False
        last_rho = r
    s.check(rising, "a column with its top held hot warms by conduction over every second")
    s.check(falling, "its density falls as it warms")
    s.check(hot.density() < RHO0, "after 60 s the hot column is less dense than rho0")

    var bad = column(T0, 1e-5)
    bad.grid.t[3] = Real(0) / Real(0)
    bad.step(1e-3)
    s.check(bad.grid.isolated == 1, "a non-finite cell is isolated and counted")
    s.check(isfinite(bad.density()), "the column density stays finite after the isolation")

    s.finish()
