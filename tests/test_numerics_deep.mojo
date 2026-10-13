# tier: integration
"""Numerics / differentiable deepening (ROADMAP 17.84).

  1. Ordinary: `gradcheck` passes the analytic gradient of the Rosenbrock
     function (best error <= 1e-7) and fails one with a sign error in one
     component (error >= 0.1); the landing x of `diffsim.rollout_ctrl` has
     three agreeing gradients: reverse (`rollout_ctrl_adjoint`), forward
     (`DualReal`, one seeded rollout per control) and central differences.
  2. Integration: on a 1D convection-diffusion matrix (upwind, non-symmetric)
     BiCGStab reaches 1e-6 and the solution error is small, while CG on the
     same system does not converge (or converges to a wrong answer); on the SPD
     Poisson matrix BiCGStab and CG agree.
  3. Extreme: `condition_1` of the 5x5 and 6x6 Hilbert matrices matches the
     published 1-norm values (9.4366e5, 2.9070e7) within 5 % (the entries
     are rounded to f32, which moves the 6x6 value by 3 %); mixed-precision refinement
     on Hilbert(5) cuts the residual and the error against a Float64 solve
     of the same (f32-rounded) system by >= 100x; a kinked function (|x|)
     sampled at x = 1e-4 is caught by the schedule hash: the large steps
     that cross the kink are counted and skipped; a singular matrix raises;
     with convection 4 and no reaction the BiCGStab recursion meets 1e-6
     while the true residual does not, and the result says not converged.
"""

from harness.runner import Suite
from harness.gradcheck import GradProblem, GradReport, gradcheck, default_steps, max_rel_diff
from geometry.vec import Real
from geometry.field import DualReal
from physics.diffsim import rollout_ctrl, rollout_ctrl_adjoint
from numerics.sparse import CsrMatrix, poisson_1d
from numerics.cg import cg
from numerics.bicgstab import bicgstab
from numerics.dense import condition_1, solve_dense_refined, solve_dense


struct Rosen(GradProblem):
    var n: Int
    var bug: Bool

    def __init__(out self, n: Int, bug: Bool):
        self.n = n
        self.bug = bug

    def dim(self) -> Int:
        return self.n

    def value(self, x: List[Float64]) -> Float64:
        var f = Float64(0)
        for i in range(self.n - 1):
            f += 100 * (x[i + 1] - x[i] * x[i]) ** 2 + (1 - x[i]) ** 2
        return f

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        for i in range(self.n):
            g[i] = 0
        for i in range(self.n - 1):
            var t = x[i + 1] - x[i] * x[i]
            g[i] += -400 * x[i] * t - 2 * (1 - x[i])
            g[i + 1] += 200 * t
        if self.bug:
            g[1] = -g[1]

    def schedule(self, x: List[Float64]) -> UInt64:
        return 0


struct Kink(GradProblem):
    def __init__(out self):
        pass

    def dim(self) -> Int:
        return 1

    def value(self, x: List[Float64]) -> Float64:
        return abs(x[0])

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        g[0] = 1 if x[0] >= 0 else -1

    def schedule(self, x: List[Float64]) -> UInt64:
        return 1 if x[0] >= 0 else 2


