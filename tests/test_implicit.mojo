# tier: component
"""Implicit differentiation through a linear solve (ROADMAP 17.84,
`numerics.implicit.implicit_gradient`).

Steady conduction on a 16 x 16 node grid: K(θ) x = s b0, K = sum over the
480 edges of θ_e (e_i - e_j)(e_i - e_j)^T + 0.01 I, θ_e = 1 + 0.5 sin(e),
b0 = +1 at node (4, 4) and -1 at (11, 11), plus one more parameter, the
load scale s = 1.

  1. Ordinary: compliance L = b^T x is self-adjoint (λ = x), so
     dL/dθ_e = -(x_i - x_j)^2 exactly: the implicit gradient matches it on
     all 480 edges (relative 1e-4 of the largest).
  2. Integration: L = x . x (adjoint ≠ primal): the implicit gradient
     matches a central difference of two full CG solves on 6 edges and on
     s (h = 3e-2 θ, relative 1 %), and dL/ds = 2 L / s (L is quadratic in
     s; 1e-4). One adjoint solve replaces 2 x 481 solves (iterations
     printed).
  3. Extreme: an indefinite symmetric A (saddle point, `spd = False`)
     goes through MINRES: compliance-style check against a central
     difference on its one parameter (1e-3).
"""

from std.math import sin
from harness.runner import Suite
from geometry.vec import Real
from numerics.sparse import CsrMatrix
from numerics.cg import cg
from numerics.minres import minres
from numerics.implicit import ParamDerivative, implicit_gradient

comptime M = 16


struct Grid(ParamDerivative, Movable):
    var ei: List[Int]
    var ej: List[Int]
    var theta: List[Real]
    var s: Real
    var b0: List[Real]

    def __init__(out self):
        self.ei = List[Int]()
        self.ej = List[Int]()
        self.theta = List[Real]()
        for r in range(M):
            for c in range(M):
                var k = r * M + c
                if c + 1 < M:
                    self.ei.append(k)
                    self.ej.append(k + 1)
                if r + 1 < M:
                    self.ei.append(k)
                    self.ej.append(k + M)
        for e in range(len(self.ei)):
            self.theta.append(1 + 0.5 * sin(Real(e)))
        self.s = 1
        self.b0 = List[Real](length=M * M, fill=0)
        self.b0[4 * M + 4] = 1
        self.b0[11 * M + 11] = -1

    def matrix(self) -> CsrMatrix:
        var r = List[Int]()
        var c = List[Int]()
        var v = List[Real]()
        for k in range(M * M):
            r.append(k)
            c.append(k)
            v.append(0.01)
        for e in range(len(self.ei)):
            var i = self.ei[e]
            var j = self.ej[e]
            var t = self.theta[e]
            r.append(i); c.append(i); v.append(t)
            r.append(j); c.append(j); v.append(t)
            r.append(i); c.append(j); v.append(-t)
            r.append(j); c.append(i); v.append(-t)
        return CsrMatrix.from_triplets(M * M, r, c, v)

    def rhs(self) -> List[Real]:
        var b = List[Real](length=M * M, fill=0)
        for k in range(M * M):
            b[k] = self.s * self.b0[k]
        return b^

    def nparams(self) -> Int:
        return len(self.ei) + 1

    def da_x(self, k: Int, x: List[Real], mut out: List[Real]):
        for q in range(len(out)):
            out[q] = 0
        if k < len(self.ei):
            var d = x[self.ei[k]] - x[self.ej[k]]
            out[self.ei[k]] = d
            out[self.ej[k]] = -d

    def db(self, k: Int, mut out: List[Real]):
        for q in range(len(out)):
            out[q] = 0 if k < len(self.ei) else self.b0[q]


def solve(g: Grid) -> List[Real]:
    var x = List[Real](length=M * M, fill=0)
    _ = cg(g.matrix(), g.rhs(), x, 1e-7, 4 * M * M)
    return x^


def l2(x: List[Real]) -> Float64:
    var a = Float64(0)
    for v in x:
        a += Float64(v) * Float64(v)
    return a


def compliance(g: Grid, x: List[Real]) -> Float64:
    var b = g.rhs()
    var a = Float64(0)
    for k in range(len(x)):
        a += Float64(b[k]) * Float64(x[k])
    return a


