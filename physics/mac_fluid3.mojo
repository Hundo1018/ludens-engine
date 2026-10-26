"""Incompressible grid fluid on a 3-D MAC grid, periodic, and buoyant smoke
on it (ROADMAP 17.60: 3-D single-phase MAC).

`MacFluid2` in three dimensions: u on the x faces (i, j + 1/2, k + 1/2) dx,
v on the y faces, w on the z faces, pressure at the cell centres. One
`step(dt)`:

  1. advect u, v, w semi-Lagrangian, RK2 backtrace, trilinear (periodic);
  2. viscosity explicitly, u += nu dt lap u (raises when
     nu dt / dx^2 > 1/6, the explicit limit in 3-D);
  3. the body force (fx, fy, fz) times dt;
  4. project: -lap p = -div u / dt with `numerics.pcg` through a
     matrix-free 7-point operator, right-hand side mean removed in f64 (the
     periodic Laplacian is singular; see `MacFluid2.project`), warm-started
     from the last pressure unless that is a worse start than zero
     (`mac_fluid.warm_start_or_zero`), then u -= dt grad p.

`Smoke3`: a cell-centred temperature advected with the flow (RK2,
trilinear) pushes the v faces by Boussinesq buoyancy,
fy = buoyancy (T - mean T); the mean is removed so the periodic box as a
whole does not accelerate.

Vorticity confinement (17.60, opt-in): `set_confinement(eps)` adds
eps dx (N x omega) to the body force, N = grad|omega| / |grad|omega|, with
omega the curl of the cell-centred velocity (central differences). eps = 0
(the default) skips it, so the off path is the same code as before. The
2-D version is `Smoke2`'s `_forces` in `mac_fluid.mojo`; this one works at the
cell centres instead of the corners.

A field that does not vary along z, with w = 0, steps like `MacFluid2`
(`test_mac_fluid3` compares them; equal to the CG tolerance, not bit for
bit -- the 3-D solve sums over n^3 cells).
"""

from std.math import ceil, floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult
from numerics.multigrid3 import PeriodicPoissonMG3, pcg_mg3
from .mac_fluid import warm_start_or_zero


