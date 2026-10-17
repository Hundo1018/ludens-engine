# tier: component
"""GMRES, sparse Cholesky and IC(0)-preconditioned CG (ROADMAP 17.84,
`numerics.gmres`, `numerics.cholesky`).

  1. Ordinary: on 2D Poisson (32 x 32 grid, n = 1024) the sparse Cholesky
     solve matches the manufactured solution (max error printed, < 1e-4);
     CG and IC(0)-PCG reach 1e-6 and agree with it; IC(0) needs fewer
     iterations than plain CG (printed).
  2. Integration: the same grid with its nodes shuffled: natural-order
     Cholesky fills L far more than with the reverse Cuthill-McKee
     ordering (nnz printed), both solve it. Upwind convection-diffusion
     (rows -2, 3.1, -1; n = 1024; `bench_numerics_deep`'s solution
     1 + 0.25 (i mod 7)), where BiCGStab with Jacobi diverges (printed):
     GMRES(30) with and without Jacobi converges, error < 1e-3.
  3. Extreme: an indefinite matrix (one negative diagonal) and a singular
     one (pure Neumann Laplacian) make `factor` raise; a non-permutation
     raises; b = 0 returns x = 0 converged in 0 iterations (GMRES, PCG);
     n = 1 works.
"""

from std.math import sin
from harness.runner import Suite
from geometry.vec import Real
from numerics.sparse import CsrMatrix
from numerics.cg import cg
from numerics.bicgstab import bicgstab
from numerics.gmres import gmres
from numerics.cholesky import SparseCholesky, IncompleteCholesky, pcg_ic0, rcm_order


def _poisson2d(m: Int, label: List[Int]) -> CsrMatrix:
    """5-point Laplacian (+ 0.01 I) on an m x m grid; node (i, j) is row
    label[i m + j]."""
    var r = List[Int]()
    var c = List[Int]()
    var v = List[Real]()
    for i in range(m):
        for j in range(m):
            var k = label[i * m + j]
            r.append(k)
            c.append(k)
            v.append(4.01)
            if i > 0:
                r.append(k)
                c.append(label[(i - 1) * m + j])
                v.append(-1)
            if i + 1 < m:
                r.append(k)
                c.append(label[(i + 1) * m + j])
                v.append(-1)
            if j > 0:
                r.append(k)
                c.append(label[i * m + j - 1])
                v.append(-1)
            if j + 1 < m:
                r.append(k)
                c.append(label[i * m + j + 1])
                v.append(-1)
    return CsrMatrix.from_triplets(m * m, r, c, v)


def _convdiff(n: Int) -> CsrMatrix:
    var r = List[Int]()
    var c = List[Int]()
    var v = List[Real]()
    for i in range(n):
        r.append(i)
        c.append(i)
        v.append(3.1)
        if i > 0:
            r.append(i)
            c.append(i - 1)
            v.append(-2)
        if i + 1 < n:
            r.append(i)
            c.append(i + 1)
            v.append(-1)
    return CsrMatrix.from_triplets(n, r, c, v)


def _xstar(n: Int) -> List[Real]:
    var x = List[Real](capacity=n)
    for i in range(n):
        x.append(sin(Real(i) * 0.37) + 0.5)
    return x^


def _rhs(a: CsrMatrix, x: List[Real]) -> List[Real]:
    var b = List[Real](length=a.n, fill=0)
    a.apply(x, b)
    return b^


def _err(x: List[Real], y: List[Real]) -> Real:
    var e = Real(0)
    for i in range(len(x)):
        e = max(e, abs(x[i] - y[i]))
    return e


def _ident(n: Int) -> List[Int]:
    var p = List[Int](capacity=n)
    for i in range(n):
        p.append(i)
    return p^


