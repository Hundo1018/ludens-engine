"""Constitutive models for tetrahedral FEM (ROADMAP 17.58).

`FemBody.elastic_forces` hard-codes co-rotational linear elasticity. That
model is cheap and exact under rigid rotation, but it measures strain
linearly in the unrotated frame, so under large compression or inversion its
answer depends on what the polar decomposition does with det F <= 0. This
module puts the stress law behind a trait, chosen at compile time:

  * `Corotational`: P = 2 mu (F - R) + lambda tr(R^T F - I) R
    (the model `FemBody` already uses; same numbers).
  * `StableNeoHookean` (Smith, de Goes, Kim 2018, without the log term):
    Psi = mu/2 (I_C - 3) + lambda_s/2 (J - alpha)^2,
    P = mu F + lambda_s (J - alpha) cof(F), lambda_s = lambda + mu,
    alpha = 1 + mu / lambda_s. Rest-stable (P(I) = 0), matches linear
    elasticity at small strain, and defined for J <= 0 (cof(F) needs no
    inverse), so an inverted element is pushed back out.
  * `StVK`: P = F (2 mu E + lambda tr(E) I), E = (F^T F - I) / 2. Rotation
    invariant and exact at small strain, but its energy has a minimum at
    the fully collapsed state: under strong compression the force turns
    toward collapse. Kept as the control that shows what the stable model
    buys.

All three agree at small strain and give zero force under a rigid rotation
(`test_fem_material`); they differ under large compression, which is the
point of the seam.

IMPLICIT NEO-HOOKEAN (17.58). `step_implicit_nh` is `FemBody.step_implicit`'s
linearised backward Euler with the stable Neo-Hookean tangent in place of
the co-rotational one. `NhImplicitOp` applies dP = mu dF + lambda_s
(cof F : dF) cof F + lambda_s (J - alpha) d cof(F)[dF] matrix-free, where
cof F's columns are f1 x f2, f2 x f0, f0 x f1 (f_i the columns of F), so
d cof is a sum of cross products. The tangent is symmetric (an energy
Hessian) but indefinite under compression (the (J - alpha) d cof term), so
the solve is `numerics.minres`, not CG (`test_fem_nh_implicit`).
"""

from geometry.vec import Real, Vec3, cross
from geometry.mat import Mat3
from .fem import FemBody, polar_rotation, det3
from numerics.sparse import LinearOperator
from numerics.cg import CgResult
from numerics.minres import minres
from diag.counters import CG_NOT_CONVERGED


trait Material:
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3: ...

    @staticmethod
    def name() -> String: ...


def cofactor(f: Mat3) -> Mat3:
    """The cofactor matrix d det(F) / dF = det(F) F^-T, computed without the inverse so
    it stays finite at det F = 0."""
    var c = Mat3()
    c.set(0, 0, f.get(1, 1) * f.get(2, 2) - f.get(1, 2) * f.get(2, 1))
    c.set(0, 1, f.get(1, 2) * f.get(2, 0) - f.get(1, 0) * f.get(2, 2))
    c.set(0, 2, f.get(1, 0) * f.get(2, 1) - f.get(1, 1) * f.get(2, 0))
    c.set(1, 0, f.get(0, 2) * f.get(2, 1) - f.get(0, 1) * f.get(2, 2))
    c.set(1, 1, f.get(0, 0) * f.get(2, 2) - f.get(0, 2) * f.get(2, 0))
    c.set(1, 2, f.get(0, 1) * f.get(2, 0) - f.get(0, 0) * f.get(2, 1))
    c.set(2, 0, f.get(0, 1) * f.get(1, 2) - f.get(0, 2) * f.get(1, 1))
    c.set(2, 1, f.get(0, 2) * f.get(1, 0) - f.get(0, 0) * f.get(1, 2))
    c.set(2, 2, f.get(0, 0) * f.get(1, 1) - f.get(0, 1) * f.get(1, 0))
    return c^


