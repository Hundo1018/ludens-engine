"""Global solve vs local iteration, and what a preconditioner is actually for.

Three questions, three blocks.

SCALING IN DEGREES OF FREEDOM. CG on the 1D Poisson system, against the Jacobi
sweep that stands in for every local iterative method already in this engine.
Both are given the SAME iteration budget so the comparison is per unit of work,
and the `res=` column is what each reached with it. The row that matters is not
the time, it is that Jacobi does not converge at all on this budget while CG
does: local iteration propagates information one neighbour per sweep, so its
iteration count scales with the mesh diameter.

SCALING IN CONDITION NUMBER. That is CG's real scale axis, not the size. Two
systems of identical size are solved: one with a constant diagonal and one whose
diagonal spans 1e6. Jacobi preconditioning is a scalar multiple of the identity
on the first and does nothing whatsoever; on the second it is the difference
between 195 iterations and 84. Reporting only the second would make the
preconditioner look universally good, which it is not.

THE STEP SIZE IT BUYS. Explicit and implicit FEM on the same beam. At the
stiffness used here the explicit integrator does not merely cost more per unit
of simulated time -- it diverges, so its row is a cost with no result attached,
and the honest comparison is at the largest dt each can actually survive.

Run with: `mojo run -I build benchmarks/bench_numerics.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from numerics.sparse import CsrMatrix, poisson_1d
from numerics.cg import cg, pcg, jacobi_solve
from numerics.vecops import zeros
from physics.fem import FemBody, make_beam
from harness.bench import BenchTable, now


def ones(n: Int) -> List[Real]:
    var v = zeros(n)
    for i in range(n):
        v[i] = 1
    return v^


def stretched(n: Int, ratio: Real) -> CsrMatrix:
    """Strictly diagonally dominant, diagonal spanning `ratio`, SPD."""
    var rows = List[Int]()
    var cols = List[Int]()
    var vals = List[Real]()
    var d = List[Real](capacity=n)
    for i in range(n):
        d.append(Real(1) + (ratio - 1) * Real(i) / Real(n - 1))
    for i in range(n):
        rows.append(i)
        cols.append(i)
        vals.append(d[i])
        if i > 0:
            var c = Real(0.49) * (d[i] if d[i] < d[i - 1] else d[i - 1])
            rows.append(i)
            cols.append(i - 1)
            vals.append(-c)
            rows.append(i - 1)
            cols.append(i)
            vals.append(-c)
    return CsrMatrix.from_triplets(n, rows, cols, vals)


def bench_dof(mut table: BenchTable, n: Int, reps: Int):
    var a = poisson_1d(n)
    var b = ones(n)
    var budget = n // 2

    var t0 = now()
    var acc = Real(0)
    var iters = 0
    var res = Real(0)
    for _ in range(reps):
        var x = zeros(n)
        var r = cg(a, b, x, 1e-8, budget)
        iters = r.iters
        res = r.residual
        acc += x[n // 2]
    keep(acc)
    var t1 = now()
    table.add(
        "cg iters=" + String(iters) + " res=" + String(res), n, "solve",
        t1 - t0, reps,
    )

    var t2 = now()
    var acc2 = Real(0)
    var rj = Real(0)
    for _ in range(reps):
        var x = zeros(n)
        rj = jacobi_solve(a, b, x, budget)
        acc2 += x[n // 2]
    keep(acc2)
    var t3 = now()
    table.add(
        "jacobi iters=" + String(budget) + " res=" + String(rj), n, "solve",
        t3 - t2, reps,
    )


def bench_cond(mut table: BenchTable, n: Int, ratio: Real, label: String, reps: Int):
    var a = poisson_1d(n) if ratio <= 1 else stretched(n, ratio)
    var b = ones(n)
    var t0 = now()
    var it1 = 0
    var acc = Real(0)
    for _ in range(reps):
        var x = zeros(n)
        var r = cg(a, b, x, 1e-8, 4 * n)
        it1 = r.iters
        acc += x[0]
    keep(acc)
    var t1 = now()
    table.add(label + " cg iters=" + String(it1), n, "solve", t1 - t0, reps)

    var t2 = now()
    var it2 = 0
    var acc2 = Real(0)
    for _ in range(reps):
        var x = zeros(n)
        var r = pcg(a, b, x, 1e-8, 4 * n)
        it2 = r.iters
        acc2 += x[0]
    keep(acc2)
    var t3 = now()
    table.add(label + " pcg iters=" + String(it2), n, "solve", t3 - t2, reps)


def beam(young: Real) -> FemBody:
    var b = FemBody(young, 0.3, 2.0)
    make_beam(b, 6, 2, 2, 0.25, 1.0)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)
    return b^


def bench_fem(mut table: BenchTable, young: Real, dt: Real, label: String, steps: Int):
    var G = Vec3(0, -9.8, 0)
    var be = beam(young)
    var t0 = now()
    for _ in range(steps):
        be.step(dt, G)
    var t1 = now()
    var tip_e = be.pos(be.node_count() - 1)[1]
    var stable_e = tip_e > -1e4 and tip_e < 1e4
    keep(tip_e)
    table.add(
        label + " explicit" + ("" if stable_e else " DIVERGED"),
        be.node_count(), "step", t1 - t0, steps,
    )

    var bi = beam(young)
    var t2 = now()
    var its = 0
    for _ in range(steps):
        its += bi.step_implicit(dt, G).iters
    var t3 = now()
    var tip_i = bi.pos(bi.node_count() - 1)[1]
    var stable_i = tip_i > -1e4 and tip_i < 1e4
    keep(tip_i)
    table.add(
        label + " implicit cg/step=" + String(its // steps)
        + ("" if stable_i else " DIVERGED"),
        bi.node_count(), "step", t3 - t2, steps,
    )


def main() raises:
    var t1 = BenchTable("Global solve vs local iteration (1D Poisson, matched budget)")
    bench_dof(t1, 64, 200)
    bench_dof(t1, 256, 50)
    bench_dof(t1, 1024, 5)
    t1.print_report()

    var t2 = BenchTable("CG's real scale axis: condition number, not size")
    bench_cond(t2, 128, 1.0, "uniform diagonal", 200)
    bench_cond(t2, 128, 1.0e6, "diagonal spans 1e6", 200)
    t2.print_report()

    var t3 = BenchTable("Implicit FEM: the step size a global solve buys")
    bench_fem(t3, 2.0e3, 1.0 / 60.0, "soft E=2e3 dt=1/60", 120)
    bench_fem(t3, 2.0e5, 1.0 / 60.0, "stiff E=2e5 dt=1/60", 120)
    t3.print_report()
