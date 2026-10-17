"""Incompressible grid fluid on a 2-D MAC grid (ROADMAP 17.60), periodic.

Stable Fluids (Stam 1999) on a staggered grid: u on the x faces
(i dx, (j + 1/2) dx), v on the y faces ((i + 1/2) dx, j dx), pressure at the
cell centres. One `step(dt)`:

  1. advect u and v semi-Lagrangian, RK2 backtrace, bilinear (periodic);
  2. viscosity explicitly, u += nu dt lap u (raises when
     nu dt / dx^2 > 1/4, the explicit limit);
  3. the body force (fx, fy) times dt;
  4. project: solve -lap p = -div u / dt with `numerics.pcg` through a
     matrix-free 5-point operator (the periodic Laplacian is singular: the
     right-hand side's mean is removed, which CG then never re-enters),
     u -= dt grad p.

Lives in `physics`, not `fluid`: `fluid` and `numerics` share a layer and
may not import each other (ROADMAP 17.60's layering note). Semi-Lagrangian
advection adds numerical viscosity of order |u| dx / 2: decay-rate tests
keep the velocity small (test_taylor_green).
"""

from std.math import floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult


struct _NegLaplacian(LinearOperator, Movable):
    """-lap on an n x n periodic cell grid, scaled by dx^2 = 1."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def size(self) -> Int:
        return self.n * self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        var n = self.n
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                out[j * n + i] = 4 * x[j * n + i] - x[j * n + im] - x[j * n + ip] - x[jm * n + i] - x[jp * n + i]

    def diagonal(self, mut out: List[Real]):
        for k in range(self.n * self.n):
            out[k] = 4


struct MacFluid2(Movable):
    var n: Int  # cells per side
    var dx: Real
    var nu: Real  # kinematic viscosity
    var fx: Real  # body force (acceleration)
    var fy: Real
    var u: List[Real]  # [j * n + i] at (i dx, (j + 1/2) dx)
    var v: List[Real]  # [j * n + i] at ((i + 1/2) dx, j dx)
    var p: List[Real]  # last pressure (warm start), cell centres
    var last: CgResult

    def __init__(out self, n: Int, dx: Real, nu: Real) raises:
        if n < 4 or not (dx > 0) or not (nu >= 0):
            raise Error("MacFluid2: n >= 4, dx > 0, nu >= 0")
        self.n = n
        self.dx = dx
        self.nu = nu
        self.fx = 0
        self.fy = 0
        self.u = List[Real](length=n * n, fill=0)
        self.v = List[Real](length=n * n, fill=0)
        self.p = List[Real](length=n * n, fill=0)
        self.last = CgResult(True, False, 0, 0)

    def _w(self, i: Int) -> Int:
        return ((i % self.n) + self.n) % self.n

    def _bilinear(self, f: List[Real], x: Real, y: Real, ox: Real, oy: Real) -> Real:
        """Sample a staggered field whose (i, j) sample sits at
        ((i + ox) dx, (j + oy) dx)."""
        var gx = x / self.dx - ox
        var gy = y / self.dx - oy
        var i0 = Int(floor(gx))
        var j0 = Int(floor(gy))
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var n = self.n
        var a = self._w(i0)
        var b = self._w(i0 + 1)
        var c = self._w(j0)
        var d = self._w(j0 + 1)
        var lo = f[c * n + a] * (1 - ax) + f[c * n + b] * ax
        var hi = f[d * n + a] * (1 - ax) + f[d * n + b] * ax
        return lo * (1 - ay) + hi * ay

    def velocity(self, x: Real, y: Real) -> Tuple[Real, Real]:
        return (self._bilinear(self.u, x, y, 0, 0.5), self._bilinear(self.v, x, y, 0.5, 0))

    def divergence(self) -> List[Real]:
        """Per cell, (du/dx + dv/dy)."""
        var n = self.n
        var out = List[Real](length=n * n, fill=0)
        for j in range(n):
            for i in range(n):
                out[j * n + i] = (self.u[j * n + (i + 1) % n] - self.u[j * n + i] + self.v[((j + 1) % n) * n + i] - self.v[j * n + i]) / self.dx
        return out^

    def _advect(mut self, dt: Real):
        var n = self.n
        var nu_ = List[Real](length=n * n, fill=0)
        var nv_ = List[Real](length=n * n, fill=0)
        for j in range(n):
            for i in range(n):
                # u face
                var x = Real(i) * self.dx
                var y = (Real(j) + 0.5) * self.dx
                var v0 = self.velocity(x, y)
                var vm = self.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1])
                nu_[j * n + i] = self._bilinear(self.u, x - dt * vm[0], y - dt * vm[1], 0, 0.5)
                # v face
                x = (Real(i) + 0.5) * self.dx
                y = Real(j) * self.dx
                v0 = self.velocity(x, y)
                vm = self.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1])
                nv_[j * n + i] = self._bilinear(self.v, x - dt * vm[0], y - dt * vm[1], 0.5, 0)
        self.u = nu_^
        self.v = nv_^

    def _diffuse(mut self, dt: Real):
        var n = self.n
        var k = self.nu * dt / (self.dx * self.dx)
        var nu_ = self.u.copy()
        var nv_ = self.v.copy()
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                nu_[j * n + i] += k * (self.u[j * n + im] + self.u[j * n + ip] + self.u[jm * n + i] + self.u[jp * n + i] - 4 * self.u[j * n + i])
                nv_[j * n + i] += k * (self.v[j * n + im] + self.v[j * n + ip] + self.v[jm * n + i] + self.v[jp * n + i] - 4 * self.v[j * n + i])
        self.u = nu_^
        self.v = nv_^

    def project(mut self, dt: Real, tol: Real = 1e-6) -> CgResult:
        var n = self.n
        var div = self.divergence()
        # -lap p = -div / dt, in dx^2 = 1 units: rhs = -div dx^2 / dt
        var rhs = List[Real](length=n * n, fill=0)
        var mean = Real(0)
        for k in range(n * n):
            rhs[k] = -div[k] * self.dx * self.dx / dt
            mean += rhs[k]
        mean /= Real(n * n)
        for k in range(n * n):
            rhs[k] -= mean
        var op = _NegLaplacian(n)
        var r = pcg(op, rhs, self.p, tol, 4 * n * n)
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                self.u[j * n + i] -= dt * (self.p[j * n + i] - self.p[j * n + im]) / self.dx
                self.v[j * n + i] -= dt * (self.p[j * n + i] - self.p[jm * n + i]) / self.dx
        self.last = r
        return r

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("MacFluid2.step: dt must be > 0")
        if self.nu * dt / (self.dx * self.dx) > 0.25:
            raise Error("MacFluid2.step: nu dt / dx^2 > 1/4 (explicit viscosity limit)")
        self._advect(dt)
        if self.nu > 0:
            self._diffuse(dt)
        if self.fx != 0 or self.fy != 0:
            for k in range(self.n * self.n):
                self.u[k] += self.fx * dt
                self.v[k] += self.fy * dt
        _ = self.project(dt)


struct Smoke2(Movable):
    """Buoyant smoke on a `MacFluid2` (Fedkiw, Stam & Jensen 2001), 17.60.

    A temperature field `temp` at the cell centres is advected with the
    flow (semi-Lagrangian, RK2); it pushes up by Boussinesq buoyancy,
    fy = buoyancy (T - mean T) -- the mean is removed so a periodic box as
    a whole does not accelerate -- and vorticity confinement adds
    epsilon dx (N x omega) with N = grad|omega| / |grad|omega||, putting
    back the small swirls semi-Lagrangian advection smears out.
    `step(dt)` = buoyancy and confinement forces, then the fluid's step,
    then the temperature's advection. epsilon = 0 skips the confinement
    pass entirely."""

    var fluid: MacFluid2
    var temp: List[Real]
    var buoyancy: Real
    var epsilon: Real

    def __init__(out self, var fluid: MacFluid2, buoyancy: Real, epsilon: Real) raises:
        if not (epsilon >= 0):
            raise Error("Smoke2: epsilon must be >= 0")
        var n = fluid.n
        self.fluid = fluid^
        self.temp = List[Real](length=n * n, fill=0)
        self.buoyancy = buoyancy
        self.epsilon = epsilon

    def vorticity(self) -> List[Real]:
        """Vorticity dv/dx - du/dy at the cell corners (i dx, j dx)."""
        ref f = self.fluid
        var n = f.n
        var out = List[Real](length=n * n, fill=0)
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                out[j * n + i] = (f.v[j * n + i] - f.v[j * n + im] - f.u[j * n + i] + f.u[jm * n + i]) / f.dx
        return out^

    def kinetic_energy(self) -> Real:
        var e = Real(0)
        for k in range(len(self.fluid.u)):
            e += 0.5 * (self.fluid.u[k] * self.fluid.u[k] + self.fluid.v[k] * self.fluid.v[k])
        return e * self.fluid.dx * self.fluid.dx

    def _forces(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var mean = Real(0)
        for k in range(n * n):
            mean += self.temp[k]
        mean /= Real(n * n)
        # buoyancy on the v faces: temperature averaged from the two cells
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var tf = 0.5 * (self.temp[j * n + i] + self.temp[jm * n + i])
                self.fluid.v[j * n + i] += dt * self.buoyancy * (tf - mean)
        if self.epsilon <= 0:
            return
        var w = self.vorticity()  # corners
        var mag = List[Real](length=n * n, fill=0)
        for k in range(n * n):
            mag[k] = abs(w[k])
        # force at the corners, then averaged onto the faces
        var cfx = List[Real](length=n * n, fill=0)
        var cfy = List[Real](length=n * n, fill=0)
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                var gx = (mag[j * n + ip] - mag[j * n + im]) / (2 * dx)
                var gy = (mag[jp * n + i] - mag[jm * n + i]) / (2 * dx)
                var gl = sqrt(gx * gx + gy * gy) + 1e-12
                var nx = gx / gl
                var ny = gy / gl
                # (N x omega z) in 2-D: (ny omega, -nx omega)
                cfx[j * n + i] = self.epsilon * dx * ny * w[j * n + i]
                cfy[j * n + i] = -self.epsilon * dx * nx * w[j * n + i]
        for j in range(n):
            var jp = (j + 1) % n
            for i in range(n):
                var ip = (i + 1) % n
                # u face (i, j + 1/2) between corners (i, j) and (i, j + 1)
                self.fluid.u[j * n + i] += dt * 0.5 * (cfx[j * n + i] + cfx[jp * n + i])
                # v face (i + 1/2, j) between corners (i, j) and (i + 1, j)
                self.fluid.v[j * n + i] += dt * 0.5 * (cfy[j * n + i] + cfy[j * n + ip])

    def _advect_temp(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var nt = List[Real](length=n * n, fill=0)
        for j in range(n):
            for i in range(n):
                var x = (Real(i) + 0.5) * dx
                var y = (Real(j) + 0.5) * dx
                var v0 = self.fluid.velocity(x, y)
                var vm = self.fluid.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1])
                nt[j * n + i] = self.fluid._bilinear(self.temp, x - dt * vm[0], y - dt * vm[1], 0.5, 0.5)
        self.temp = nt^

    def step(mut self, dt: Real) raises:
        self._forces(dt)
        self.fluid.step(dt)
        self._advect_temp(dt)