def main() raises:
    var s = Suite("solvers")
    var m = 32
    var n = m * m

    # ---- Cholesky / CG / IC(0) on Poisson --------------------------------------------------------------------
    var a = _poisson2d(m, _ident(n))
    var xs = _xstar(n)
    var b = _rhs(a, xs)
    var ch = SparseCholesky()
    ch.factor(a, rcm_order(a))
    var x_ch = List[Real](length=n, fill=0)
    ch.solve(b, x_ch)
    var x_cg = List[Real](length=n, fill=0)
    var r_cg = cg(a, b, x_cg, 1e-6, 4 * n)
    var ic = IncompleteCholesky(a)
    var x_ic = List[Real](length=n, fill=0)
    var r_ic = pcg_ic0(a, ic, b, x_ic, 1e-6, 4 * n)
    print("  Poisson 32 x 32: Cholesky error", _err(x_ch, xs), " nnz(L)", ch.nnz(), ";  CG", r_cg.iters, "iterations error", _err(x_cg, xs), ";  IC(0)-PCG", r_ic.iters, "iterations error", _err(x_ic, xs), "shifted", ic.shifted)
    s.check(_err(x_ch, xs) < 1e-4, "sparse Cholesky solves Poisson to the manufactured solution")
    s.check(r_cg.converged and r_ic.converged and _err(x_cg, x_ch) < 1e-3 and _err(x_ic, x_ch) < 1e-3, "CG and IC(0)-PCG converge to the Cholesky answer")
    s.check(r_ic.iters < r_cg.iters and ic.shifted == 0, "IC(0) needs fewer iterations than plain CG")

    # ---- ordering on a shuffled grid -------------------------------------------------------------------------
    var label = List[Int](capacity=n)
    for k in range(n):
        label.append((k * 389) % n)  # 389 is coprime with 1024: a permutation
    var sh = _poisson2d(m, label)
    var bs = _rhs(sh, xs)
    var nat = SparseCholesky()
    nat.factor(sh, _ident(n))
    var rcm = SparseCholesky()
    rcm.factor(sh, rcm_order(sh))
    var x_nat = List[Real](length=n, fill=0)
    var x_rcm = List[Real](length=n, fill=0)
    nat.solve(bs, x_nat)
    rcm.solve(bs, x_rcm)
    print("  shuffled grid: nnz(L) natural", nat.nnz(), " RCM", rcm.nnz(), ";  errors", _err(x_nat, xs), _err(x_rcm, xs))
    s.check(rcm.nnz() * 2 < nat.nnz() and _err(x_nat, xs) < 1e-4 and _err(x_rcm, xs) < 1e-4, "RCM cuts the fill of a shuffled grid; both orderings solve it")

    # ---- GMRES on convection-diffusion ----------------------------------------------------------------------
    var cd = _convdiff(1024)
    var xc = List[Real]()
    for i in range(1024):
        xc.append(Real(1) + Real(i % 7) * 0.25)  # bench_numerics_deep's solution
    var bc = _rhs(cd, xc)
    var x_g = List[Real](length=1024, fill=0)
    var x_gj = List[Real](length=1024, fill=0)
    var x_bj = List[Real](length=1024, fill=0)
    var rg = gmres(cd, bc, x_g, 1e-6, 4096, 30, False)
    var rgj = gmres(cd, bc, x_gj, 1e-6, 4096, 30, True)
    var rbj = bicgstab(cd, bc, x_bj, 1e-6, 4096, True)
    print("  convection-diffusion n 1024: GMRES(30)", rg.iters, "steps error", _err(x_g, xc), ";  + Jacobi", rgj.iters, "error", _err(x_gj, xc), ";  BiCGStab + Jacobi converged", rbj.converged, "error", _err(x_bj, xc))
    s.check(rg.converged and rgj.converged and _err(x_g, xc) < 1e-3 and _err(x_gj, xc) < 1e-3, "GMRES converges with and without Jacobi")

    # ---- extremes -----------------------------------------------------------------------------------------------
    var raised = 0
    var bad = CsrMatrix.from_triplets(2, [0, 1], [0, 1], [1.0, -1.0])
    try:
        var f = SparseCholesky()
        f.factor(bad, _ident(2))
    except:
        raised += 1
    var neu = CsrMatrix.from_triplets(2, [0, 0, 1, 1], [0, 1, 0, 1], [1.0, -1.0, -1.0, 1.0])
    try:
        var f = SparseCholesky()
        f.factor(neu, _ident(2))
    except:
        raised += 1
    try:
        var f = SparseCholesky()
        f.factor(a, List[Int](length=n, fill=0))
    except:
        raised += 1
    s.check(raised == 3, "indefinite, singular and a non-permutation raise")
    var zero = List[Real](length=n, fill=0)
    var xz = List[Real](length=n, fill=0)
    var rz = gmres(a, zero, xz, 1e-6)
    var xz2 = List[Real](length=n, fill=0)
    var rz2 = pcg_ic0(a, ic, zero, xz2, 1e-6)
    s.check(rz.converged and rz.iters == 0 and rz2.converged and rz2.iters == 0 and _err(xz, zero) == 0, "b = 0: x = 0 in 0 iterations")
    var one = CsrMatrix.from_triplets(1, [0], [0], [4.0])
    var f1 = SparseCholesky()
    f1.factor(one, _ident(1))
    var x1 = List[Real](length=1, fill=0)
    f1.solve([2.0], x1)
    s.check(x1[0] == 0.5, "n = 1")
    s.finish()
