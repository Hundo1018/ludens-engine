"""Water whose density follows its temperature (ROADMAP 17.61).

`HeatGrid` carries the temperature of a water column, one cell per layer
from the floor up. `apply_buoyancy` reads one density per `WaterVolume`,
so the volume-mean temperature of the column sets that density through a
linear equation of state, rho(T) = rho0 (1 - beta (T - t_ref)). This is the
coupling only: a layered density profile is not modelled, and the caller
copies `density()` into the `WaterVolume` before each buoyancy step.
"""

from geometry.vec import Real
from physics.thermal import HeatGrid


struct HeatedWater(Movable):
    var grid: HeatGrid
    var rho0: Real  # density at t_ref, kg/m^3
    var t_ref: Real  # K
    var beta: Real  # thermal expansion, 1/K

    def __init__(out self, var grid: HeatGrid, rho0: Real, t_ref: Real, beta: Real):
        self.grid = grid^
        self.rho0 = rho0
        self.t_ref = t_ref
        self.beta = beta

    def mean_temperature(self) -> Real:
        var s = Real(0)
        for c in range(len(self.grid.t)):
            s += self.grid.t[c]
        return s / Real(len(self.grid.t))

    def density(self) -> Real:
        return self.rho0 * (1 - self.beta * (self.mean_temperature() - self.t_ref))

    def step(mut self, dt: Real) raises:
        self.grid.step(dt)
