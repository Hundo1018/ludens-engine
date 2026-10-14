"""BiCGStab for non-symmetric systems (ROADMAP 17.84).

`cg` / `pcg` require a symmetric positive definite operator (the
`LinearOperator` contract); on a non-symmetric one they converge to the
wrong answer or stall. BiCGStab (van der Vorst 1992) needs only `apply`. It
is generic over `LinearOperator` for the interface (size / apply / diagonal),
but does NOT need its symmetry precondition; `diagonal` is used for the
same Jacobi preconditioning as `pcg` when `precondition` is set.

Recurrences run in Float64 like `cg` (Real is f32; the f32 recurrence
loses the residual first, ROADMAP 15.1). Returns the same `CgResult`;
`stalled` reports a breakdown (rho or omega became zero), after which no
iteration budget helps. `residual` is the true ||b - A x|| / ||b|| of the
returned f32 x, not the recursive estimate (see the end of `bicgstab`).
"""

from geometry.vec import Real
from .sparse import LinearOperator
from .cg import CgResult
from .vecops import zeros64, dot64, norm64, widen, narrow


def _apply64[Op: LinearOperator](a: Op, v: List[Float64], mut tmp: List[Real], mut tmpo: List[Real], mut res: List[Float64]):
    narrow(v, tmp)
    a.apply(tmp, tmpo)
    for i in range(len(res)):
        res[i] = Float64(tmpo[i])


def bicgstab[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0, precondition: Bool = False,
) -> CgResult:
    var n = a.size()
    var limit = max_iters if max_iters > 0 else 2 * n
    var dinv = List[Float64](length=n, fill=1)
    if precondition:
        var d = List[Real](length=n, fill=0)
        a.diagonal(d)
        for i in range(n):
            dinv[i] = 1 / Float64(d[i]) if d[i] != 0 else 1
    var xs = zeros64(n)
    widen(x, xs)
    var b64 = zeros64(n)
    widen(b, b64)
    var bn = norm64(b64)
    if bn == 0:
        bn = 1
    var tmp = List[Real](length=n, fill=0)
    var tmpo = List[Real](length=n, fill=0)

    var r = zeros64(n)
    _apply64(a, xs, tmp, tmpo, r)
    for i in range(n):
        r[i] = b64[i] - r[i]
    var r0 = r.copy()
    var rho = Float64(1)
    var alpha = Float64(1)
    var omega = Float64(1)
    var v = zeros64(n)
    var p = zeros64(n)
    var y = zeros64(n)
    var z = zeros64(n)
    var s = zeros64(n)
    var t = zeros64(n)
    var res = norm64(r) / bn
    var it = 0
    var stalled = False
    while it < limit and res > Float64(tol):
        var rho1 = dot64(r0, r)
        if rho1 == 0 or omega == 0:
            stalled = True
            break
        var beta = (rho1 / rho) * (alpha / omega)
        for i in range(n):
            p[i] = r[i] + beta * (p[i] - omega * v[i])
            y[i] = p[i] * dinv[i]
        _apply64(a, y, tmp, tmpo, v)
        var r0v = dot64(r0, v)
        if r0v == 0:
            stalled = True
            break
        alpha = rho1 / r0v
        for i in range(n):
            s[i] = r[i] - alpha * v[i]
        if norm64(s) / bn <= Float64(tol):
            for i in range(n):
                xs[i] += alpha * y[i]
            res = norm64(s) / bn
            it += 1
            break
        for i in range(n):
            z[i] = s[i] * dinv[i]
        _apply64(a, z, tmp, tmpo, t)
        var tt = dot64(t, t)
        omega = dot64(t, s) / tt if tt != 0 else Float64(0)
        for i in range(n):
            xs[i] += alpha * y[i] + omega * z[i]
            r[i] = s[i] - omega * t[i]
        rho = rho1
        res = norm64(r) / bn
        it += 1
    narrow(xs, x)
    # The recursive residual drifts from b - A x on ill-conditioned systems
    # (measured: upwind convection-diffusion with c = 4 met 1e-6 recursively
    # with an answer off by 6e9). Report the true residual of the f32 answer,
    # and refuse convergence when it is above max(tol, 1e3 * eps_f32): below
    # that floor rounding x to f32 alone can produce the residual (Poisson
    # n=64, |x| ~ 500: 1.75e-5).
    var met = res <= Float64(tol)
    var x64 = zeros64(n)
    widen(x, x64)
    _apply64(a, x64, tmp, tmpo, r)
    for i in range(n):
        r[i] = b64[i] - r[i]
    var true_res = norm64(r) / bn
    var ok = met and true_res <= max(Float64(tol), 1.2e-4)
    return CgResult(ok, stalled, it, Real(true_res))
