# tier: component
"""Multigrid-preconditioned CG on the periodic Poisson problem (ROADMAP 17.84,
`numerics.multigrid`).

-lap p = rhs on an n x n periodic grid (dx^2 = 1), rhs = -lap of a known
mean-free p* (sum of two sine modes plus a cell-wise hash, so every
frequency is present):

  1. Ordinary: for n = 32, 64, 128 MGPCG reaches 1e-6 and matches p* within
     1e-3; Jacobi PCG converges to the same answer.
  2. Scaling: MGPCG's iteration count stays within 2x from n = 32 to 128
     while Jacobi PCG's grows by > 3x (both printed).
  3. Symmetry: the V-cycle is a symmetric operator: <M u, v> = <u, M v>
     for two mean-free vectors (relative difference < 1e-12).
  4. Extreme: n = 2 (one level, coarsest smoothing only) solves; a non power
     of two raises; rhs = 0 gives p = 0 in 0 iterations.
"""

from std.math import sin
from harness.runner import Suite
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg
from numerics.multigrid import PeriodicPoissonMG, pcg_mg
from numerics.vecops import zeros64, dot64


struct NegLap(LinearOperator, Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def size(self) -> Int:
        return self.n * self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        var n = self.n
        for j in range(n):
            for i in range(n):
                out[j * n + i] = 4 * x[j * n + i] - x[j * n + (i + n - 1) % n] - x[j * n + (i + 1) % n] - x[((j + n - 1) % n) * n + i] - x[((j + 1) % n) * n + i]

    def diagonal(self, mut out: List[Real]):
        for k in range(self.n * self.n):
            out[k] = 4


def pstar(n: Int) -> List[Real]:
    var p = List[Real](length=n * n, fill=0)
    var mean = Float64(0)
    for j in range(n):
        for i in range(n):
            var h = Real(((i * 7919 + j * 104729) % 97)) / 97 - 0.5
            var v = sin(6.2831853 * Real(i) / Real(n)) + 0.5 * sin(6.2831853 * 3 * Real(j) / Real(n)) + 0.1 * h
            p[j * n + i] = v
            mean += Float64(v)
    mean /= Float64(n * n)
    for k in range(n * n):
        p[k] = Real(Float64(p[k]) - mean)
    return p^


def err(a: List[Real], b: List[Real]) -> Real:
    var e = Real(0)
    for k in range(len(a)):
        e = max(e, abs(a[k] - b[k]))
    return e


def main() raises:
    var s = Suite("multigrid")
    var it_mg = List[Int]()
    var it_j = List[Int]()
    var ok = True
    for n in [32, 64, 128]:
        var a = NegLap(n)
        var ps = pstar(n)
        var rhs = List[Real](length=n * n, fill=0)
        a.apply(ps, rhs)
        var mg = PeriodicPoissonMG(n)
        var x1 = List[Real](length=n * n, fill=0)
        var x2 = List[Real](length=n * n, fill=0)
        var r1 = pcg_mg(a, mg, rhs, x1, 1e-6, 4 * n * n)
        var r2 = pcg(a, rhs, x2, 1e-6, 4 * n * n)
        print("n", n, ": MGPCG", r1.iters, "iterations error", err(x1, ps), ";  Jacobi PCG", r2.iters, "iterations error", err(x2, ps))
        ok = ok and r1.converged and r2.converged and err(x1, ps) < 1e-3 and err(x2, ps) < 1e-3
        it_mg.append(r1.iters)
        it_j.append(r2.iters)
    s.check(ok, "MGPCG and Jacobi PCG converge to p* (1e-3) at n = 32, 64, 128")
    s.check(it_mg[2] <= 2 * it_mg[0] and it_j[2] > 3 * it_j[0], "MGPCG iterations stay flat; Jacobi PCG's grow")

    var n = 64
    var mg = PeriodicPoissonMG(n)
    var u = zeros64(n * n)
    var v = zeros64(n * n)
    var su = Float64(0)
    var sv = Float64(0)
    for k in range(n * n):
        u[k] = Float64(sin(Real(k) * 0.37))
        v[k] = Float64(sin(Real(k) * 1.91 + 0.3))
        su += u[k]
        sv += v[k]
    for k in range(n * n):
        u[k] -= su / Float64(n * n)
        v[k] -= sv / Float64(n * n)
    var mu = zeros64(n * n)
    var mv = zeros64(n * n)
    mg.apply64(u, mu)
    mg.apply64(v, mv)
    var d1 = dot64(mu, v)
    var d2 = dot64(u, mv)
    print("symmetry: <Mu, v>", d1, " <u, Mv>", d2)
    s.check(abs(d1 - d2) <= 1e-12 * abs(d1), "the V-cycle is symmetric")

    var a2 = NegLap(2)
    var p2: List[Real] = [1.0, -1.0, -0.5, 0.5]
    var r2h = List[Real](length=4, fill=0)
    a2.apply(p2, r2h)
    var mg2 = PeriodicPoissonMG(2)
    var x2 = List[Real](length=4, fill=0)
    var rr = pcg_mg(a2, mg2, r2h, x2, 1e-6)
    var raised = False
    try:
        _ = PeriodicPoissonMG(48)
    except:
        raised = True
    var a8 = NegLap(8)
    var mg8 = PeriodicPoissonMG(8)
    var z8 = List[Real](length=64, fill=0)
    var x8 = List[Real](length=64, fill=1)
    var r8 = pcg_mg(a8, mg8, z8, x8)
    s.check(rr.converged and err(x2, p2) < 1e-5 and raised and r8.converged and r8.iters == 0 and x8[5] == 0, "n = 2, non power of two raises, rhs = 0")
    s.finish()
