"""Restarted GMRES for non-symmetric systems (ROADMAP 17.84).

BiCGStab's convergence is irregular on non-normal matrices: on upwind
convection-diffusion n = 1024 it diverged with Jacobi preconditioning
(1136 iterations, error 4e14) where the unpreconditioned run converged
(`bench_numerics_deep`). GMRES(m) (Saad & Schultz 1986) minimises the
residual over the Krylov space at every step, so within a cycle the
residual never grows; restarting every `restart` steps bounds memory at
`restart + 1` basis vectors. Arnoldi uses modified Gram-Schmidt and the
least-squares problem is updated with Givens rotations, all in Float64 like
`cg` / `bicgstab` (Real is f32). Jacobi preconditioning is applied on the
right (x = D^-1 u), so the residual being minimised is the true one.

`iters` counts operator applications (inner steps); `residual` is the true
||b - A x|| / ||b|| of the returned f32 x, with the same convergence floor
as `bicgstab` (max(tol, 1.2e-4)). `stalled` reports a lucky breakdown that
did not reach the tolerance (the Krylov space stopped growing).
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


def gmres[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0, restart: Int = 30, precondition: Bool = False,
) -> CgResult:
    var n = a.size()
    var limit = max_iters if max_iters > 0 else 2 * n
    var m = max(1, min(restart, n))
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
    var w = zeros64(n)
    var z = zeros64(n)
    var basis = List[List[Float64]]()
    for _ in range(m + 1):
        basis.append(zeros64(n))
    var h = List[Float64](length=(m + 1) * m, fill=0)  # column-major (m+1) x m
    var cs = List[Float64](length=m, fill=0)
    var sn = List[Float64](length=m, fill=0)
    var g = List[Float64](length=m + 1, fill=0)
    var yv = List[Float64](length=m, fill=0)
    var it = 0
    var stalled = False
    var res = Float64(1)
    while it < limit:
        _apply64(a, xs, tmp, tmpo, r)
        for i in range(n):
            r[i] = b64[i] - r[i]
        var beta = norm64(r)
        res = beta / bn
        if res <= Float64(tol):
            break
        for i in range(n):
            basis[0][i] = r[i] / beta
        for k in range(m + 1):
            g[k] = 0
        g[0] = beta
        var k_used = 0
        for j in range(m):
            if it >= limit:
                break
            for i in range(n):
                z[i] = basis[j][i] * dinv[i]
            _apply64(a, z, tmp, tmpo, w)
            it += 1
            for i in range(j + 1):
                var hij = dot64(w, basis[i])
                h[j * (m + 1) + i] = hij
                for q in range(n):
                    w[q] -= hij * basis[i][q]
            var hn = norm64(w)
            h[j * (m + 1) + j + 1] = hn
            if hn > 0:
                for q in range(n):
                    basis[j + 1][q] = w[q] / hn
            # apply the earlier rotations to column j, then make a new one
            for i in range(j):
                var t0 = h[j * (m + 1) + i]
                var t1 = h[j * (m + 1) + i + 1]
                h[j * (m + 1) + i] = cs[i] * t0 + sn[i] * t1
                h[j * (m + 1) + i + 1] = -sn[i] * t0 + cs[i] * t1
            var hjj = h[j * (m + 1) + j]
            var den = sqrt(hjj * hjj + hn * hn)
            if den == 0:
                cs[j] = 1
                sn[j] = 0
            else:
                cs[j] = hjj / den
                sn[j] = hn / den
            h[j * (m + 1) + j] = den
            h[j * (m + 1) + j + 1] = 0
            g[j + 1] = -sn[j] * g[j]
            g[j] = cs[j] * g[j]
            k_used = j + 1
            res = abs(g[j + 1]) / bn
            if res <= Float64(tol) or hn == 0:
                if hn == 0 and res > Float64(tol):
                    stalled = True
                break
        # back substitution H y = g, then x += D^-1 V y
        for i in range(k_used - 1, -1, -1):
            var acc = g[i]
            for q in range(i + 1, k_used):
                acc -= h[q * (m + 1) + i] * yv[q]
            yv[i] = acc / h[i * (m + 1) + i] if h[i * (m + 1) + i] != 0 else 0
        for q in range(n):
            var acc = Float64(0)
            for i in range(k_used):
                acc += basis[i][q] * yv[i]
            xs[q] += acc * dinv[q]
        if stalled or res <= Float64(tol):
            break
    narrow(xs, x)
    var x64 = zeros64(n)
    widen(x, x64)
    _apply64(a, x64, tmp, tmpo, r)
    for i in range(n):
        r[i] = b64[i] - r[i]
    var true_res = norm64(r) / bn
    var ok = res <= Float64(tol) and true_res <= max(Float64(tol), 1.2e-4)
    return CgResult(ok, stalled, it, Real(true_res))
