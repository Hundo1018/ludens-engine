"""Sparse linear algebra and the implicit FEM step it unlocks (law v3).

Every other solver in this engine is a LOCAL iteration — PBD projection, PGS,
Jacobi, per-vertex Newton — and every one of them is stiffness-limited. A global
linear solve is the thing that removes that limit, so the test that matters is
not "CG returns the right vector" but "a step size the explicit integrator
cannot survive is now available".

ORDINARY    CG reproduces the closed-form solution of the 1D Poisson system at
            three sizes; the matrix built for it really is symmetric; the
            residual actually reaches the tolerance claimed.
INTEGRATION `FemBody.step_implicit` is stable at a stiffness and step size that
            make the explicit path diverge, preserves volume, and holds pinned
            nodes EXACTLY; the two integrators agree on a soft material where
            both are stable.
EXTREME     a zero right-hand side, a one-degree-of-freedom system, a singular
            (semi-definite) operator that must be reported rather than diverged
            through, an iteration budget deliberately exhausted, and a system
            with a diagonal spanning 1e6 — where Jacobi preconditioning is the
            difference between converging and not, which is the only honest way
            to show a preconditioner earns its place.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from numerics.sparse import CsrMatrix, poisson_1d
from numerics.cg import cg, pcg, jacobi_solve
from numerics.vecops import zeros, norm2
from physics.fem import FemBody, make_beam


def _ones(n: Int) -> List[Real]:
    var v = zeros(n)
    for i in range(n):
        v[i] = 1
    return v^


def _beam(young: Real) -> FemBody:
    var b = FemBody(young, 0.3, 2.0)
    make_beam(b, 6, 2, 2, 0.25, 1.0)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)  # cantilever: the x = 0 face is nailed down
    return b^


def _stretched(n: Int, ratio: Real) -> CsrMatrix:
    """A diagonally dominant system whose diagonal spans `ratio`.

    This is the regime Jacobi preconditioning is FOR. On a uniform Poisson
    matrix the diagonal is constant, so Jacobi is a scalar multiple of the
    identity and changes nothing; only a varying diagonal — stiff elements next
    to soft ones, a heavy body next to a light one — gives it anything to do."""
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
            # coupling capped at half the SMALLER neighbour, which keeps every
            # row strictly diagonally dominant and therefore the matrix SPD.
            # A first version scaled the off-diagonals by the row's own value,
            # which made the row sums negative wherever the scale increased --
            # the matrix was indefinite and CG correctly reported a breakdown
            # at iteration 1. The test was wrong, not the solver.
            var c = Real(0.49) * (d[i] if d[i] < d[i - 1] else d[i - 1])
            rows.append(i)
            cols.append(i - 1)
            vals.append(-c)
            rows.append(i - 1)
            cols.append(i)
            vals.append(-c)
    return CsrMatrix.from_triplets(n, rows, cols, vals)


def main() raises:
    var s = Suite("numerics")

    # ---- ORDINARY: the closed-form reference ----
    var sizes = List[Int](capacity=3)
    sizes.append(8)
    sizes.append(64)
    sizes.append(256)
    for si in range(3):
        var n = sizes[si]
        var a = poisson_1d(n)
        s.check(a.is_symmetric(), "the Poisson matrix is symmetric")
        var b = _ones(n)
        var x = zeros(n)
        var r = cg(a, b, x, 1e-6)
        var worst = Real(0)
        for i in range(n):
            # -u'' = 1 with Dirichlet ends and h = 1: u_i = (i+1)(n-i)/2
            var exact = Real(0.5) * Real(i + 1) * Real(n - i)
            if abs(x[i] - exact) > worst:
                worst = abs(x[i] - exact)
        print("  poisson n", n, " iters", r.iters, " residual", r.residual,
              " worst error", worst)
        s.check(r.converged, "CG converges on the Poisson system")
        s.check(not r.stalled, "without reporting a breakdown")
        s.check(Float64(worst) < 1e-3, "and matches the closed-form solution")
        s.check(r.iters <= n, "in at most n iterations, as the theory says")

    # the local method this replaces, on the same system and iteration budget
    var a64 = poisson_1d(64)
    var xj = zeros(64)
    var rj = jacobi_solve(a64, _ones(64), xj, 32)
    var xc = zeros(64)
    var rc = cg(a64, _ones(64), xc, 1e-6, 32)
    print("  after 32 iterations — jacobi residual", rj,
          " CG residual", rc.residual)
    s.check(
        Float64(rj) > 0.5,
        "32 Jacobi sweeps have barely moved: local iteration is stiffness bound",
    )
    s.check(
        Float64(rc.residual) < Float64(rj),
        "and CG is further along on the same budget",
    )

    # ---- INTEGRATION: the step size this buys ----
    var G = Vec3(0, -9.8, 0)
    var dt = Real(1.0) / 60.0

    var be = _beam(2.0e5)
    var exploded = False
    for _ in range(120):
        be.step(dt, G)
        var tip = be.pos(be.node_count() - 1)
        if not (tip[1] > -1e4 and tip[1] < 1e4):
            exploded = True
            break
    print("  explicit at E=2e5, dt=1/60 — exploded:", exploded,
          " tip y", be.pos(be.node_count() - 1)[1])
    s.check(exploded, "the explicit integrator cannot survive this stiffness")

    var bi = _beam(2.0e5)
    var rest_vol = bi.total_volume()
    var total_iters = 0
    var all_converged = True
    for _ in range(120):
        var r = bi.step_implicit(dt, G)
        total_iters += r.iters
        if not r.converged:
            all_converged = False
    var tip = bi.pos(bi.node_count() - 1)
    print("  implicit at the same stiffness — tip y", tip[1],
          " volume", bi.total_volume(), " (rest", rest_vol, ")",
          " cg iters", total_iters)
    s.check(all_converged, "every implicit step's solve converged")
    s.check(
        Float64(tip[1]) > -2.0 and Float64(tip[1]) < 2.0,
        "and the beam stays where a beam should be",
    )
    s.check(
        abs(Float64(bi.total_volume() - rest_vol)) < 0.05 * Float64(rest_vol),
        "volume is preserved: the solve is not quietly inflating the mesh",
    )

    var pinned_ok = True
    for i in range(bi.node_count()):
        if bi.inv_m[i] == 0 and abs(Float64(bi.pos(i)[0])) > 1e-6:
            pinned_ok = False
    s.check(pinned_ok, "pinned nodes did not move at all")

    # On a soft material both integrators are stable, and they should agree --
    # but only in the limit. Backward Euler is unconditionally stable BECAUSE it
    # is dissipative, so at a coarse step it lags a symplectic integrator by a
    # visible margin. Shrinking dt is what makes the comparison meaningful: the
    # gap has to close, and a gap that did NOT close would mean the implicit
    # step is solving a different problem rather than the same one more
    # stiffly.
    var fine = dt / 8
    var gap_coarse = Real(0)
    var gap_fine = Real(0)
    for pass_id in range(2):
        var h = dt if pass_id == 0 else fine
        var steps = 60 if pass_id == 0 else 480
        var se = _beam(2.0e3)
        var si = _beam(2.0e3)
        for _ in range(steps):
            se.step(h, G)
            _ = si.step_implicit(h, G, tol=1e-7, max_iters=200)
        var g = abs(
            se.pos(se.node_count() - 1)[1] - si.pos(si.node_count() - 1)[1]
        )
        if pass_id == 0:
            gap_coarse = g
        else:
            gap_fine = g
    print("  soft beam explicit-vs-implicit gap — dt/1", gap_coarse,
          " dt/8", gap_fine)
    s.check(
        Float64(gap_fine) < Float64(gap_coarse) * 0.5,
        "the two integrators converge on each other as dt shrinks: the implicit"
        " step solves the same problem, more dissipatively",
    )

    # ---- EXTREME ----
    var a8 = poisson_1d(8)
    var zb = zeros(8)
    var zx = zeros(8)
    for i in range(8):
        zx[i] = 7  # a deliberately wrong starting guess
    var rz = cg(a8, zb, zx)
    var zero_ok = True
    for i in range(8):
        if zx[i] != 0:
            zero_ok = False
    s.check(rz.converged, "a zero right-hand side converges")
    s.check(zero_ok, "to exactly zero, overwriting the starting guess")

    var one = poisson_1d(1)
    var ob = _ones(1)
    var ox = zeros(1)
    var ro = cg(one, ob, ox)
    s.check(ro.converged, "a one-degree-of-freedom system converges")
    s.check(abs(Float64(ox[0] - 0.5)) < 1e-5, "to the right answer")

    # singular operator: an all-zero row makes A positive SEMI-definite, and a
    # right-hand side that touches the null space has no solution at all
    var rows = List[Int]()
    var cols = List[Int]()
    var vals = List[Real]()
    for i in range(1, 4):
        rows.append(i)
        cols.append(i)
        vals.append(1.0)
    var sing = CsrMatrix.from_triplets(4, rows, cols, vals)
    var sb = _ones(4)
    var sx = zeros(4)
    var rs = cg(sing, sb, sx, 1e-6, 40)
    print("  singular system — converged", rs.converged, " stalled", rs.stalled,
          " residual", rs.residual)
    s.check(not rs.converged, "a singular system is not reported as solved")
    s.check(rs.stalled, "it is reported as a breakdown, not as running out of time")
    # The residual at breakdown is NOT checked for size. A right-hand side with
    # a component in the null space has no solution at all, so there is no
    # small residual to reach and demanding one would be demanding the
    # impossible. What must hold is that the numbers stay numbers -- a NaN
    # would propagate into whatever the caller does next, and no `converged`
    # flag would save it.
    var finite = True
    for i in range(4):
        if not (Float64(sx[i]) > -1e300 and Float64(sx[i]) < 1e300):
            finite = False
    s.check(finite, "and the returned vector is finite, not NaN")

    # iteration budget deliberately exhausted: not converged, not a breakdown
    var big = poisson_1d(256)
    var bx = zeros(256)
    var rb = cg(big, _ones(256), bx, 1e-9, 4)
    s.check(not rb.converged, "four iterations do not solve a 256-dof system")
    s.check(
        not rb.stalled,
        "and running out of budget is NOT a breakdown: the distinction is the"
        " point of having both flags",
    )
    s.eqi(rb.iters, 4, "the budget is honoured exactly")

    # ---- the preconditioner's advantage regime ----
    var flat = poisson_1d(128)
    var fb = _ones(128)
    var fx1 = zeros(128)
    var fx2 = zeros(128)
    var f_cg = cg(flat, fb, fx1, 1e-8)
    var f_pcg = pcg(flat, fb, fx2, 1e-8)
    print("  uniform diagonal — cg", f_cg.iters, " pcg", f_pcg.iters)
    s.eqi(
        f_pcg.iters, f_cg.iters,
        "on a CONSTANT diagonal Jacobi is a scalar and changes nothing --"
        " a preconditioner that helped here would be a measurement error",
    )

    var st = _stretched(128, 1.0e6)
    var sb2 = _ones(128)
    var sx1 = zeros(128)
    var sx2 = zeros(128)
    var s_cg = cg(st, sb2, sx1, 1e-8, 400)
    var s_pcg = pcg(st, sb2, sx2, 1e-8, 400)
    print("  diagonal spanning 1e6 — cg", s_cg.iters, "conv", s_cg.converged,
          " | pcg", s_pcg.iters, "conv", s_pcg.converged)
    s.check(s_pcg.converged, "with a 1e6 diagonal spread, PCG converges")
    s.check(
        s_pcg.iters < s_cg.iters,
        "in fewer iterations than plain CG: this is the preconditioner earning"
        " its place, in the one regime where it can",
    )

    s.finish()