struct Corotational(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var r = polar_rotation(f)
        var rtf = r.transpose() * f
        var tr = rtf.get(0, 0) + rtf.get(1, 1) + rtf.get(2, 2) - 3.0
        var p = Mat3()
        for i in range(3):
            for j in range(3):
                p.set(i, j, 2 * mu * (f.get(i, j) - r.get(i, j)) + lam * tr * r.get(i, j))
        return p^

    @staticmethod
    def name() -> String:
        return "corotational"


struct StableNeoHookean(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var lam_s = lam + mu
        var alpha = 1 + mu / lam_s
        var j = det3(f)
        var c = cofactor(f)
        var p = Mat3()
        for a in range(3):
            for b in range(3):
                p.set(a, b, mu * f.get(a, b) + lam_s * (j - alpha) * c.get(a, b))
        return p^

    @staticmethod
    def name() -> String:
        return "stable neo-hookean"


struct StVK(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var ftf = f.transpose() * f
        var e = Mat3()
        for a in range(3):
            for b in range(3):
                e.set(a, b, 0.5 * (ftf.get(a, b) - (Real(1) if a == b else Real(0))))
        var tr = e.get(0, 0) + e.get(1, 1) + e.get(2, 2)
        var s = Mat3()
        for a in range(3):
            for b in range(3):
                s.set(a, b, 2 * mu * e.get(a, b) + (lam * tr if a == b else Real(0)))
        return f * s

    @staticmethod
    def name() -> String:
        return "stvk"


def deformation_gradient(body: FemBody, t: Int) -> Mat3:
    var tt = body.tets[t]
    var pa = body.pos(tt.a)
    var e1 = body.pos(tt.b) - pa
    var e2 = body.pos(tt.c) - pa
    var e3 = body.pos(tt.d) - pa
    var ds = Mat3()
    for k in range(3):
        ds.set(k, 0, e1[k])
        ds.set(k, 1, e2[k])
        ds.set(k, 2, e3[k])
    return ds * tt.dm_inv


def material_forces[M: Material](body: FemBody, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
    """Accumulate the elastic nodal forces of model `M` (H = -W P Dm^-T, as
    in `FemBody.elastic_forces`)."""
    for t in range(len(body.tets)):
        var f = deformation_gradient(body, t)
        var p = M.pk1(f, body.mu, body.lam)
        var tt = body.tets[t]
        var h = p * tt.dm_inv.transpose()
        var w = tt.vol
        var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0), 0)
        var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1), 0)
        var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2), 0)
        var f0 = (f1 + f2 + f3) * Real(-1)
        fx[tt.a] += f0[0]
        fy[tt.a] += f0[1]
        fz[tt.a] += f0[2]
        fx[tt.b] += f1[0]
        fy[tt.b] += f1[1]
        fz[tt.b] += f1[2]
        fx[tt.c] += f2[0]
        fy[tt.c] += f2[1]
        fz[tt.c] += f2[2]
        fx[tt.d] += f3[0]
        fy[tt.d] += f3[1]
        fz[tt.d] += f3[2]


