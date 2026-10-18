"""Numerics deepening (ROADMAP 17.84): what the new solvers and checks cost.

NON-SYMMETRIC SOLVE. Upwind convection-diffusion (-u'' + u' + 0.1 u, row
(-2, 3.1, -1)): BiCGStab with and without Jacobi, and CG on the same system
for contrast. CG's row carries its final error against the known x: on a
non-symmetric operator it does not converge, so its time buys nothing. The
diagonal is constant, so Jacobi is a scalar multiple of the identity here;
it still changes the rounding, and on this non-normal matrix that alone can
flip BiCGStab between converging and not (the n=1024 rows).

SYMMETRIC INDEFINITE SOLVE. A saddle point [[K, B^T], [B, 0]] (K the
m x m 5-point Poisson block + 0.01 I, B m^2/8 rows x_8k - x_8k+3): MINRES
with and without |diag| preconditioning vs restarted GMRES(30), and CG as
the wrong solver (it does not converge on an indefinite operator).

PARALLEL SPMV. `CsrMatrix.apply` vs `ParallelCsr.apply` (blocks of 2048
rows on the default pool) on the saddle-point matrix above; the product is bit-identical
(`test_par_spmv`), so the rows differ only in time.

DENSE REFINEMENT. `solve_dense` (f32 elimination) vs `solve_dense_refined`
(3 rounds, residual in f64) vs `condition_1` (f64 LU plus n solves) on a
diagonally dominant random-ish matrix: the price of the accuracy.

GRADCHECK. One `gradcheck` of the diffsim landing x over 6 controls and 6
step sizes: 72 rollouts plus one adjoint. Reported per call.

Run with: `mojo run -I build benchmarks/bench_numerics_deep.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real
from numerics.sparse import CsrMatrix, ParallelCsr
from numerics.cg import cg
from numerics.bicgstab import bicgstab
from numerics.gmres import gmres
from numerics.minres import minres
from numerics.dense import solve_dense, solve_dense_refined, condition_1
from physics.diffsim import rollout_ctrl_adjoint
from harness.bench import BenchTable, now
from harness.gradcheck import GradProblem, gradcheck, default_steps


def convdiff(n: Int) -> CsrMatrix:
    var r = List[Int]()
    var cl = List[Int]()
    var v = List[Real]()
    for i in range(n):
        r.append(i)
        cl.append(i)
        v.append(3.1)
        if i > 0:
            r.append(i)
            cl.append(i - 1)
            v.append(-2)
        if i + 1 < n:
            r.append(i)
            cl.append(i + 1)
            v.append(-1)
    return CsrMatrix.from_triplets(n, r, cl, v)


def max_err(a: List[Real], b: List[Real]) -> Float64:
    var w = Float64(0)
    for i in range(len(a)):
        w = max(w, abs(Float64(a[i]) - Float64(b[i])))
    return w


def solve_once(a: CsrMatrix, b: List[Real], xt: List[Real], which: Int) -> Tuple[Int, Bool, Float64]:
    var n = a.size()
    var x = List[Real](length=n, fill=0)
    if which == 2:
        var r = cg(a, b, x, 1e-6, 4 * n)
        return (r.iters, r.converged, max_err(x, xt))
    if which == 3 or which == 4:
        var r = minres(a, b, x, 1e-6, 0, which == 4)
        return (r.iters, r.converged, max_err(x, xt))
    if which == 5:
        var r = gmres(a, b, x, 1e-6, 8 * n, 30, False)
        return (r.iters, r.converged, max_err(x, xt))
    var r = bicgstab(a, b, x, 1e-6, 4 * n, which == 1)
    return (r.iters, r.converged, max_err(x, xt))


def bench_row(mut t: BenchTable, name: String, a: CsrMatrix, b: List[Real], xt: List[Real], which: Int, reps: Int):
    var it = 0
    var ok = False
    var err = Float64(0)
    var t0 = now()
    for _ in range(reps):
        var r = solve_once(a, b, xt, which)
        it = r[0]
        ok = r[1]
        err = r[2]
    var t1 = now()
    keep(err)
    t.add(name + " iters=" + String(it) + " converged=" + String(ok) + " err=" + String(Float32(err)), a.size(), "solve", t1 - t0, reps)


def bench_nonsym(mut t: BenchTable, n: Int, reps: Int):
    var a = convdiff(n)
    var xt = List[Real]()
    for i in range(n):
        xt.append(Real(1) + Real(i % 7) * 0.25)
    var b = List[Real](length=n, fill=0)
    a.apply(xt, b)
    bench_row(t, "bicgstab", a, b, xt, 0, reps)
    bench_row(t, "bicgstab+jacobi", a, b, xt, 1, reps)
    bench_row(t, "cg (wrong solver)", a, b, xt, 2, reps)


def saddle(m: Int) -> CsrMatrix:
    var r = List[Int]()
    var cl = List[Int]()
    var v = List[Real]()
    for i in range(m):
        for j in range(m):
            var k = i * m + j
            r.append(k)
            cl.append(k)
            v.append(4.01)
            var nb: List[Int] = [k - m if i > 0 else -1, k + m if i + 1 < m else -1, k - 1 if j > 0 else -1, k + 1 if j + 1 < m else -1]
            for q in nb:
                if q >= 0:
                    r.append(k)
                    cl.append(q)
                    v.append(-1)
    var nc = m * m // 8
    for c in range(nc):
        for e in range(2):
            var s = Real(1) if e == 0 else Real(-1)
            r.append(m * m + c)
            cl.append(8 * c + 3 * e)
            v.append(s)
            r.append(8 * c + 3 * e)
            cl.append(m * m + c)
            v.append(s)
    return CsrMatrix.from_triplets(m * m + nc, r, cl, v)


def bench_indef(mut t: BenchTable, m: Int, reps: Int):
    var a = saddle(m)
    var n = a.size()
    var xt = List[Real]()
    for i in range(n):
        xt.append(Real(1) + Real(i % 7) * 0.25)
    var b = List[Real](length=n, fill=0)
    a.apply(xt, b)
    bench_row(t, "minres", a, b, xt, 3, reps)
    bench_row(t, "minres+absdiag", a, b, xt, 4, reps)
    bench_row(t, "gmres(30)", a, b, xt, 5, reps)
    bench_row(t, "cg (wrong solver)", a, b, xt, 2, reps)


def bench_spmv(mut t: BenchTable, m: Int, reps: Int):
    var a = saddle(m)
    var n = a.size()
    var x = List[Real](length=n, fill=1)
    var y = List[Real](length=n, fill=0)
    var t0 = now()
    for _ in range(reps):
        a.apply(x, y)
        keep(y[n // 2])
    var t1 = now()
    t.add("serial", n, "spmv", t1 - t0, reps)
    var p = ParallelCsr(saddle(m))
    t0 = now()
    for _ in range(reps):
        p.apply(x, y)
        keep(y[n // 2])
    t1 = now()
    t.add("parallel (2048-row blocks)", n, "spmv", t1 - t0, reps)


def dense_matrix(n: Int) -> List[Real]:
    var a = List[Real](capacity=n * n)
    for i in range(n):
        for j in range(n):
            var v = Real(((i * 7 + j * 13) % 17)) / 17 - 0.5
            if i == j:
                v += Real(n) * 0.6
            a.append(v)
    return a^


def bench_dense(mut t: BenchTable, n: Int, reps: Int) raises:
    var a = dense_matrix(n)
    var b = List[Real](length=n, fill=1)
    var acc = Real(0)
    var t0 = now()
    for _ in range(reps):
        acc += solve_dense(a.copy(), b.copy(), n)[0]
    var t1 = now()
    var after = Float64(0)
    for _ in range(reps):
        var r = solve_dense_refined(a, b, n, 3)
        acc += r[0][0]
        after = r[2]
    var t2 = now()
    var k = Float64(0)
    for _ in range(reps):
        k = condition_1(a, n)
    var t3 = now()
    keep(acc)
    t.add("solve_dense (f32)", n, "solve", t1 - t0, reps)
    t.add("solve_dense_refined 3 rounds, residual " + String(Float32(after)), n, "solve", t2 - t1, reps)
    t.add("condition_1 = " + String(Float32(k)), n, "estimate", t3 - t2, reps)


struct Landing(GradProblem):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def dim(self) -> Int:
        return self.n

    def value(self, x: List[Float64]) -> Float64:
        var u = List[Real]()
        for v in x:
            u.append(Real(v))
        var g = List[Real](length=self.n, fill=0)
        return Float64(rollout_ctrl_adjoint(u, 8, 1.0 / 60.0, g))

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        var u = List[Real]()
        for v in x:
            u.append(Real(v))
        var gr = List[Real](length=self.n, fill=0)
        _ = rollout_ctrl_adjoint(u, 8, 1.0 / 60.0, gr)
        for i in range(self.n):
            g[i] = Float64(gr[i])

    def schedule(self, x: List[Float64]) -> UInt64:
        return 0


def main() raises:
    var t1 = BenchTable("Non-symmetric solve: BiCGStab vs CG (convection-diffusion, 17.84)")
    bench_nonsym(t1, 256, 20)
    bench_nonsym(t1, 1024, 5)
    bench_nonsym(t1, 4096, 2)
    t1.print_report()

    var t4 = BenchTable("Symmetric indefinite solve: MINRES vs GMRES(30) vs CG (saddle point, 17.84)")
    bench_indef(t4, 16, 20)
    bench_indef(t4, 32, 5)
    t4.print_report()

    var t5 = BenchTable("SpMV: serial vs ParallelCsr (Poisson saddle matrix, 17.84)")
    bench_spmv(t5, 32, 2000)
    bench_spmv(t5, 128, 200)
    bench_spmv(t5, 512, 20)
    t5.print_report()

    var t2 = BenchTable("Dense solve: f32 elimination, mixed-precision refinement, condition number (17.84)")
    bench_dense(t2, 8, 2000)
    bench_dense(t2, 32, 200)
    t2.print_report()

    var t3 = BenchTable("gradcheck: diffsim landing x, 6 controls x 6 steps (17.84)")
    var p = Landing(6)
    var x = List[Float64]()
    for k in range(6):
        x.append(0.3 + Float64(k % 3) * 0.1)
    var reps = 50
    var e = Float64(0)
    var t0 = now()
    for _ in range(reps):
        e = gradcheck(p, x, default_steps()).best_error
    var tt = now()
    t3.add("gradcheck best error " + String(Float32(e)), 6, "check", tt - t0, reps)
    t3.print_report()
