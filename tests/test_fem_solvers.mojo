# tier: component
"""FEM implicit step with each linear solver (ROADMAP 17.84,
`FemBody.solver`: FEM_SOLVE_CG / FEM_SOLVE_CHOLESKY / FEM_SOLVE_PCG_IC0).

  1. Parity: the assembled matrix applied to a vector equals the matrix-free
     operator on every free node (1e-3 relative); a 6 x 2 x 2 cantilever at
     E = 2e5 sags under gravity for 2 s at dt = 1/60 with each solver, and
     the three tip trajectories agree within 1 mm (CG at tol 1e-6).
  2. Integration: every step's solve converges with each solver; IC(0)-PCG
     uses fewer iterations than CG in total (printed); the beam stays
     bounded (tip y in (-2, 2)) and keeps its volume (1 %).
  3. Extreme: a body with every node pinned steps (identity system) with
     each solver and does not move.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, FemImplicitOp, make_beam, FEM_SOLVE_CG, FEM_SOLVE_CHOLESKY, FEM_SOLVE_PCG_IC0

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _beam(solver: Int) -> FemBody:
    var b = FemBody(2.0e5, 0.3, 2.0)
    make_beam(b, 6, 2, 2, 0.25, 1.0)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)
    b.solver = solver
    return b^


def main() raises:
    var s = Suite("fem_solvers")

    # ---- assembled == matrix-free --------------------------------------------------------------------
    var b0 = _beam(FEM_SOLVE_CG)
    for _ in range(10):
        _ = b0.step_implicit(DT, G, tol=1e-6, max_iters=400)
    var op = FemImplicitOp(b0, DT)
    var a = op.assemble()
    var n = op.size()
    var x = List[Real](length=n, fill=0)
    for i in range(n):
        x[i] = Real((i * 7919) % 13) * 0.1 - 0.6
    for i in range(b0.node_count()):
        if b0.inv_m[i] == 0:
            for k in range(3):
                x[3 * i + k] = 0
    var y0 = List[Real](length=n, fill=0)
    var y1 = List[Real](length=n, fill=0)
    op.apply(x, y0)
    a.apply(x, y1)
    var worst = Real(0)
    var scale = Real(0)
    for i in range(n):
        worst = max(worst, abs(y0[i] - y1[i]))
        scale = max(scale, abs(y0[i]))
    print("  assembled vs matrix-free: max diff", worst, "of", scale, " nnz", len(a.val), " symmetric", a.is_symmetric(1e-3))
    s.check(worst <= 1e-3 * scale and a.is_symmetric(1e-3), "the assembled matrix is the operator, and symmetric")

    # ---- the three solvers --------------------------------------------------------------------------
    var tips = List[List[Real]]()
    var iters = List[Int]()
    var ok = List[Bool]()
    var vols = List[Real]()
    var rest = Real(0)
    for solver in [FEM_SOLVE_CG, FEM_SOLVE_CHOLESKY, FEM_SOLVE_PCG_IC0]:
        var b = _beam(solver)
        rest = b.total_volume()
        var tr = List[Real]()
        var it = 0
        var conv = True
        for _ in range(120):
            var r = b.step_implicit(DT, G, tol=1e-6, max_iters=400)
            it += r.iters
            conv = conv and r.converged
            tr.append(b.pos(b.node_count() - 1)[1])
        tips.append(tr^)
        iters.append(it)
        ok.append(conv)
        vols.append(b.total_volume())
    var gap = Real(0)
    for k in range(120):
        gap = max(gap, max(abs(tips[0][k] - tips[1][k]), abs(tips[0][k] - tips[2][k])))
    print("  2 s cantilever: tip y CG", tips[0][119], " Cholesky", tips[1][119], " IC(0)-PCG", tips[2][119], ";  max gap", gap, "m;  iterations CG", iters[0], " IC(0)", iters[2], ";  volume", vols[0], vols[1], vols[2], "(rest", rest, ")")
    s.check(gap < 1e-3, "the three solvers give the same sag (1 mm)")
    s.check(ok[0] and ok[1] and ok[2], "every step converges with each solver")
    s.check(iters[2] < iters[0], "IC(0)-PCG needs fewer iterations than CG")
    s.check(tips[1][119] > -2 and tips[1][119] < 2 and abs(vols[1] / rest - 1) < 0.01, "bounded, volume kept (1 %)")

    # ---- extremes ---------------------------------------------------------------------------------------
    var still = True
    for solver in [FEM_SOLVE_CG, FEM_SOLVE_CHOLESKY, FEM_SOLVE_PCG_IC0]:
        var b = FemBody(1e4, 0.3)
        make_beam(b, 1, 1, 1, 0.5, 1.0)
        for i in range(b.node_count()):
            b.pin(i)
        b.solver = solver
        var p0 = b.pos(3)
        var r = b.step_implicit(DT, G)
        still = still and r.converged and b.pos(3)[0] == p0[0] and b.pos(3)[1] == p0[1]
    s.check(still, "an all-pinned body does not move with any solver")
    s.finish()