def step_material[M: Material](mut body: FemBody, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
    """Explicit step of `FemBody` with model `M` (same integrator as
    `FemBody.step`: symplectic Euler, mass-proportional damping, floor)."""
    var n = body.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    material_forces[M](body, fx, fy, fz)
    body.integrate(fx, fy, fz, dt, gravity, floor_y)


def inverted_count(body: FemBody) -> Int:
    """Elements whose current det F is <= 0."""
    var k = 0
    for t in range(len(body.tets)):
        if det3(deformation_gradient(body, t)) <= 0:
            k += 1
    return k


def _col(m: Mat3, j: Int) -> Vec3:
    return Vec3(m.get(0, j), m.get(1, j), m.get(2, j), 0)


def _set_col(mut m: Mat3, j: Int, v: Vec3):
    for i in range(3):
        m.set(i, j, v[i])


def nh_dpk1(f: Mat3, df: Mat3, mu: Real, lam: Real) -> Mat3:
    """Differential of `StableNeoHookean.pk1` at F in direction dF."""
    var lam_s = lam + mu
    var alpha = 1 + mu / lam_s
    var j = det3(f)
    var c = cofactor(f)
    var cdf = Real(0)
    for a in range(3):
        for b in range(3):
            cdf += c.get(a, b) * df.get(a, b)
    var f0 = _col(f, 0)
    var f1 = _col(f, 1)
    var f2 = _col(f, 2)
    var d0 = _col(df, 0)
    var d1 = _col(df, 1)
    var d2 = _col(df, 2)
    var dc = Mat3()
    _set_col(dc, 0, cross(d1, f2) + cross(f1, d2))
    _set_col(dc, 1, cross(d2, f0) + cross(f2, d0))
    _set_col(dc, 2, cross(d0, f1) + cross(f0, d1))
    var dp = Mat3()
    for a in range(3):
        for b in range(3):
            dp.set(a, b, mu * df.get(a, b) + lam_s * cdf * c.get(a, b) + lam_s * (j - alpha) * dc.get(a, b))
    return dp^


struct NhImplicitOp(LinearOperator, Movable):
    """A = M - dt^2 df/dx with the stable Neo-Hookean tangent at the
    snapshot F of every element (F is fixed for the solve, so the operator
    does not change between Krylov iterations)."""

    var n: Int
    var dt: Real
    var mu: Real
    var lam: Real
    var tet_idx: List[Int]
    var f: List[Mat3]
    var dm_inv: List[Mat3]
    var vol: List[Real]
    var mass: List[Real]

    def __init__(out self, body: FemBody, dt: Real):
        self.n = body.node_count()
        self.dt = dt
        self.mu = body.mu
        self.lam = body.lam
        self.tet_idx = List[Int]()
        self.f = List[Mat3]()
        self.dm_inv = List[Mat3]()
        self.vol = List[Real]()
        for t in range(len(body.tets)):
            var tt = body.tets[t]
            self.tet_idx.append(tt.a)
            self.tet_idx.append(tt.b)
            self.tet_idx.append(tt.c)
            self.tet_idx.append(tt.d)
            self.f.append(deformation_gradient(body, t))
            self.dm_inv.append(tt.dm_inv)
            self.vol.append(tt.vol)
        self.mass = List[Real]()
        for i in range(self.n):
            self.mass.append(Real(0) if body.inv_m[i] == 0 else Real(1) / body.inv_m[i])

    def size(self) -> Int:
        return 3 * self.n

    def stiffness_apply(self, du: List[Real], mut out: List[Real]):
        """Out = (df/dx) du."""
        for i in range(len(out)):
            out[i] = 0
        for e in range(len(self.vol)):
            var a = self.tet_idx[4 * e]
            var b = self.tet_idx[4 * e + 1]
            var c = self.tet_idx[4 * e + 2]
            var d = self.tet_idx[4 * e + 3]
            var dds = Mat3()
            for k in range(3):
                dds.set(k, 0, du[3 * b + k] - du[3 * a + k])
                dds.set(k, 1, du[3 * c + k] - du[3 * a + k])
                dds.set(k, 2, du[3 * d + k] - du[3 * a + k])
            var dmi = self.dm_inv[e]
            var dp = nh_dpk1(self.f[e], dds * dmi, self.mu, self.lam)
            var h = dp * dmi.transpose()
            var w = self.vol[e]
            for k in range(3):
                var g1 = -w * h.get(k, 0)
                var g2 = -w * h.get(k, 1)
                var g3 = -w * h.get(k, 2)
                out[3 * b + k] += g1
                out[3 * c + k] += g2
                out[3 * d + k] += g3
                out[3 * a + k] -= g1 + g2 + g3

    def apply(self, x: List[Real], mut out: List[Real]):
        self.stiffness_apply(x, out)
        var dt2 = self.dt * self.dt
        for i in range(self.n):
            for k in range(3):
                if self.mass[i] == 0:
                    out[3 * i + k] = x[3 * i + k]
                else:
                    out[3 * i + k] = self.mass[i] * x[3 * i + k] - dt2 * out[3 * i + k]

    def diagonal(self, mut out: List[Real]):
        for i in range(self.n):
            for k in range(3):
                out[3 * i + k] = Real(1) if self.mass[i] == 0 else self.mass[i]


def step_implicit_nh(
    mut body: FemBody, dt: Real, gravity: Vec3, floor_y: Real = -1e30,
    tol: Real = 1e-4, max_iters: Int = 0,
) -> CgResult:
    """Linearised backward Euler with the stable Neo-Hookean tangent:
    (M - dt^2 K) dv = dt (f(x) + M g + dt K v), K = df/dx at the current x,
    solved with MINRES. A non-converged solve is dropped and counted
    (`CG_NOT_CONVERGED`), as in `FemBody.step_implicit`."""
    var n = body.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    material_forces[StableNeoHookean](body, fx, fy, fz)
    var op = NhImplicitOp(body, dt)
    var v0 = List[Real](length=3 * n, fill=0)
    for i in range(n):
        v0[3 * i] = body.vx[i]
        v0[3 * i + 1] = body.vy[i]
        v0[3 * i + 2] = body.vz[i]
    var kv = List[Real](length=3 * n, fill=0)
    op.stiffness_apply(v0, kv)
    var b = List[Real](length=3 * n, fill=0)
    for i in range(n):
        if body.inv_m[i] == 0:
            continue
        var m = Real(1) / body.inv_m[i]
        b[3 * i] = dt * (fx[i] + m * gravity[0] + dt * kv[3 * i])
        b[3 * i + 1] = dt * (fy[i] + m * gravity[1] + dt * kv[3 * i + 1])
        b[3 * i + 2] = dt * (fz[i] + m * gravity[2] + dt * kv[3 * i + 2])
    var dv = List[Real](length=3 * n, fill=0)
    # floor 1e-2: rounding dv to f32 leaves a true relative residual of
    # eps_f32 cond(A) (5.2e-4 at E = 1e7, dt = 1/60), above minres's default
    # 1.2e-4 floor; a failed recurrence shows residuals of order 1
    var res = minres(op, b, dv, tol, max_iters, False, 1e-2)
    if not res.converged:
        body.counters.incr(CG_NOT_CONVERGED)
        return res
    var damp = Real(1.0) / (1.0 + body.damping * dt)
    for i in range(n):
        if body.inv_m[i] == 0:
            body.vx[i] = 0
            body.vy[i] = 0
            body.vz[i] = 0
            continue
        body.vx[i] = (body.vx[i] + dv[3 * i]) * damp
        body.vy[i] = (body.vy[i] + dv[3 * i + 1]) * damp
        body.vz[i] = (body.vz[i] + dv[3 * i + 2]) * damp
        body.x[i] += body.vx[i] * dt
        body.y[i] += body.vy[i] * dt
        body.z[i] += body.vz[i] * dt
        if body.y[i] < floor_y:
            body.y[i] = floor_y
            if body.vy[i] < 0:
                body.vy[i] = 0
    return res
