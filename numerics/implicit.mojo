"""Implicit differentiation through a symmetric linear solve (ROADMAP 17.84).

A quantity defined by a solve, x = A(θ)^-1 b(θ), has the gradient

    dL/dθ_k = λ^T (∂b/∂θ_k - (∂A/∂θ_k) x),   A^T λ = ∂L/∂x,

whatever iterative method produced x: one more solve (the adjoint) plus one
product per parameter, instead of taping every Krylov iteration (a `Tape`
through 150 CG iterations on n = 1024 would hold the whole recurrence) or
2 solves per parameter for a central difference. It is exact for the
converged x; with an approximate x (or λ) the error is of the order of the
two solves' residuals (`test_implicit`).

Here A must be symmetric (A^T λ = A λ): the adjoint is solved with `cg`
when `spd` (stiffness, Laplacians) and with `minres` otherwise (saddle
points). The caller describes how A and b depend on θ through
`ParamDerivative`. Sums run in Float64.
"""

from geometry.vec import Real
from .sparse import LinearOperator
from .cg import cg, CgResult
from .minres import minres


trait ParamDerivative:
    def nparams(self) -> Int: ...

    def da_x(self, k: Int, x: List[Real], mut out: List[Real]):
        """Out = (∂A/∂θ_k) x."""
        ...

    def db(self, k: Int, mut out: List[Real]):
        """Out = ∂b/∂θ_k (zeros when b does not depend on θ_k)."""
        ...


def implicit_gradient[Op: LinearOperator, P: ParamDerivative](
    a: Op, p: P, x: List[Real], dl_dx: List[Real], mut grad: List[Float64],
    tol: Real = 1e-6, spd: Bool = True,
) -> CgResult:
    """Fill grad[k] = dL/dθ_k for the solved x; returns the adjoint solve's
    result (its `converged` is the caller's permission to use grad)."""
    var n = a.size()
    var lam = List[Real](length=n, fill=0)
    var r: CgResult
    if spd:
        r = cg(a, dl_dx, lam, tol, 4 * n)
    else:
        r = minres(a, dl_dx, lam, tol)
    var ax = List[Real](length=n, fill=0)
    var bk = List[Real](length=n, fill=0)
    var np = p.nparams()
    if len(grad) != np:
        grad = List[Float64](length=np, fill=0)
    for k in range(np):
        p.da_x(k, x, ax)
        p.db(k, bk)
        var g = Float64(0)
        for i in range(n):
            g += Float64(lam[i]) * (Float64(bk[i]) - Float64(ax[i]))
        grad[k] = g
    return r
