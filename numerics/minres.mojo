"""MINRES for symmetric indefinite systems (ROADMAP 17.84).

CG needs a positive-definite operator: on a saddle-point system
[[K, B^T], [B, 0]] (a constrained solve: K an SPD stiffness block, B the
constraint rows) its step length p^T A p can be zero or negative and it
fails (`test_solvers`). GMRES works but keeps its whole basis. MINRES
(Paige & Saunders 1975) uses the symmetric Lanczos three-term recurrence,
so it stores a fixed six vectors, and minimises ||b - A x|| over the Krylov
space at every step, so the residual never grows. The recurrences run in
Float64 like `cg` / `gmres` (Real is f32).

`precondition` uses M = diag(|a_ii|) (1 where a_ii = 0): MINRES needs a
symmetric positive-definite preconditioner, and a saddle point's zero block
has no diagonal to invert. The convergence estimate is then in the M^-1
norm; the returned `residual` is always the true ||b - A x|| / ||b|| of the
f32 x, with the same floor as `gmres` (max(tol, 1.2e-4)) unless the caller
passes `floor`: rounding x to f32 alone leaves a relative residual of about
eps_f32 cond(A), 5.2e-4 on the stiff implicit FEM system of
`test_fem_nh_implicit`, so a caller with such a system raises it. `stalled`
reports a Lanczos breakdown (beta = 0) short of the tolerance.
"""

from std.math import sqrt
from geometry.vec import Real
from .sparse import LinearOperator
from .cg import CgResult
from .vecops import zeros64, dot64, norm64, widen, narrow


def _apply64[Op: LinearOperator](a: Op, v: List[Float64], mut tmp: List[Real], mut tmpo: List[Real], mut res: List[Float64]):
    narrow(v, tmp)
    a.apply(tmp, tmpo)
    for i in range(len(res)):
        res[i] = Float64(tmpo[i])


def minres[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0, precondition: Bool = False,
    floor: Real = 1.2e-4,
) -> CgResult:
    var n = a.size()
    var limit = max_iters if max_iters > 0 else 4 * n
    var minv = List[Float64](length=n, fill=1)
    if precondition:
        var d = List[Real](length=n, fill=0)
        a.diagonal(d)
        for i in range(n):
            minv[i] = 1 / abs(Float64(d[i])) if d[i] != 0 else 1
    var xs = zeros64(n)
    widen(x, xs)
    var b64 = zeros64(n)
    widen(b, b64)
    var bn = norm64(b64)
    if bn == 0:
        bn = 1
    var tmp = List[Real](length=n, fill=0)
    var tmpo = List[Real](length=n, fill=0)
    var r1 = zeros64(n)
    _apply64(a, xs, tmp, tmpo, r1)
    for i in range(n):
        r1[i] = b64[i] - r1[i]
    var r2 = r1.copy()
    var y = zeros64(n)
    for i in range(n):
        y[i] = minv[i] * r1[i]
    var beta1 = sqrt(max(dot64(r1, y), 0))
    var v = zeros64(n)
    var w = zeros64(n)
    var w1 = zeros64(n)
    var w2 = zeros64(n)
    var oldb = Float64(0)
    var beta = beta1
    var dbar = Float64(0)
    var epsln = Float64(0)
    var phibar = beta1
    var cs = Float64(-1)
    var sn = Float64(0)
    var it = 0
    var stalled = False
    var est = Float64(0) if beta1 == 0 else Float64(1)
    while est > Float64(tol) and it < limit:
        if beta == 0:
            stalled = True
            break
        it += 1
        var s = 1 / beta
        for i in range(n):
            v[i] = s * y[i]
        _apply64(a, v, tmp, tmpo, y)
        if it >= 2:
            var f = beta / oldb
            for i in range(n):
                y[i] -= f * r1[i]
        var alfa = dot64(v, y)
        var f2 = alfa / beta
        for i in range(n):
            y[i] -= f2 * r2[i]
        swap(r1, r2)
        for i in range(n):
            r2[i] = y[i]
            y[i] = minv[i] * r2[i]
        oldb = beta
        beta = sqrt(max(dot64(r2, y), 0))
        # QR of the Lanczos tridiagonal by Givens rotations
        var oldeps = epsln
        var delta = cs * dbar + sn * alfa
        var gbar = sn * dbar - cs * alfa
        epsln = sn * beta
        dbar = -cs * beta
        var gamma = sqrt(gbar * gbar + beta * beta)
        if gamma == 0:
            gamma = 1e-300
        cs = gbar / gamma
        sn = beta / gamma
        var phi = cs * phibar
        phibar = sn * phibar
        var dg = 1 / gamma
        swap(w1, w2)  # w1 <- old w2
        swap(w2, w)   # w2 <- old w, w <- old w1 (overwritten next)
        for i in range(n):
            w[i] = (v[i] - oldeps * w1[i] - delta * w2[i]) * dg
            xs[i] += phi * w[i]
        est = phibar / beta1
    narrow(xs, x)
    var x64 = zeros64(n)
    widen(x, x64)
    _apply64(a, x64, tmp, tmpo, r1)
    for i in range(n):
        r1[i] = b64[i] - r1[i]
    var true_res = norm64(r1) / bn
    var ok = est <= Float64(tol) and true_res <= max(Float64(tol), Float64(floor))
    if stalled and ok:
        stalled = False
    return CgResult(ok, stalled, it, Real(true_res))