struct Saddle(ParamDerivative, Movable):
    """[[2 + t, 1], [1, -3]] x = (1, 2); one parameter t."""

    var t: Real

    def __init__(out self, t: Real):
        self.t = t

    def matrix(self) -> CsrMatrix:
        return CsrMatrix.from_triplets(2, [0, 0, 1, 1], [0, 1, 0, 1], [2 + self.t, 1.0, 1.0, -3.0])

    def nparams(self) -> Int:
        return 1

    def da_x(self, k: Int, x: List[Real], mut out: List[Real]):
        out[0] = x[0]
        out[1] = 0

    def db(self, k: Int, mut out: List[Real]):
        out[0] = 0
        out[1] = 0


def main() raises:
    var s = Suite("implicit")
    var g = Grid()
    var x = solve(g)
    var a = g.matrix()
    var grad = List[Float64]()
    var r = implicit_gradient(a, g, x, g.rhs(), grad, 1e-7)
    var big = Float64(0)
    for e in range(len(g.ei)):
        var d = Float64(x[g.ei[e]] - x[g.ej[e]])
        big = max(big, d * d)
    var worst = Float64(0)
    for e in range(len(g.ei)):
        var d = Float64(x[g.ei[e]] - x[g.ej[e]])
        worst = max(worst, abs(grad[e] + d * d))
    print("compliance: adjoint CG", r.iters, "iterations; worst |implicit - exact| / max", worst / big)
    s.check(r.converged and worst <= 1e-4 * big, "compliance: implicit gradient == -(x_i - x_j)^2 on all 480 edges")

    var dl = List[Real](length=M * M, fill=0)
    for k in range(M * M):
        dl[k] = 2 * x[k]
    var r2 = implicit_gradient(a, g, x, dl, grad, 1e-7)
    var ok = r2.converged
    var worst2 = Float64(0)
    var fd_iters = 0
    for e in [0, 17, 101, 239, 333, 479, 480]:
        var h: Real
        var base: Real
        if e < 480:
            base = g.theta[e]
            h = Real(3e-2) * base
            g.theta[e] = base + h
        else:
            base = g.s
            h = Real(3e-2) * base
            g.s = base + h
        var lp = l2(solve(g))
        if e < 480:
            g.theta[e] = base - h
        else:
            g.s = base - h
        var lm = l2(solve(g))
        if e < 480:
            g.theta[e] = base
        else:
            g.s = base
        fd_iters += 2
        var fd = (lp - lm) / (2 * Float64(h))
        var rl = abs(grad[e] - fd) / max(abs(fd), 1e-3 * abs(grad[480]))
        worst2 = max(worst2, rl)
    var lval = l2(x)
    var ds_exact = 2 * lval / Float64(g.s)
    print("x.x: worst relative error vs central differences", worst2, ";  dL/ds", grad[480], "exact 2 L / s", ds_exact, ";  adjoint CG", r2.iters, "iterations vs", 2 * 481, "solves for a full central difference")
    s.check(ok and worst2 < 0.01, "x.x: implicit gradient matches central differences of full solves (1 %)")
    s.check(abs(grad[480] - ds_exact) <= 1e-4 * abs(ds_exact), "dL/ds through db == 2 L / s")

    var sp = Saddle(0.5)
    var xs = List[Real](length=2, fill=0)
    _ = minres(sp.matrix(), [1.0, 2.0], xs, 1e-7)
    var gs = List[Float64]()
    var r3 = implicit_gradient(sp.matrix(), sp, xs, [1.0, 2.0], gs, 1e-7, False)
    var hh = Real(1e-3)
    var xp = List[Real](length=2, fill=0)
    var xm = List[Real](length=2, fill=0)
    _ = minres(Saddle(0.5 + hh).matrix(), [1.0, 2.0], xp, 1e-7)
    _ = minres(Saddle(0.5 - hh).matrix(), [1.0, 2.0], xm, 1e-7)
    var fdp = Float64(xp[0] * 1 + xp[1] * 2 - xm[0] * 1 - xm[1] * 2) / (2 * Float64(hh))
    print("saddle: implicit", gs[0], " central difference", fdp)

    s.check(r3.converged and abs(gs[0] - fdp) <= 1e-3 * abs(fdp), "indefinite A through MINRES matches a central difference")
    s.finish()
