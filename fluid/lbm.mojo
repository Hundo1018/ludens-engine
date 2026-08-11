"""The LBM solver: collide, stream, and the boundaries that make it a tunnel.

One step is two halves. COLLIDE relaxes every cell's distribution toward its
local equilibrium; STREAM moves each distribution one cell along its own
velocity. Collision is entirely local and streaming is a fixed shift, so the
whole method is a stencil with no search, no solve, and no global coupling —
`bench_lbm` is where that shows up against the particle solvers.

Streaming is PULL, not push: each cell gathers from its neighbours instead of
scattering to them. Both are correct; pull is chosen because it writes only to
the cell being processed, which makes the sweep race-free by construction and
means the CPU reference and a GPU kernel can share the same indexing without
one of them needing atomics.

Two buffers are kept and swapped. Streaming in place would read values a
neighbour has already overwritten; the classic in-place tricks (AA-pattern,
esoteric twist) trade that memory for indexing complexity that is not worth it
until the grid stops fitting in RAM.

BOUNDARIES. Solid cells use half-way bounce-back: the wall sits midway between
two cell centres, and a distribution arriving at a solid cell is reflected back
along its opposite direction. That places the no-slip surface at second-order
accuracy for walls aligned to the grid, and at first order with a staircase
error for walls that are not — the honest limitation, and the reason a tilted
wall is its own benchmark row rather than a footnote.

Inlet and outlet turn a box into a tunnel: a fixed-velocity inlet imposed by
equilibrium with the local density, and a zero-gradient outlet that copies its
neighbour. Without them there is no through-flow and no drag to measure.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from .d3q19 import (
    Q, cx, cy, cz, weight, opposite, equilibrium, tau_from_viscosity,
    viscosity_from_tau, CS2,
)

comptime CELL_FLUID = 0
comptime CELL_SOLID = 1
comptime CELL_INLET = 2
comptime CELL_OUTLET = 3

comptime BC_PERIODIC = 0
comptime BC_TUNNEL = 1  # inlet at x=0, outlet at x=nx-1, periodic elsewhere


struct Lbm(Movable, ImplicitlyDeletable):
    """A D3Q19 lattice. All fields flat, SoA by direction."""

    var nx: Int
    var ny: Int
    var nz: Int
    var tau: Real
    var f: List[Real]  # [dir][cell]
    var g: List[Real]  # scratch for the streamed values
    var flag: List[Int]
    # The velocity set, materialised ONCE. `d3q19.cx` and friends build a list
    # on every call and `opposite` searches the set, which is fine for a test
    # asserting a property and catastrophic in a loop that runs 19 times per
    # cell per step: the first benchmark of this module read 0.18 MLUPS, about
    # three orders below any published CPU LBM, and all of it was allocation.
    var ex: InlineArray[Int, Q]
    var ey: InlineArray[Int, Q]
    var ez: InlineArray[Int, Q]
    var w: InlineArray[Real, Q]
    var opp: InlineArray[Int, Q]
    var inlet_u: Real  # x velocity imposed at the inlet
    var force_x: Real  # uniform body force, the pressure gradient of a channel
    # Smagorinsky constant. 0 disables the model and leaves plain BGK, bit for
    # bit. 0.1-0.2 is the usual range; 0.17 is the classic value.
    var smagorinsky: Real
    # Force on the solid, accumulated over the last `stream()` by momentum
    # exchange. This is the step that turns the simulation into a MEASUREMENT:
    # without it a wind tunnel is a nice animation.
    var fx: Real
    var fy: Real
    var fz: Real
    var mode: Int

    def __init__(
        out self, nx: Int, ny: Int, nz: Int, nu: Real, mode: Int = BC_PERIODIC
    ):
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.tau = tau_from_viscosity(nu)
        self.mode = mode
        self.ex = InlineArray[Int, Q](fill=0)
        self.ey = InlineArray[Int, Q](fill=0)
        self.ez = InlineArray[Int, Q](fill=0)
        self.w = InlineArray[Real, Q](fill=0)
        self.opp = InlineArray[Int, Q](fill=0)
        for i in range(Q):
            self.ex[i] = cx(i)
            self.ey[i] = cy(i)
            self.ez[i] = cz(i)
            self.w[i] = weight(i)
            self.opp[i] = opposite(i)
        self.inlet_u = 0
        self.force_x = 0
        self.smagorinsky = 0
        self.fx = 0
        self.fy = 0
        self.fz = 0
        var n = nx * ny * nz
        self.f = List[Real](capacity=Q * n)
        self.g = List[Real](capacity=Q * n)
        for _ in range(Q * n):
            self.f.append(0)
            self.g.append(0)
        self.flag = List[Int](capacity=n)
        for _ in range(n):
            self.flag.append(CELL_FLUID)

    @always_inline
    def _feq(self, i: Int, rho: Real, ux: Real, uy: Real, uz: Real) -> Real:
        """Equilibrium from the cached velocity set. Same formula as
        `d3q19.equilibrium`, which stays as the readable reference the test
        checks moments against."""
        var cu = Real(self.ex[i]) * ux + Real(self.ey[i]) * uy + Real(
            self.ez[i]
        ) * uz
        var u2 = ux * ux + uy * uy + uz * uz
        return self.w[i] * rho * (1 + 3 * cu + 4.5 * cu * cu - 1.5 * u2)

    def cells(self) -> Int:
        return self.nx * self.ny * self.nz

    def idx(self, x: Int, y: Int, z: Int) -> Int:
        return (z * self.ny + y) * self.nx + x

    def at(self, i: Int, c: Int) -> Real:
        return self.f[i * self.cells() + c]

    def set_at(mut self, i: Int, c: Int, v: Real):
        self.f[i * self.cells() + c] = v

    def init_uniform(mut self, rho: Real, ux: Real, uy: Real, uz: Real):
        """Every cell at equilibrium for the given macroscopic state — the only
        initial condition that does not radiate a pressure wave on step one."""
        for c in range(self.cells()):
            for i in range(Q):
                self.f[i * self.cells() + c] = self._feq(i, rho, ux, uy, uz)

    def density(self, c: Int) -> Real:
        var r = Real(0)
        for i in range(Q):
            r += self.f[i * self.cells() + c]
        return r

    def velocity(self, c: Int) -> Vec3:
        var r = Real(0)
        var ux = Real(0)
        var uy = Real(0)
        var uz = Real(0)
        for i in range(Q):
            var v = self.f[i * self.cells() + c]
            r += v
            ux += v * Real(self.ex[i])
            uy += v * Real(self.ey[i])
            uz += v * Real(self.ez[i])
        if r <= 0:
            return Vec3(0, 0, 0)
        return Vec3(ux / r, uy / r, uz / r)

    def total_mass(self) -> Real:
        """Summed over FLUID cells only. Solid cells hold reflected
        distributions that are not part of the fluid, and counting them would
        make a conservation check pass for the wrong reason."""
        var m = Real(0)
        for c in range(self.cells()):
            if self.flag[c] == CELL_FLUID:
                m += self.density(c)
        return m

    def set_solid_box(mut self, lo: Vec3, hi: Vec3):
        """Voxelise an axis-aligned box as solid cells."""
        for z in range(self.nz):
            for y in range(self.ny):
                for x in range(self.nx):
                    if (
                        Real(x) >= lo[0] and Real(x) <= hi[0]
                        and Real(y) >= lo[1] and Real(y) <= hi[1]
                        and Real(z) >= lo[2] and Real(z) <= hi[2]
                    ):
                        self.flag[self.idx(x, y, z)] = CELL_SOLID

    def set_solid_sphere(mut self, cxx: Real, cyy: Real, czz: Real, r: Real):
        for z in range(self.nz):
            for y in range(self.ny):
                for x in range(self.nx):
                    var dx = Real(x) - cxx
                    var dy = Real(y) - cyy
                    var dz = Real(z) - czz
                    if dx * dx + dy * dy + dz * dz <= r * r:
                        self.flag[self.idx(x, y, z)] = CELL_SOLID

    def solid_count(self) -> Int:
        var n = 0
        for c in range(self.cells()):
            if self.flag[c] == CELL_SOLID:
                n += 1
        return n

    def _wrap(self, v: Int, n: Int) -> Int:
        var w = v % n
        return w + n if w < 0 else w

    def collide(mut self):
        """BGK: f <- f - (f - f_eq) / tau, on fluid cells only."""
        var inv_tau = Real(1) / self.tau
        var n = self.cells()
        for c in range(n):
            if self.flag[c] != CELL_FLUID:
                continue
            var rho = Real(0)
            var ux = Real(0)
            var uy = Real(0)
            var uz = Real(0)
            for i in range(Q):
                var v = self.f[i * n + c]
                rho += v
                ux += v * Real(self.ex[i])
                uy += v * Real(self.ey[i])
                uz += v * Real(self.ez[i])
            if rho <= 0:
                continue
            ux /= rho
            uy /= rho
            uz /= rho
            # Body force by velocity shift (He/Shan): the equilibrium is built
            # at u + tau*F/rho instead of u. Cheaper than Guo forcing and exact
            # to the same order for a UNIFORM force, which is all a channel
            # needs -- a spatially varying force would want the full scheme.
            if self.force_x != 0:
                ux += self.tau * self.force_x / rho
            if self.smagorinsky <= 0:
                for i in range(Q):
                    var fe = self._feq(i, rho, ux, uy, uz)
                    self.f[i * n + c] += (fe - self.f[i * n + c]) * inv_tau
                continue

            # Smagorinsky LES. The strain rate does not have to be
            # reconstructed by finite differences: in LBM the non-equilibrium
            # part of the distribution IS proportional to it, so the whole
            # model is local to the cell and costs one extra pass over the 19
            # directions. That locality is the reason LES sits so naturally
            # here and so awkwardly in a projection-method solver.
            var qxx = Real(0)
            var qyy = Real(0)
            var qzz = Real(0)
            var qxy = Real(0)
            var qxz = Real(0)
            var qyz = Real(0)
            for i in range(Q):
                var neq = self.f[i * n + c] - self._feq(i, rho, ux, uy, uz)
                var ax = Real(self.ex[i])
                var ay = Real(self.ey[i])
                var az = Real(self.ez[i])
                qxx += ax * ax * neq
                qyy += ay * ay * neq
                qzz += az * az * neq
                qxy += ax * ay * neq
                qxz += ax * az * neq
                qyz += ay * az * neq
            var qmag = sqrt(
                2
                * (
                    qxx * qxx + qyy * qyy + qzz * qzz
                    + 2 * (qxy * qxy + qxz * qxz + qyz * qyz)
                )
            )
            # tau_eff solves the quadratic that adds the eddy viscosity to the
            # molecular one. It is >= tau always, so the model can only DAMP --
            # a turbulence model that could reduce the effective viscosity
            # would be a stability hazard rather than a stabiliser.
            var cd = self.smagorinsky * self.smagorinsky
            var tau_eff = 0.5 * (
                self.tau
                + sqrt(
                    self.tau * self.tau
                    + 18 * Real(1.4142135) * cd * qmag / rho
                )
            )
            var inv_eff = Real(1) / tau_eff
            for i in range(Q):
                var fe = self._feq(i, rho, ux, uy, uz)
                self.f[i * n + c] += (fe - self.f[i * n + c]) * inv_eff

    def stream(mut self):
        """Pull streaming with half-way bounce-back at solids.

        A fluid cell gathers direction `i` from the neighbour that lies OPPOSITE
        `i` — that is where the distribution travelling along `i` came from. If
        that neighbour is solid, the distribution never arrived: what arrives
        instead is this cell's own opposite-direction population, reflected.
        That single substitution is the whole of half-way bounce-back, and it
        is why a solid needs no special data at all beyond its flag."""
        var n = self.cells()
        self.fx = 0
        self.fy = 0
        self.fz = 0
        for z in range(self.nz):
            for y in range(self.ny):
                for x in range(self.nx):
                    var c = self.idx(x, y, z)
                    if self.flag[c] == CELL_SOLID:
                        continue
                    for i in range(Q):
                        var sx = x - self.ex[i]
                        var sy = y - self.ey[i]
                        var sz = z - self.ez[i]
                        var outside = (
                            sx < 0 or sx >= self.nx
                            or sy < 0 or sy >= self.ny
                            or sz < 0 or sz >= self.nz
                        )
                        if outside and self.mode == BC_TUNNEL and (
                            sx < 0 or sx >= self.nx
                        ):
                            # streamwise ends are handled after the sweep by
                            # the inlet/outlet conditions; gather from self so
                            # nothing is read out of bounds meanwhile
                            self.g[i * n + c] = self.f[i * n + c]
                            continue
                        var wx = self._wrap(sx, self.nx)
                        var wy = self._wrap(sy, self.ny)
                        var wz = self._wrap(sz, self.nz)
                        var src = self.idx(wx, wy, wz)
                        if self.flag[src] == CELL_SOLID:
                            var back = self.f[self.opp[i] * n + c]
                            self.g[i * n + c] = back
                            # Momentum exchange across this link. The fluid
                            # sends `back` away along -c_i and gets it returned
                            # along +c_i, so its momentum changes by 2*back*c_i
                            # and the solid takes the opposite. Summed over
                            # every boundary link this is the total force,
                            # exact to the same order as the bounce-back
                            # itself and needing no surface normal, no area
                            # element, and no reconstruction of the pressure.
                            self.fx -= 2 * Real(self.ex[i]) * back
                            self.fy -= 2 * Real(self.ey[i]) * back
                            self.fz -= 2 * Real(self.ez[i]) * back
                        else:
                            self.g[i * n + c] = self.f[i * n + src]
        # Swap, not copy: streaming already wrote every value into `g`, so
        # copying it back would touch 19 floats per cell for no reason. The
        # buffers are interchangeable by construction, which is the whole point
        # of keeping two.
        var tmp = self.f^
        self.f = self.g^
        self.g = tmp^

    def apply_inlet_outlet(mut self):
        """Fixed-velocity inlet, zero-gradient outlet.

        The inlet is imposed by setting the whole distribution to equilibrium at
        the target velocity and the density the cell already has — taking the
        density from the flow rather than fixing it is what stops the inlet
        acting as a mass source. The outlet copies its upstream neighbour,
        which is the cheapest condition that lets a wake leave without
        reflecting."""
        if self.mode != BC_TUNNEL:
            return
        var n = self.cells()
        for z in range(self.nz):
            for y in range(self.ny):
                var ci = self.idx(0, y, z)
                if self.flag[ci] != CELL_SOLID:
                    var rho = self.density(ci)
                    for i in range(Q):
                        self.f[i * n + ci] = self._feq(
                            i, rho, self.inlet_u, 0, 0
                        )
                var co = self.idx(self.nx - 1, y, z)
                var cu = self.idx(self.nx - 2, y, z)
                if self.flag[co] != CELL_SOLID:
                    for i in range(Q):
                        self.f[i * n + co] = self.f[i * n + cu]

    def eddy_viscosity(self, c: Int) -> Real:
        """The extra viscosity the model adds at cell `c`, for inspection.
        Zero everywhere the flow is locally uniform, which is the property that
        makes it a SUBGRID model rather than a blanket damping."""
        if self.smagorinsky <= 0:
            return 0
        var n = self.cells()
        var rho = self.density(c)
        if rho <= 0:
            return 0
        var u = self.velocity(c)
        var qxx = Real(0)
        var qyy = Real(0)
        var qzz = Real(0)
        var qxy = Real(0)
        var qxz = Real(0)
        var qyz = Real(0)
        for i in range(Q):
            var neq = self.f[i * n + c] - self._feq(i, rho, u[0], u[1], u[2])
            var ax = Real(self.ex[i])
            var ay = Real(self.ey[i])
            var az = Real(self.ez[i])
            qxx += ax * ax * neq
            qyy += ay * ay * neq
            qzz += az * az * neq
            qxy += ax * ay * neq
            qxz += ax * az * neq
            qyz += ay * az * neq
        var qmag = sqrt(
            2
            * (
                qxx * qxx + qyy * qyy + qzz * qzz
                + 2 * (qxy * qxy + qxz * qxz + qyz * qyz)
            )
        )
        var cd = self.smagorinsky * self.smagorinsky
        var tau_eff = 0.5 * (
            self.tau
            + sqrt(self.tau * self.tau + 18 * Real(1.4142135) * cd * qmag / rho)
        )
        return (tau_eff - self.tau) / 3

    def drag_coefficient(self, u_inf: Real, area: Real) -> Real:
        """Cd = Fx / (0.5 * rho * u^2 * A), with rho = 1 in lattice units.

        `area` is the projected frontal area in lattice cells. Reporting a
        coefficient rather than a force is what makes the number comparable to
        a wind tunnel and to the literature — and what makes it a statement
        about the SHAPE rather than about this particular grid."""
        if u_inf == 0 or area == 0:
            return 0
        return self.fx / (0.5 * u_inf * u_inf * area)

    def step(mut self):
        self.collide()
        self.stream()
        self.apply_inlet_outlet()