struct _NegLaplacian3(LinearOperator, Movable):
    """-lap on an n^3 periodic cell grid, scaled by dx^2 = 1."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def size(self) -> Int:
        return self.n * self.n * self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        var n = self.n
        for k in range(n):
            var km = (k + n - 1) % n
            var kp = (k + 1) % n
            for j in range(n):
                var jm = (j + n - 1) % n
                var jp = (j + 1) % n
                for i in range(n):
                    var im = (i + n - 1) % n
                    var ip = (i + 1) % n
                    var c = (k * n + j) * n + i
                    out[c] = (
                        6 * x[c]
                        - x[(k * n + j) * n + im] - x[(k * n + j) * n + ip]
                        - x[(k * n + jm) * n + i] - x[(k * n + jp) * n + i]
                        - x[(km * n + j) * n + i] - x[(kp * n + j) * n + i]
                    )

    def diagonal(self, mut out: List[Real]):
        for c in range(self.n * self.n * self.n):
            out[c] = 6


struct MacFluid3(Movable):
    var n: Int  # cells per side
    var dx: Real
    var nu: Real
    var fx: Real
    var fy: Real
    var fz: Real
    var epsilon: Real  # vorticity confinement strength, 0 = off
    var u: List[Real]  # [(k n + j) n + i] at (i, j + 1/2, k + 1/2) dx
    var v: List[Real]  # at (i + 1/2, j, k + 1/2) dx
    var w: List[Real]  # at (i + 1/2, j + 1/2, k) dx
    var p: List[Real]  # cell centres, warm start
    var last: CgResult
    var mg: Optional[PeriodicPoissonMG3]  # set by use_multigrid
    var flux_advect: Bool  # set by use_flux_advection

    def __init__(out self, n: Int, dx: Real, nu: Real) raises:
        if n < 4 or not (dx > 0) or not (nu >= 0):
            raise Error("MacFluid3: n >= 4, dx > 0, nu >= 0")
        self.n = n
        self.dx = dx
        self.nu = nu
        self.fx = 0
        self.fy = 0
        self.fz = 0
        self.epsilon = 0
        var m = n * n * n
        self.u = List[Real](length=m, fill=0)
        self.v = List[Real](length=m, fill=0)
        self.w = List[Real](length=m, fill=0)
        self.p = List[Real](length=m, fill=0)
        self.last = CgResult(True, False, 0, 0)
        self.mg = None
        self.flux_advect = False

    def cells(self) -> Int:
        return self.n * self.n * self.n

    def use_multigrid(mut self) raises:
        """Project with MGPCG from now on; raises unless n is a power of two."""
        self.mg = PeriodicPoissonMG3(self.n)

    def use_flux_advection(mut self):
        """Advect the faces in flux form, `_advect_flux` (opt-in; off by
        default). Total momentum is conserved by construction."""
        self.flux_advect = True

    def set_confinement(mut self, eps: Real) raises:
        if not (eps >= 0):
            raise Error("MacFluid3.set_confinement: eps must be >= 0")
        self.epsilon = eps

    def _centre_velocity(self) -> Tuple[List[Real], List[Real], List[Real]]:
        """Face velocities averaged to the cell centres."""
        var m = self.cells()
        var uc = List[Real](length=m, fill=0)
        var vc = List[Real](length=m, fill=0)
        var wc = List[Real](length=m, fill=0)
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var c = self.idx(i, j, k)
                    uc[c] = 0.5 * (self.u[c] + self.u[self.idx(i + 1, j, k)])
                    vc[c] = 0.5 * (self.v[c] + self.v[self.idx(i, j + 1, k)])
                    wc[c] = 0.5 * (self.w[c] + self.w[self.idx(i, j, k + 1)])
        return (uc^, vc^, wc^)

    def vorticity(self) -> Tuple[List[Real], List[Real], List[Real]]:
        """Curl of the cell-centred velocity (central differences, periodic)."""
        var vel = self._centre_velocity()
        ref uc = vel[0]
        ref vc = vel[1]
        ref wc = vel[2]
        var m = self.cells()
        var ox = List[Real](length=m, fill=0)
        var oy = List[Real](length=m, fill=0)
        var oz = List[Real](length=m, fill=0)
        var h = 2 * self.dx
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var c = self.idx(i, j, k)
                    ox[c] = (wc[self.idx(i, j + 1, k)] - wc[self.idx(i, j - 1, k)]) / h - (vc[self.idx(i, j, k + 1)] - vc[self.idx(i, j, k - 1)]) / h
                    oy[c] = (uc[self.idx(i, j, k + 1)] - uc[self.idx(i, j, k - 1)]) / h - (wc[self.idx(i + 1, j, k)] - wc[self.idx(i - 1, j, k)]) / h
                    oz[c] = (vc[self.idx(i + 1, j, k)] - vc[self.idx(i - 1, j, k)]) / h - (uc[self.idx(i, j + 1, k)] - uc[self.idx(i, j - 1, k)]) / h
        return (ox^, oy^, oz^)

    def enstrophy(self) -> Real:
        """Sum of |omega|^2 over the cells, times dx^3."""
        var om = self.vorticity()
        ref ox = om[0]
        ref oy = om[1]
        ref oz = om[2]
        var e = Real(0)
        for c in range(self.cells()):
            e += ox[c] * ox[c] + oy[c] * oy[c] + oz[c] * oz[c]
        return e * self.dx * self.dx * self.dx

    def _confine(mut self, dt: Real):
        """Adds dt eps dx (N x omega) to the faces; the force is taken from the
        velocity at the start of the call, all components before any face moves."""
        var n = self.n
        var m = self.cells()
        var dx = self.dx
        var om = self.vorticity()
        ref ox = om[0]
        ref oy = om[1]
        ref oz = om[2]
        var mag = List[Real](length=m, fill=0)
        for c in range(m):
            mag[c] = sqrt(ox[c] * ox[c] + oy[c] * oy[c] + oz[c] * oz[c])
        var fx = List[Real](length=m, fill=0)
        var fy = List[Real](length=m, fill=0)
        var fz = List[Real](length=m, fill=0)
        var h = 2 * dx
        var scale = self.epsilon * dx
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = self.idx(i, j, k)
                    var gx = (mag[self.idx(i + 1, j, k)] - mag[self.idx(i - 1, j, k)]) / h
                    var gy = (mag[self.idx(i, j + 1, k)] - mag[self.idx(i, j - 1, k)]) / h
                    var gz = (mag[self.idx(i, j, k + 1)] - mag[self.idx(i, j, k - 1)]) / h
                    var gl = sqrt(gx * gx + gy * gy + gz * gz) + 1e-12
                    var nx = gx / gl
                    var ny = gy / gl
                    var nz = gz / gl
                    var wx = ox[c]
                    var wy = oy[c]
                    var wz = oz[c]
                    fx[c] = scale * (ny * wz - nz * wy)
                    fy[c] = scale * (nz * wx - nx * wz)
                    fz[c] = scale * (nx * wy - ny * wx)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = self.idx(i, j, k)
                    # each face sits between the two cells on either side of it
                    self.u[c] += dt * 0.5 * (fx[self.idx(i - 1, j, k)] + fx[c])
                    self.v[c] += dt * 0.5 * (fy[self.idx(i, j - 1, k)] + fy[c])
                    self.w[c] += dt * 0.5 * (fz[self.idx(i, j, k - 1)] + fz[c])

    def idx(self, i: Int, j: Int, k: Int) -> Int:
        var n = self.n
        return ((((k % n) + n) % n) * n + (((j % n) + n) % n)) * n + (((i % n) + n) % n)

    def sample(self, f: List[Real], x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real) -> Real:
        """Trilinear sample of a field whose (i, j, k) value sits at
        ((i + ox) dx, (j + oy) dx, (k + oz) dx)."""
        var gx = x / self.dx - ox
        var gy = y / self.dx - oy
        var gz = z / self.dx - oz
        var i0 = Int(floor(gx))
        var j0 = Int(floor(gy))
        var k0 = Int(floor(gz))
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var az = gz - Real(k0)
        var c00 = f[self.idx(i0, j0, k0)] * (1 - ax) + f[self.idx(i0 + 1, j0, k0)] * ax
        var c10 = f[self.idx(i0, j0 + 1, k0)] * (1 - ax) + f[self.idx(i0 + 1, j0 + 1, k0)] * ax
        var c01 = f[self.idx(i0, j0, k0 + 1)] * (1 - ax) + f[self.idx(i0 + 1, j0, k0 + 1)] * ax
        var c11 = f[self.idx(i0, j0 + 1, k0 + 1)] * (1 - ax) + f[self.idx(i0 + 1, j0 + 1, k0 + 1)] * ax
        var lo = c00 * (1 - ay) + c10 * ay
        var hi = c01 * (1 - ay) + c11 * ay
        return lo * (1 - az) + hi * az

    def velocity(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        return (
            self.sample(self.u, x, y, z, 0, 0.5, 0.5),
            self.sample(self.v, x, y, z, 0.5, 0, 0.5),
            self.sample(self.w, x, y, z, 0.5, 0.5, 0),
        )

    def divergence(self) -> List[Real]:
        var n = self.n
        var out = List[Real](length=self.cells(), fill=0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    out[c] = (
                        self.u[self.idx(i + 1, j, k)] - self.u[c]
                        + self.v[self.idx(i, j + 1, k)] - self.v[c]
                        + self.w[self.idx(i, j, k + 1)] - self.w[c]
                    ) / self.dx
        return out^

    def _back(self, x: Real, y: Real, z: Real, dt: Real) -> Tuple[Real, Real, Real]:
        """RK2 (midpoint) backtrace of the point (x, y, z) over dt."""
        var v0 = self.velocity(x, y, z)
        var vm = self.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1], z - 0.5 * dt * v0[2])
        return (x - dt * vm[0], y - dt * vm[1], z - dt * vm[2])

    def _advect(mut self, dt: Real):
        var n = self.n
        var dx = self.dx
        var nu_ = List[Real](length=self.cells(), fill=0)
        var nv_ = List[Real](length=self.cells(), fill=0)
        var nw_ = List[Real](length=self.cells(), fill=0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var b = self._back(Real(i) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nu_[c] = self.sample(self.u, b[0], b[1], b[2], 0, 0.5, 0.5)
                    b = self._back((Real(i) + 0.5) * dx, Real(j) * dx, (Real(k) + 0.5) * dx, dt)
                    nv_[c] = self.sample(self.v, b[0], b[1], b[2], 0.5, 0, 0.5)
                    b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, Real(k) * dx, dt)
                    nw_[c] = self.sample(self.w, b[0], b[1], b[2], 0.5, 0.5, 0)
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def _lap(self, f: List[Real], i: Int, j: Int, k: Int) -> Real:
        return (
            f[self.idx(i - 1, j, k)] + f[self.idx(i + 1, j, k)]
            + f[self.idx(i, j - 1, k)] + f[self.idx(i, j + 1, k)]
            + f[self.idx(i, j, k - 1)] + f[self.idx(i, j, k + 1)]
            - 6 * f[self.idx(i, j, k)]
        )

    def _diffuse(mut self, dt: Real):
        var n = self.n
        var a = self.nu * dt / (self.dx * self.dx)
        var nu_ = self.u.copy()
        var nv_ = self.v.copy()
        var nw_ = self.w.copy()
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    nu_[c] += a * self._lap(self.u, i, j, k)
                    nv_[c] += a * self._lap(self.v, i, j, k)
                    nw_[c] += a * self._lap(self.w, i, j, k)
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def project(mut self, dt: Real, tol: Real = 1e-6) -> CgResult:
        var n = self.n
        var m = self.cells()
        var div = self.divergence()
        var rhs = List[Real](length=m, fill=0)
        var mean = Float64(0)
        for c in range(m):
            rhs[c] = -div[c] * self.dx * self.dx / dt
            mean += Float64(rhs[c])
        mean /= Float64(m)
        for c in range(m):
            rhs[c] = Real(Float64(rhs[c]) - mean)
        var op = _NegLaplacian3(n)
        warm_start_or_zero(op, rhs, self.p)
        var r: CgResult
        if self.mg:
            r = pcg_mg3(op, self.mg.value(), rhs, self.p, tol, 4 * m)
        else:
            r = pcg(op, rhs, self.p, tol, 4 * m)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    self.u[c] -= dt * (self.p[c] - self.p[self.idx(i - 1, j, k)]) / self.dx
                    self.v[c] -= dt * (self.p[c] - self.p[self.idx(i, j - 1, k)]) / self.dx
                    self.w[c] -= dt * (self.p[c] - self.p[self.idx(i, j, k - 1)]) / self.dx
        self.last = r
        return r

    def _advect_flux(mut self, dt: Real):
        """Flux-form advection, first-order upwind, finite volume (17.61 in 3-D).

        Each face owns the control volume around it: the u face at
        (i, j + 1/2, k + 1/2) owns [i - 1/2, i + 1/2] x [j, j + 1] x [k, k + 1],
        and v and w are the same with their roles permuted. Each side's
        advecting speed is the average of the staggered components there, and
        the advected value is upwind. A shared side is evaluated once by each
        neighbour from the same arrays, so the periodic sum telescopes and total
        momentum is conserved to rounding. Explicit and unsplit: stability needs
        3 |u|max h <= 1, so the step is sub-cycled ceil(3 |u|max dt / dx) times,
        and each sub-step is itself conservative. First order, hence diffusive."""
        var umax = Real(0)
        for c in range(self.cells()):
            umax = max(umax, max(abs(self.u[c]), max(abs(self.v[c]), abs(self.w[c]))))
        var need = 3 * umax * dt / self.dx
        var sub = 1
        if need > 1:
            sub = Int(ceil(need))
        var h = dt / Real(sub) / self.dx
        for _ in range(sub):
            self._flux_once(h)

    def _flux_once(mut self, h: Real):
        """One conservative flux update with step h = sub-step / dx."""
        var m = self.cells()
        var u0 = self.u.copy()
        var v0 = self.v.copy()
        var w0 = self.w.copy()
        var nu_ = List[Real](length=m, fill=0)
        var nv_ = List[Real](length=m, fill=0)
        var nw_ = List[Real](length=m, fill=0)
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    # u face: x sides speed from u; y sides from v; z sides from w
                    var c = self.idx(i, j, k)
                    var ue = 0.5 * (u0[c] + u0[self.idx(i + 1, j, k)])
                    var fe = ue * (u0[c] if ue > 0 else u0[self.idx(i + 1, j, k)])
                    var uw = 0.5 * (u0[self.idx(i - 1, j, k)] + u0[c])
                    var fw = uw * (u0[self.idx(i - 1, j, k)] if uw > 0 else u0[c])
                    var vn = 0.5 * (v0[self.idx(i - 1, j + 1, k)] + v0[self.idx(i, j + 1, k)])
                    var fnorth = vn * (u0[c] if vn > 0 else u0[self.idx(i, j + 1, k)])
                    var vs = 0.5 * (v0[self.idx(i - 1, j, k)] + v0[c])
                    var fs = vs * (u0[self.idx(i, j - 1, k)] if vs > 0 else u0[c])
                    var wt = 0.5 * (w0[self.idx(i - 1, j, k + 1)] + w0[self.idx(i, j, k + 1)])
                    var ft = wt * (u0[c] if wt > 0 else u0[self.idx(i, j, k + 1)])
                    var wb = 0.5 * (w0[self.idx(i - 1, j, k)] + w0[c])
                    var fb = wb * (u0[self.idx(i, j, k - 1)] if wb > 0 else u0[c])
                    nu_[c] = u0[c] - h * ((fe - fw) + (fnorth - fs) + (ft - fb))
                    # v face: x sides speed from u; y sides from v; z sides from w
                    ue = 0.5 * (u0[self.idx(i + 1, j - 1, k)] + u0[self.idx(i + 1, j, k)])
                    fe = ue * (v0[c] if ue > 0 else v0[self.idx(i + 1, j, k)])
                    uw = 0.5 * (u0[self.idx(i, j - 1, k)] + u0[c])
                    fw = uw * (v0[self.idx(i - 1, j, k)] if uw > 0 else v0[c])
                    var vnv = 0.5 * (v0[c] + v0[self.idx(i, j + 1, k)])
                    fnorth = vnv * (v0[c] if vnv > 0 else v0[self.idx(i, j + 1, k)])
                    var vsv = 0.5 * (v0[self.idx(i, j - 1, k)] + v0[c])
                    fs = vsv * (v0[self.idx(i, j - 1, k)] if vsv > 0 else v0[c])
                    wt = 0.5 * (w0[self.idx(i, j - 1, k + 1)] + w0[self.idx(i, j, k + 1)])
                    ft = wt * (v0[c] if wt > 0 else v0[self.idx(i, j, k + 1)])
                    wb = 0.5 * (w0[self.idx(i, j - 1, k)] + w0[c])
                    fb = wb * (v0[self.idx(i, j, k - 1)] if wb > 0 else v0[c])
                    nv_[c] = v0[c] - h * ((fe - fw) + (fnorth - fs) + (ft - fb))
                    # w face: x sides speed from u; y sides from v; z sides from w
                    ue = 0.5 * (u0[self.idx(i + 1, j, k - 1)] + u0[self.idx(i + 1, j, k)])
                    fe = ue * (w0[c] if ue > 0 else w0[self.idx(i + 1, j, k)])
                    uw = 0.5 * (u0[self.idx(i, j, k - 1)] + u0[c])
                    fw = uw * (w0[self.idx(i - 1, j, k)] if uw > 0 else w0[c])
                    vn = 0.5 * (v0[self.idx(i, j + 1, k - 1)] + v0[self.idx(i, j + 1, k)])
                    fnorth = vn * (w0[c] if vn > 0 else w0[self.idx(i, j + 1, k)])
                    vs = 0.5 * (v0[self.idx(i, j, k - 1)] + v0[c])
                    fs = vs * (w0[self.idx(i, j - 1, k)] if vs > 0 else w0[c])
                    var wtw = 0.5 * (w0[c] + w0[self.idx(i, j, k + 1)])
                    ft = wtw * (w0[c] if wtw > 0 else w0[self.idx(i, j, k + 1)])
                    var wbw = 0.5 * (w0[self.idx(i, j, k - 1)] + w0[c])
                    fb = wbw * (w0[self.idx(i, j, k - 1)] if wbw > 0 else w0[c])
                    nw_[c] = w0[c] - h * ((fe - fw) + (fnorth - fs) + (ft - fb))
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("MacFluid3.step: dt must be > 0")
        if self.nu * dt / (self.dx * self.dx) > Real(1.0 / 6.0):
            raise Error("MacFluid3.step: nu dt / dx^2 > 1/6 (explicit viscosity limit)")
        if self.flux_advect:
            self._advect_flux(dt)
        else:
            self._advect(dt)
        if self.nu > 0:
            self._diffuse(dt)
        if self.fx != 0 or self.fy != 0 or self.fz != 0:
            for c in range(self.cells()):
                self.u[c] += self.fx * dt
                self.v[c] += self.fy * dt
                self.w[c] += self.fz * dt
        if self.epsilon > 0:
            self._confine(dt)
        _ = self.project(dt)

    def kinetic_energy(self) -> Real:
        var e = Real(0)
        for c in range(self.cells()):
            e += 0.5 * (self.u[c] * self.u[c] + self.v[c] * self.v[c] + self.w[c] * self.w[c])
        return e * self.dx * self.dx * self.dx


struct Smoke3(Movable):
    var fluid: MacFluid3
    var temp: List[Real]
    var buoyancy: Real

    def __init__(out self, var fluid: MacFluid3, buoyancy: Real):
        var m = fluid.cells()
        self.fluid = fluid^
        self.temp = List[Real](length=m, fill=0)
        self.buoyancy = buoyancy

    def _buoyancy(mut self, dt: Real):
        var n = self.fluid.n
        var m = self.fluid.cells()
        var mean = Float64(0)
        for c in range(m):
            mean += Float64(self.temp[c])
        var tm = Real(mean / Float64(m))
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var tf = 0.5 * (self.temp[c] + self.temp[self.fluid.idx(i, j - 1, k)])
                    self.fluid.v[c] += dt * self.buoyancy * (tf - tm)

    def _advect_temp(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var nt = List[Real](length=self.fluid.cells(), fill=0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var b = self.fluid._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nt[(k * n + j) * n + i] = self.fluid.sample(self.temp, b[0], b[1], b[2], 0.5, 0.5, 0.5)
        self.temp = nt^

    def step(mut self, dt: Real) raises:
        self._buoyancy(dt)
        self.fluid.step(dt)
        self._advect_temp(dt)

    def heat_centre_y(self) -> Real:
        """Temperature-weighted mean height of the cells above the mean
        temperature (where the hot blob is), in metres."""
        var n = self.fluid.n
        var m = self.fluid.cells()
        var mean = Float64(0)
        for c in range(m):
            mean += Float64(self.temp[c])
        mean /= Float64(m)
        var sw = Float64(0)
        var sy = Float64(0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var t = Float64(self.temp[(k * n + j) * n + i]) - mean
                    if t > 0:
                        sw += t
                        sy += t * (Float64(j) + 0.5)
        return Real(sy / sw) * self.fluid.dx if sw > 0 else Real(0)
