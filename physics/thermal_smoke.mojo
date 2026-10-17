"""A heated plate under buoyant smoke, coupled through `Coupler` (ROADMAP
17.61: "smoke rising over a heated metal plate").

`HeatPlate` wraps a `HeatGrid` (w x rows x 1 cells, same dx as the gas);
its top row touches gas cells (i0 .. i0 + w - 1, row j0) of a `Smoke2`
wrapped by `SmokeGas`. Heat crosses that face as convection,
q = h dx (T_other - T_own) dt per cell (J per metre of depth, the 2-D
gas being a slice). Each side adds its q to its own cell over its own
`advance` (the plate in one step of dt, the gas in each of its substeps),
using the other side's temperature that `Coupler` hands it; `impulse()` is
the heat received, so the coupler's `imbalance` is the heat the
partitioned exchange creates or loses per step.

Temperatures are kelvin on both sides; the gas buoyancy is the
`Smoke2.buoyancy` factor (g / T_ref for a Boussinesq gas). Capacities are
rho c dx^2 per cell (J / (K m)). `HeatPlate.advance` splits dt into
`HeatGrid` steps below its stability limit. The gas side raises if
h dx dt / cap_gas >= 1 (the explicit exchange would overshoot).
"""

from geometry.vec import Real
from .thermal import HeatGrid
from .mac_fluid import Smoke2
from .coupler import CoupledPart


struct HeatPlate(CoupledPart):
    var grid: HeatGrid
    var cap: Real  # J / (K m) per cell
    var h: Real  # W / (m^2 K)
    var gas_t: List[Real]
    var received: Real  # heat in over the last advance, J / m
    var total_in: Float64  # since construction
    var _saved: List[Real]

    def __init__(out self, var grid: HeatGrid, rho_c: Real, h: Real, gas_t0: Real) raises:
        if grid.nz != 1 or not (rho_c > 0) or not (h >= 0):
            raise Error("HeatPlate: grid with nz 1, rho_c > 0, h >= 0")
        self.cap = rho_c * grid.dx * grid.dx
        self.h = h
        self.gas_t = List[Real](length=grid.nx, fill=gas_t0)
        self.received = 0
        self.total_in = 0
        self._saved = List[Real]()
        self.grid = grid^

    def advance(mut self, dt: Real) raises:
        var top = self.grid.ny - 1
        var q_sum = Real(0)
        for i in range(self.grid.nx):
            var c = self.grid.idx(i, top, 0)
            var q = self.h * self.grid.dx * (self.gas_t[i] - self.grid.t[c]) * dt
            q_sum += q
            if not self.grid.fixed[c]:
                self.grid.t[c] += q / self.cap
        var n = Int(dt / self.grid.max_dt()) + 1
        for _ in range(n):
            self.grid.step(dt / Real(n))
        self.received = q_sum
        self.total_in += Float64(q_sum)

    def send(self) -> List[Real]:
        var out = List[Real](length=self.grid.nx, fill=0)
        for i in range(self.grid.nx):
            out[i] = self.grid.t[self.grid.idx(i, self.grid.ny - 1, 0)]
        return out^

    def recv(mut self, data: List[Real]):
        self.gas_t = data.copy()

    def impulse(self) -> List[Real]:
        return [self.received]

    def save(mut self):
        self._saved = self.grid.t.copy()

    def restore(mut self):
        self.grid.t = self._saved.copy()


struct SmokeGas(CoupledPart):
    var smoke: Smoke2
    var i0: Int
    var w: Int
    var j0: Int
    var cap: Real
    var h: Real
    var plate_t: List[Real]
    var received: Real
    var total_in: Float64
    var _su: List[Real]
    var _sv: List[Real]
    var _sp: List[Real]
    var _st: List[Real]

    def __init__(out self, var smoke: Smoke2, i0: Int, w: Int, j0: Int, rho_c: Real, h: Real, plate_t0: Real) raises:
        var n = smoke.fluid.n
        if i0 < 0 or w < 1 or i0 + w > n or j0 < 0 or j0 >= n or not (rho_c > 0) or not (h >= 0):
            raise Error("SmokeGas: contact span inside the grid, rho_c > 0, h >= 0")
        self.cap = rho_c * smoke.fluid.dx * smoke.fluid.dx
        self.i0 = i0
        self.w = w
        self.j0 = j0
        self.h = h
        self.plate_t = List[Real](length=w, fill=plate_t0)
        self.received = 0
        self.total_in = 0
        self._su = List[Real]()
        self._sv = List[Real]()
        self._sp = List[Real]()
        self._st = List[Real]()
        self.smoke = smoke^

    def advance(mut self, dt: Real) raises:
        var n = self.smoke.fluid.n
        var k = self.h * self.smoke.fluid.dx * dt / self.cap
        if k >= 1:
            raise Error("SmokeGas.advance: h dx dt / cap >= 1, take smaller gas steps")
        var q_sum = Real(0)
        for i in range(self.w):
            var c = self.j0 * n + self.i0 + i
            var q = self.h * self.smoke.fluid.dx * (self.plate_t[i] - self.smoke.temp[c]) * dt
            q_sum += q
            self.smoke.temp[c] += q / self.cap
        self.smoke.step(dt)
        self.received = q_sum
        self.total_in += Float64(q_sum)

    def send(self) -> List[Real]:
        var n = self.smoke.fluid.n
        var out = List[Real](length=self.w, fill=0)
        for i in range(self.w):
            out[i] = self.smoke.temp[self.j0 * n + self.i0 + i]
        return out^

    def recv(mut self, data: List[Real]):
        self.plate_t = data.copy()

    def impulse(self) -> List[Real]:
        return [self.received]

    def save(mut self):
        self._su = self.smoke.fluid.u.copy()
        self._sv = self.smoke.fluid.v.copy()
        self._sp = self.smoke.fluid.p.copy()
        self._st = self.smoke.temp.copy()

    def restore(mut self):
        self.smoke.fluid.u = self._su.copy()
        self.smoke.fluid.v = self._sv.copy()
        self.smoke.fluid.p = self._sp.copy()
        self.smoke.temp = self._st.copy()
