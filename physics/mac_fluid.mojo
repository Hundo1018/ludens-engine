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
     u -= dt grad p. `use_multigrid()` swaps Jacobi PCG for
     multigrid-preconditioned CG (`numerics.multigrid`, n a power of two):
     a near-constant iteration count instead of one growing with n
     (`bench_grid_fluid`, `test_mac_multigrid`).

Lives in `physics`, not `fluid`: `fluid` and `numerics` share a layer and
may not import each other (ROADMAP 17.60's layering note). Semi-Lagrangian
advection adds numerical viscosity of order |u| dx / 2: decay-rate tests
keep the velocity small (test_taylor_green).
"""

from std.math import ceil, floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult
from numerics.multigrid import PeriodicPoissonMG, pcg_mg


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


struct _MaskedNegLaplacian(LinearOperator, Movable):
    """-lap on the fluid cells of a periodic n x n grid (17.61 solid mask).

    A face between two fluid cells couples them. A face to a solid cell
    carries no flux (Neumann), so it leaves the stencil. Solid cells are
    identity rows, which keeps the operator nonsingular there. Symmetric
    positive semidefinite; its null space is the constant on each connected
    fluid region."""

    var n: Int
    var solid: List[Bool]

    def __init__(out self, n: Int, var solid: List[Bool]):
        self.n = n
        self.solid = solid^

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
                var k = j * n + i
                if self.solid[k]:
                    out[k] = x[k]
                    continue
                var acc = Real(0)
                if not self.solid[j * n + im]:
                    acc += x[k] - x[j * n + im]
                if not self.solid[j * n + ip]:
                    acc += x[k] - x[j * n + ip]
                if not self.solid[jm * n + i]:
                    acc += x[k] - x[jm * n + i]
                if not self.solid[jp * n + i]:
                    acc += x[k] - x[jp * n + i]
                out[k] = acc

    def diagonal(self, mut out: List[Real]):
        var n = self.n
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                var k = j * n + i
                if self.solid[k]:
                    out[k] = 1
                    continue
                var cnt = 0
                if not self.solid[j * n + im]:
                    cnt += 1
                if not self.solid[j * n + ip]:
                    cnt += 1
                if not self.solid[jm * n + i]:
                    cnt += 1
                if not self.solid[jp * n + i]:
                    cnt += 1
                out[k] = Real(cnt)


def warm_start_or_zero[Op: LinearOperator](op: Op, rhs: List[Real], mut x: List[Real]):
    """Zero `x` when it is a worse start than zero, ||b - A x|| > ||b||
    (ROADMAP 17.60). A projection warm-started from the last pressure
    after the flow has become divergence-free faces a right-hand side of
    rounding noise: the old pressure's residual is then many times ||b||,
    CG cannot reach tol ||b|| from it in f32 and breaks down, and the
    pressure it leaves injects velocity (a 2-D MAC field grew from
    |u| 0.05 to 667 in 15 steps). From zero the same solve converges."""
    var ax = List[Real](length=len(x), fill=0)
    op.apply(x, ax)
    var rr = Float64(0)
    var bb = Float64(0)
    for k in range(len(x)):
        var d = Float64(rhs[k]) - Float64(ax[k])
        rr += d * d
        bb += Float64(rhs[k]) * Float64(rhs[k])
    if rr > bb:
        for k in range(len(x)):
            x[k] = 0


def _spread_face(mut f: List[Real], n: Int, dx: Real, x: Real, y: Real, ox: Real, oy: Real, amount: Real):
    """Adjoint of `MacFluid2._bilinear`: adds `amount` to the four samples around
    (x, y), weighted as the sampling weights, so the four weights sum to one."""
    var gx = x / dx - ox
    var gy = y / dx - oy
    var i0 = Int(floor(gx))
    var j0 = Int(floor(gy))
    var ax = gx - Real(i0)
    var ay = gy - Real(j0)
    var a = ((i0 % n) + n) % n
    var b = ((i0 + 1) % n + n) % n
    var c = ((j0 % n) + n) % n
    var d = ((j0 + 1) % n + n) % n
    f[c * n + a] += amount * (1 - ax) * (1 - ay)
    f[c * n + b] += amount * ax * (1 - ay)
    f[d * n + a] += amount * (1 - ax) * ay
    f[d * n + b] += amount * ax * ay


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
    var mg: Optional[PeriodicPoissonMG]  # set by use_multigrid
    var fix_momentum: Bool  # set by use_momentum_fix
    var momentum_booked: Real  # sum of |momentum corrections| applied (x and y)
    var flux_advect: Bool  # set by use_flux_advection
    var flux_substeps: Int  # sub-steps taken by `_advect_flux`, summed
    var solid: List[Bool]  # set by set_solid; empty means no solid cell

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
        self.mg = None
        self.fix_momentum = False
        self.momentum_booked = 0
        self.flux_advect = False
        self.flux_substeps = 0
        self.solid = List[Bool]()

    def set_solid(mut self, var mask: List[Bool]) raises:
        """Mark cells solid (opt-in; the default empty mask leaves the solver
        unchanged). Faces that touch a solid cell carry no normal flux: they
        are zeroed before each projection and the pressure solve treats them
        as walls. Every fluid cell needs a fluid neighbour, so the operator has
        no empty row. Not available with multigrid."""
        var n = self.n
        if len(mask) != n * n:
            raise Error("MacFluid2.set_solid: mask length must be n * n")
        if self.mg:
            raise Error("MacFluid2.set_solid: the solid mask is not supported with multigrid")
        var fluid = 0
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                if mask[j * n + i]:
                    continue
                fluid += 1
                var nb = 0
                if not mask[j * n + im]:
                    nb += 1
                if not mask[j * n + ip]:
                    nb += 1
                if not mask[jm * n + i]:
                    nb += 1
                if not mask[jp * n + i]:
                    nb += 1
                if nb == 0:
                    raise Error("MacFluid2.set_solid: a fluid cell has no fluid neighbour")
        if fluid == 0:
            raise Error("MacFluid2.set_solid: the mask leaves no fluid cell")
        self.solid = mask^

    def use_momentum_fix(mut self):
        """Restore the total momentum after each advection (opt-in; off by
        default so the semi-Lagrangian default path is unchanged). The applied
        corrections are summed in `momentum_booked`."""
        self.fix_momentum = True

    def use_flux_advection(mut self):
        """Advect the faces in flux form, `_advect_flux`, instead of
        semi-Lagrangian (opt-in; off by default). Total momentum is conserved
        by construction, so `momentum_booked` stays zero on this path."""
        self.flux_advect = True

    def momentum(self) -> Tuple[Real, Real]:
        """Total (sum u dx^2, sum v dx^2), accumulated in f64."""
        var sx = Float64(0)
        var sy = Float64(0)
        for k in range(self.n * self.n):
            sx += Float64(self.u[k])
            sy += Float64(self.v[k])
        var a = Real(sx * Float64(self.dx) * Float64(self.dx))
        var b = Real(sy * Float64(self.dx) * Float64(self.dx))
        return (a, b)

    def use_multigrid(mut self) raises:
        """Project with MGPCG from now on; raises unless n is a power of two.
        Not available once a solid mask is set."""
        if len(self.solid) > 0:
            raise Error("MacFluid2.use_multigrid: not supported with a solid mask")
        self.mg = PeriodicPoissonMG(self.n)

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

    def add_impulse(mut self, x: Real, y: Real, ix: Real, iy: Real):
        """Adds the momentum impulse (ix, iy) per unit density at the point (x, y).
        The impulse is spread onto the staggered faces with the velocity-sampling
        weights, so the total momentum sum(u) dx^2 rises by exactly ix (and
        sum(v) dx^2 by iy); density is 1, as in the rest of this struct."""
        var inv = 1 / (self.dx * self.dx)
        _spread_face(self.u, self.n, self.dx, x, y, 0, 0.5, ix * inv)
        _spread_face(self.v, self.n, self.dx, x, y, 0.5, 0, iy * inv)

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

    def _zero_solid_faces(mut self):
        """Hold the normal velocity on every face that touches a solid cell at
        zero (the u face on a cell's left and right, the v face below and
        above it)."""
        var n = self.n
        for j in range(n):
            var jp = (j + 1) % n
            for i in range(n):
                var k = j * n + i
                if not self.solid[k]:
                    continue
                var ip = (i + 1) % n
                self.u[k] = 0
                self.u[j * n + ip] = 0
                self.v[k] = 0
                self.v[jp * n + i] = 0

    def project(mut self, dt: Real, tol: Real = 1e-6) -> CgResult:
        var n = self.n
        var masked = len(self.solid) > 0
        if masked:
            self._zero_solid_faces()
        var div = self.divergence()
        # -lap p = -div / dt, in dx^2 = 1 units: rhs = -div dx^2 / dt
        var rhs = List[Real](length=n * n, fill=0)
        # The periodic Laplacian is singular: remove the mean in f64. An f32
        # sum over n^2 cells left a mean of ~n^2 eps |rhs| that CG cannot
        # reduce, so it never met tol, ran 4 n^2 iterations, and the constant
        # it piled into p cost f32 its pressure differences (a heated row
        # under Smoke2 blew up to 1e11 m/s in 0.3 s; 17.61). With solid cells
        # the mean runs over the fluid cells only, and solid rows stay zero.
        var fluid = 0
        for k in range(n * n):
            if not masked or not self.solid[k]:
                fluid += 1
        var mean = Float64(0)
        for k in range(n * n):
            if masked and self.solid[k]:
                continue
            rhs[k] = -div[k] * self.dx * self.dx / dt
            mean += Float64(rhs[k])
        mean /= Float64(fluid)
        for k in range(n * n):
            if masked and self.solid[k]:
                continue
            rhs[k] = Real(Float64(rhs[k]) - mean)
        var r: CgResult
        if masked:
            var mop = _MaskedNegLaplacian(n, self.solid.copy())
            warm_start_or_zero(mop, rhs, self.p)
            r = pcg(mop, rhs, self.p, tol, 4 * n * n)
        else:
            var op = _NegLaplacian(n)
            warm_start_or_zero(op, rhs, self.p)
            if case .Some(ref mg) = self.mg:
                r = pcg_mg(op, mg, rhs, self.p, tol, 4 * n * n)
            else:
                r = pcg(op, rhs, self.p, tol, 4 * n * n)
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var k = j * n + i
                var kl = j * n + im
                var kd = jm * n + i
                # A face that touches a solid cell keeps its zero normal velocity.
                if not masked or not (self.solid[k] or self.solid[kl]):
                    self.u[k] -= dt * (self.p[k] - self.p[kl]) / self.dx
                if not masked or not (self.solid[k] or self.solid[kd]):
                    self.v[k] -= dt * (self.p[k] - self.p[kd]) / self.dx
        self.last = r
        return r

    def _advect_flux(mut self, dt: Real):
        """Flux-form (finite-volume) advection, first-order upwind (17.61).

        Each face is advected through its own control volume: the u face at
        (i, j + 1/2) owns [i - 1/2, i + 1/2] x [j, j + 1]; the v face at
        (i + 1/2, j) owns [i, i + 1] x [j - 1/2, j + 1/2]. The advecting speed
        on each side is the average of the two staggered components there, and
        the advected value is taken upwind. The flux through a shared side is
        computed once from the same arrays by both neighbours, so the periodic
        sum over the grid telescopes: total momentum is conserved to rounding
        with no correction term. The scheme is first order and therefore
        diffusive: the upwind value is the cell value, not an interpolated
        one, which dissipates small-scale swirl that semi-Lagrangian keeps.
        Explicit and unsplit, so stability needs 2 |u|max h <= 1 (h = sub-step
        dt / dx). The step is sub-cycled: the count is ceil(2 |u|max dt / dx),
        and each sub-step is itself a conservative flux update, so the total is
        still conserved. Without sub-cycling the 17.61 k = 5 run goes to NaN
        within 3 steps (face speeds reach 1000 m/s against dx / dt = 3.75)."""
        var umax = Real(0)
        for c in range(self.n * self.n):
            umax = max(umax, max(abs(self.u[c]), abs(self.v[c])))
        var need = 2 * umax * dt / self.dx
        var sub = 1
        if need > 1:
            sub = Int(ceil(need))
        var h = dt / Real(sub) / self.dx
        self.flux_substeps += sub
        for _ in range(sub):
            self._flux_once(h)

    def _flux_once(mut self, h: Real):
        """One conservative flux update with step h = sub-step / dx."""
        var n = self.n
        var u0 = self.u.copy()
        var v0 = self.v.copy()
        var nu_ = List[Real](length=n * n, fill=0)
        var nv_ = List[Real](length=n * n, fill=0)
        for j in range(n):
            var jm = self._w(j - 1)
            var jp = self._w(j + 1)
            for i in range(n):
                var im = self._w(i - 1)
                var ip = self._w(i + 1)
                # u face: east / west sides at x = i +- 1/2, speed from u
                var c = j * n + i
                var ue = 0.5 * (u0[c] + u0[j * n + ip])
                var fe = ue * (u0[c] if ue > 0 else u0[j * n + ip])
                var uw = 0.5 * (u0[j * n + im] + u0[c])
                var fw = uw * (u0[j * n + im] if uw > 0 else u0[c])
                # u face: north / south sides at y = j + 1, j, speed from v at x = i +- 1/2
                var vn = 0.5 * (v0[jp * n + im] + v0[jp * n + i])
                var fnorth = vn * (u0[c] if vn > 0 else u0[jp * n + i])
                var vs = 0.5 * (v0[j * n + im] + v0[j * n + i])
                var fs = vs * (u0[jm * n + i] if vs > 0 else u0[c])
                nu_[c] = u0[c] - h * ((fe - fw) + (fnorth - fs))
                # v face: east / west sides at x = i + 1, i, speed from u at y = j +- 1/2
                var ve = 0.5 * (u0[jm * n + ip] + u0[j * n + ip])
                var ge = ve * (v0[c] if ve > 0 else v0[j * n + ip])
                var vw = 0.5 * (u0[jm * n + i] + u0[j * n + i])
                var gw = vw * (v0[j * n + im] if vw > 0 else v0[c])
                # v face: north / south sides at y = j + 1/2, j - 1/2, speed from v
                var vv_n = 0.5 * (v0[c] + v0[jp * n + i])
                var gn = vv_n * (v0[c] if vv_n > 0 else v0[jp * n + i])
                var vv_s = 0.5 * (v0[jm * n + i] + v0[c])
                var gs = vv_s * (v0[jm * n + i] if vv_s > 0 else v0[c])
                nv_[c] = v0[c] - h * ((ge - gw) + (gn - gs))
        self.u = nu_^
        self.v = nv_^

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("MacFluid2.step: dt must be > 0")
        if self.nu * dt / (self.dx * self.dx) > 0.25:
            raise Error("MacFluid2.step: nu dt / dx^2 > 1/4 (explicit viscosity limit)")
        var m0 = self.momentum() if self.fix_momentum else (Real(0), Real(0))
        if self.flux_advect:
            self._advect_flux(dt)
        else:
            self._advect(dt)
        if self.fix_momentum:
            # Semi-Lagrangian advection changes sum(u) and sum(v) by the
            # interpolation residual, though the periodic box has no external
            # momentum source. Shift every face by the same amount so the total
            # matches m0. A constant has zero divergence on the periodic grid,
            # so the projection is unaffected. This restores the total only:
            # the local distribution keeps the advection error.
            var m1 = self.momentum()
            var cells = Real(self.n * self.n) * self.dx * self.dx
            var du = (m0[0] - m1[0]) / cells
            var dv = (m0[1] - m1[1]) / cells
            for k in range(self.n * self.n):
                self.u[k] += du
                self.v[k] += dv
            self.momentum_booked += abs(m0[0] - m1[0]) + abs(m0[1] - m1[1])
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