struct Landing(GradProblem):
    """Landing x of the diffsim control rollout as a function of the controls;
    the analytic gradient is the generated reverse sweep."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def dim(self) -> Int:
        return self.n

    def value(self, x: List[Float64]) -> Float64:
        var u = List[Real](capacity=self.n)
        for v in x:
            u.append(Real(v))
        var g = List[Real](length=self.n, fill=0)
        return Float64(rollout_ctrl_adjoint(u, 8, 1.0 / 60.0, g))

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        var u = List[Real](capacity=self.n)
        for v in x:
            u.append(Real(v))
        var gr = List[Real](length=self.n, fill=0)
        _ = rollout_ctrl_adjoint(u, 8, 1.0 / 60.0, gr)
        for i in range(self.n):
            g[i] = Float64(gr[i])

    def schedule(self, x: List[Float64]) -> UInt64:
        return 0


def _convdiff(n: Int, c: Real, sigma: Real) -> CsrMatrix:
    """-u'' + c u' + sigma u on n interior nodes, first-order upwind: row i
    has (-1 - c, 2 + c + sigma, -1). Non-symmetric for c != 0."""
    var r = List[Int]()
    var cl = List[Int]()
    var v = List[Real]()
    for i in range(n):
        r.append(i)
        cl.append(i)
        v.append(2 + c + sigma)
        if i > 0:
            r.append(i)
            cl.append(i - 1)
            v.append(-1 - c)
        if i + 1 < n:
            r.append(i)
            cl.append(i + 1)
            v.append(-1)
    return CsrMatrix.from_triplets(n, r, cl, v)


def _hilbert(n: Int) -> List[Real]:
    var h = List[Real](capacity=n * n)
    for i in range(n):
        for j in range(n):
            h.append(Real(1.0 / Float64(i + j + 1)))
    return h^


def _solve64(a: List[Real], b: List[Real], n: Int) -> List[Real]:
    """Gaussian elimination in Float64 on the stored (f32-rounded) entries:
    the exact answer of the system the solvers actually see."""
    var m = List[Float64]()
    for v in a:
        m.append(Float64(v))
    var r = List[Float64]()
    for v in b:
        r.append(Float64(v))
    for k in range(n):
        var p = k
        for i in range(k + 1, n):
            if abs(m[i * n + k]) > abs(m[p * n + k]):
                p = i
        for j in range(n):
            var t = m[k * n + j]
            m[k * n + j] = m[p * n + j]
            m[p * n + j] = t
        var tr = r[k]
        r[k] = r[p]
        r[p] = tr
        for i in range(k + 1, n):
            var f = m[i * n + k] / m[k * n + k]
            for j in range(k, n):
                m[i * n + j] -= f * m[k * n + j]
            r[i] -= f * r[k]
    var x = List[Float64](length=n, fill=0)
    var i = n - 1
    while i >= 0:
        var acc = r[i]
        for j in range(i + 1, n):
            acc -= m[i * n + j] * x[j]
        x[i] = acc / m[i * n + i]
        i -= 1
    var out = List[Real]()
    for v in x:
        out.append(Real(v))
    return out^


def _err(a: List[Real], b: List[Real]) -> Float64:
    var w = Float64(0)
    for i in range(len(a)):
        w = max(w, abs(Float64(a[i]) - Float64(b[i])))
    return w


def main() raises:
    var s = Suite("numerics_deep")

    # ---- gradcheck ------------------------------------------------------------------
    var x0: List[Float64] = [-1.2, 1.0, 0.5, 0.8]
    var good = gradcheck(Rosen(4, False), x0, default_steps())
    var bad = gradcheck(Rosen(4, True), x0, default_steps())
    print("  rosenbrock: correct gradient best error", good.best_error, "at h", good.best_step, "  sign bug", bad.best_error)
    for k in range(len(good.steps)):
        print("    h", good.steps[k], " error", good.errors[k])
    s.check(good.passed(1e-7), "gradcheck passes the correct Rosenbrock gradient")
    s.check(bad.best_error >= 0.1, "gradcheck fails a gradient with one sign error")

    var nu = 6
    var u0 = List[Float64]()
    for k in range(nu):
        u0.append(0.3 + Float64(k % 3) * 0.1)
    var land = Landing(nu)
    var rep = gradcheck(land, u0, default_steps())
    var rev = List[Float64](length=nu, fill=0)
    land.gradient(u0, rev)
    var fwd = List[Float64]()
    for k in range(nu):
        var ud = List[DualReal]()
        for j in range(nu):
            ud.append(DualReal.seed(Real(u0[j])) if j == k else DualReal.const(Real(u0[j])))
        fwd.append(Float64(rollout_ctrl[DualReal](ud, 8, 1.0 / 60.0).x.b))
    var fr = max_rel_diff(rev, fwd)
    print("  diffsim landing x, 6 controls: reverse vs forward", fr, "  reverse vs central difference", rep.best_error, "at h", rep.best_step)
    s.check(fr <= 1e-6 and rep.passed(1e-3), "reverse, forward and finite-difference gradients agree (f32 primal)")

    var kink = gradcheck(Kink(), [1e-4], default_steps())
    print("  |x| at 1e-4: crossings per step", kink.crossings[0], kink.crossings[1], kink.crossings[2], kink.crossings[3], kink.crossings[4], kink.crossings[5], " best error", kink.best_error)
    s.check(kink.crossings[0] == 1 and kink.crossings[1] == 1 and kink.crossings[3] == 0 and kink.best_error < 1e-9, "steps crossing the kink are counted and skipped")

    # ---- BiCGStab ---------------------------------------------------------------------
    var n = 200
    var a = _convdiff(n, 1.0, 0.1)
    var xt = List[Real]()
    for i in range(n):
        xt.append(Real(1) + Real(i % 7) * 0.25)
    var b = List[Real](length=n, fill=0)
    a.apply(xt, b)
    var xb = List[Real](length=n, fill=0)
    var rb = bicgstab(a, b, xb, 1e-6, 4 * n)
    var xc = List[Real](length=n, fill=0)
    var rc = cg(a, b, xc, 1e-6, 4 * n)
    var eb = _err(xb, xt)
    var ec = _err(xc, xt)
    print("  convection-diffusion n=200 (non-symmetric): bicgstab converged", rb.converged, "true residual", rb.residual, "iters", rb.iters, "error", eb, "  cg converged", rc.converged, "iters", rc.iters, "error", ec)
    s.check(not a.is_symmetric() and rb.converged and eb < 1e-3, "BiCGStab solves the non-symmetric system")
    s.check(not rc.converged or ec > 1e-2, "CG does not (fails or converges to the wrong answer)")
    var xp = List[Real](length=n, fill=0)
    var rp = bicgstab(a, b, xp, 1e-6, 4 * n, True)
    print("  bicgstab + jacobi iters", rp.iters)
    s.check(rp.converged and _err(xp, xt) < 1e-3, "BiCGStab with Jacobi preconditioning also converges")

    var a4 = _convdiff(n, 4.0, 0.0)
    var b4 = List[Real](length=n, fill=0)
    a4.apply(xt, b4)
    var x4 = List[Real](length=n, fill=0)
    var r4 = bicgstab(a4, b4, x4, 1e-6, 4 * n)
    print("  convection-dominated c=4, no reaction: bicgstab converged", r4.converged, "true residual", r4.residual, "error", _err(x4, xt))
    s.check(not r4.converged, "recursive residual met but the true one is not: reported as not converged")

    var p = poisson_1d(64)
    var bp = List[Real](length=64, fill=1)
    var x1 = List[Real](length=64, fill=0)
    var x2 = List[Real](length=64, fill=0)
    var r1 = cg(p, bp, x1, 1e-6)
    var r2 = bicgstab(p, bp, x2, 1e-6)
    print("  poisson n=64: cg iters", r1.iters, r1.converged, r1.residual, " bicgstab iters", r2.iters, r2.converged, r2.residual, " max |dx|", _err(x1, x2))
    s.check(r1.converged and r2.converged and _err(x1, x2) < 1e-4 * _err(x1, List[Real](length=64, fill=0)), "on SPD Poisson both converge to the same answer")

    # ---- dense: condition and refinement --------------------------------------------
    var k5 = condition_1(_hilbert(5), 5)
    var k6 = condition_1(_hilbert(6), 6)
    print("  cond_1 Hilbert(5)", k5, " Hilbert(6)", k6)
    s.check(abs(k5 / 943656.0 - 1) < 0.05 and abs(k6 / 29070279.0 - 1) < 0.05, "condition_1 matches the published Hilbert values")
    var h5 = _hilbert(5)
    var bh = List[Real](length=5, fill=0)
    for i in range(5):
        var acc = Float64(0)
        for j in range(5):
            acc += 1.0 / Float64(i + j + 1)
        bh[i] = Real(acc)
    var plain = solve_dense(h5.copy(), bh.copy(), 5)
    var res = solve_dense_refined(h5, bh, 5, 3)
    var want = _solve64(h5, bh, 5)
    var ep = _err(plain, want)
    var er = _err(res[0], want)
    print("  Hilbert(5): residual before", res[1], "after 3 rounds", res[2], "  error vs f64 solve: plain", ep, "refined", er)
    s.check(res[2] * 100 <= res[1], "refinement cuts the residual by >= 100x")
    s.check(er * 100 <= ep, "refinement cuts the forward error by >= 100x")
    var sing: List[Real] = [1, 2, 2, 4]
    var raised = False
    try:
        _ = condition_1(sing, 2)
    except:
        raised = True
    s.check(raised, "condition_1 raises on a singular matrix")
    s.finish()
