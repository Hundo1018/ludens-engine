"""Small dense linear solves (Gaussian elimination, partial pivoting).

The sparse/Krylov half of this package (`cg`, `sparse`) targets large systems
that only exist as an operator. Articulated-body dynamics produces the other
kind: a few dozen unknowns, the matrix fully assembled and row-major, solved
once or many times per step (`physics.chain` solves `H x = rhs` for the joint
accelerations and for `H^-1 J^T`). Iterating CG there would cost more than the
direct solve it replaces, so the direct solve lives here, next to the Krylov
solvers, and every caller shares one implementation.

Storage: a matrix is a flat row-major `List[Real]` of `n * n` entries, a
right-hand side a `List[Real]` of `n`. Both are taken BY VALUE: the
elimination overwrites them, and a caller that still needs its copy passes
`.copy()` (which is also what lets a one-shot caller hand the buffer over
with `^` and pay nothing).

Two entry points, differing only in what happens to a singular matrix:

- `solve_dense`: never raises, for hot paths. A matrix that is exactly
  singular after pivoting divides by a zero pivot, so the result holds
  inf / NaN under IEEE rules; a nearly singular one returns a large,
  inaccurate answer. The step-end NaN quarantine (docs/ARCHITECTURE.md S2) is
  the net for that class, as for any other numerical failure.
- `solve_dense_checked`: raises `Error` when a pivot is not larger than
  `tol` times the largest entry of the matrix, i.e. when the system is
  singular or so close to it that the answer would be noise. Use it at API
  boundaries where the matrix comes from the caller.

Cost is O(n^3) for the elimination, O(n^2) for the back-substitution. Partial
pivoting makes the elimination stable for any non-singular matrix in the
usual sense; the accuracy of the answer is still limited by the condition
number of the matrix (about `cond * epsilon` relative error in `Real`).
`condition_1` computes that condition number (Float64 LU, O(n^3));
`solve_dense_refined` recovers Float64-level accuracy by mixed-precision
iterative refinement while cond * 6e-8 < 1 (ROADMAP 17.84).
"""

from std.math import sqrt
from geometry.vec import Real


def _eliminate(mut a: List[Real], mut b: List[Real], n: Int) -> Real:
    """Forward elimination with partial pivoting, in place. Returns the
    smallest pivot magnitude seen (0 for `n == 0` is never reported: an empty
    system has no pivot, and the return is then the largest finite `Real`)."""
    var smallest = Real.MAX
    for col in range(n):
        var piv = col
        var best = abs(a[col * n + col])
        for r in range(col + 1, n):
            if abs(a[r * n + col]) > best:
                best = abs(a[r * n + col])
                piv = r
        if piv != col:
            for cc in range(n):
                var tmp = a[col * n + cc]
                a[col * n + cc] = a[piv * n + cc]
                a[piv * n + cc] = tmp
            var tr = b[col]
            b[col] = b[piv]
            b[piv] = tr
        var d = a[col * n + col]
        if abs(d) < smallest:
            smallest = abs(d)
        for r in range(col + 1, n):
            var fscale = a[r * n + col] / d
            for cc in range(col, n):
                a[r * n + cc] -= fscale * a[col * n + cc]
            b[r] -= fscale * b[col]
    return smallest


def _back_substitute(a: List[Real], b: List[Real], n: Int) -> List[Real]:
    var x = List[Real]()
    for _ in range(n):
        x.append(0)
    var r = n - 1
    while r >= 0:
        var acc = b[r]
        for cc in range(r + 1, n):
            acc -= a[r * n + cc] * x[cc]
        x[r] = acc / a[r * n + r]
        r -= 1
    return x^


def solve_dense(var a: List[Real], var b: List[Real], n: Int) -> List[Real]:
    """Solve `A x = b` for the row-major `n x n` matrix `a`.

    `n == 0` returns an empty list. A singular `a` is NOT reported: the result
    then contains inf / NaN (see the module doc); use `solve_dense_checked`
    when the matrix is not known to be non-singular. The sizes
    (`len(a) == n * n`, `len(b) == n`) are a caller invariant."""
    debug_assert(len(a) == n * n, "solve_dense: matrix is not n x n")
    debug_assert(len(b) == n, "solve_dense: rhs is not length n")
    _ = _eliminate(a, b, n)
    return _back_substitute(a, b, n)


def cholesky(a: List[Real], n: Int) -> Tuple[List[Real], Bool]:
    """Lower-triangular L (row-major n x n) with L L^T = a, for a symmetric
    positive definite `a` (17.51: a mass matrix factored once and reused for
    every right-hand side). False when a pivot is not positive."""
    var l = List[Real](length=n * n, fill=0)
    for i in range(n):
        for j in range(i + 1):
            var acc = a[i * n + j]
            for k in range(j):
                acc -= l[i * n + k] * l[j * n + k]
            if i == j:
                if not (acc > 0):
                    return (l^, False)
                l[i * n + i] = sqrt(acc)
            else:
                l[i * n + j] = acc / l[j * n + j]
    return (l^, True)


def cholesky_solve(l: List[Real], b: List[Real], n: Int) -> List[Real]:
    """Solve L L^T x = b: forward then back substitution, O(n^2)."""
    var y = List[Real](length=n, fill=0)
    for i in range(n):
        var acc = b[i]
        for k in range(i):
            acc -= l[i * n + k] * y[k]
        y[i] = acc / l[i * n + i]
    var x = List[Real](length=n, fill=0)
    var i = n - 1
    while i >= 0:
        var acc = y[i]
        for k in range(i + 1, n):
            acc -= l[k * n + i] * x[k]
        x[i] = acc / l[i * n + i]
        i -= 1
    return x^


def solve_dense_checked(
    var a: List[Real], var b: List[Real], n: Int, tol: Real = 1e-6
) raises -> List[Real]:
    """`solve_dense` that raises on a singular or nearly singular matrix.

    A pivot whose magnitude is `<= tol * max|a_ij|` (measured on the input
    matrix) counts as zero, as does a non-finite one. The default `tol` is
    about ten times `Real`'s epsilon, so it flags only systems whose answer
    would be mostly rounding error. A zero matrix raises for any `n >= 1`."""
    if len(a) != n * n or len(b) != n:
        raise Error("solve_dense_checked: sizes do not match n")
    var scale = Real(0)
    for i in range(len(a)):
        if abs(a[i]) > scale:
            scale = abs(a[i])
    var smallest = _eliminate(a, b, n)
    if n > 0 and not (smallest > tol * scale):
        raise Error("solve_dense_checked: matrix is singular to working precision")
    return _back_substitute(a, b, n)


def _lu64(a: List[Float64], n: Int, mut lu: List[Float64], mut piv: List[Int]) -> Bool:
    """Float64 LU with partial pivoting (row-major, in `lu`); False if a
    pivot is exactly zero."""
    for i in range(n * n):
        lu[i] = a[i]
    for i in range(n):
        piv[i] = i
    for k in range(n):
        var m = k
        for r in range(k + 1, n):
            if abs(lu[r * n + k]) > abs(lu[m * n + k]):
                m = r
        if lu[m * n + k] == 0:
            return False
        if m != k:
            for c in range(n):
                var t = lu[k * n + c]
                lu[k * n + c] = lu[m * n + c]
                lu[m * n + c] = t
            var tp = piv[k]
            piv[k] = piv[m]
            piv[m] = tp
        for r in range(k + 1, n):
            var f = lu[r * n + k] / lu[k * n + k]
            lu[r * n + k] = f
            for c in range(k + 1, n):
                lu[r * n + c] -= f * lu[k * n + c]
    return True


def _lu_solve64(lu: List[Float64], piv: List[Int], n: Int, b: List[Float64]) -> List[Float64]:
    var y = List[Float64](length=n, fill=0)
    for i in range(n):
        var s = b[piv[i]]
        for j in range(i):
            s -= lu[i * n + j] * y[j]
        y[i] = s
    var x = List[Float64](length=n, fill=0)
    var i = n - 1
    while i >= 0:
        var s = y[i]
        for j in range(i + 1, n):
            s -= lu[i * n + j] * x[j]
        x[i] = s / lu[i * n + i]
        i -= 1
    return x^


def condition_1(a: List[Real], n: Int) raises -> Float64:
    """The 1-norm condition number ||A||_1 ||A^-1||_1, computed exactly in
    Float64 through an LU factorisation (O(n^3); meant for the small dense
    systems this module solves, ROADMAP 17.84). Raises on a singular A."""
    if len(a) != n * n:
        raise Error("condition_1: matrix is not n x n")
    var a64 = List[Float64](capacity=n * n)
    for v in a:
        a64.append(Float64(v))
    var lu = List[Float64](length=n * n, fill=0)
    var piv = List[Int](length=n, fill=0)
    if not _lu64(a64, n, lu, piv):
        raise Error("condition_1: matrix is singular")
    var norm_a = Float64(0)
    var norm_inv = Float64(0)
    for j in range(n):
        var col = Float64(0)
        for i in range(n):
            col += abs(a64[i * n + j])
        norm_a = max(norm_a, col)
        var e = List[Float64](length=n, fill=0)
        e[j] = 1
        var x = _lu_solve64(lu, piv, n, e)
        var ci = Float64(0)
        for i in range(n):
            ci += abs(x[i])
        norm_inv = max(norm_inv, ci)
    return norm_a * norm_inv


def _resid64(a: List[Real], b: List[Real], n: Int, x: List[Float64], mut r: List[Real]) -> Float64:
    """r = b - A x formed in Float64 (stored as Real for the f32 correction
    solve); returns max |r|."""
    var worst = Float64(0)
    for i in range(n):
        var s = Float64(b[i])
        for j in range(n):
            s -= Float64(a[i * n + j]) * x[j]
        r[i] = Real(s)
        worst = max(worst, abs(s))
    return worst


def solve_dense_refined(a: List[Real], b: List[Real], n: Int, rounds: Int = 3) -> Tuple[List[Real], Float64, Float64]:
    """`solve_dense` (f32 elimination) followed by `rounds` of mixed-precision
    iterative refinement: x is accumulated in Float64, the residual
    r = b - A x is formed in Float64 and the correction solved with the same
    f32 elimination. Converges while cond(A) * 6e-8 < 1 (see `condition_1`).
    Returns (x, residual before, residual after) as max-norm relative to
    max |b|."""
    var x32 = solve_dense(a.copy(), b.copy(), n)
    var x = List[Float64](capacity=n)
    for v in x32:
        x.append(Float64(v))
    var bmax = Float64(0)
    for v in b:
        bmax = max(bmax, abs(Float64(v)))
    if bmax == 0:
        bmax = 1
    var r = List[Real](length=n, fill=0)
    var before = _resid64(a, b, n, x, r) / bmax
    var after = before
    for _ in range(rounds):
        var d = solve_dense(a.copy(), r.copy(), n)
        for i in range(n):
            x[i] += Float64(d[i])
        after = _resid64(a, b, n, x, r) / bmax
    var out = List[Real](capacity=n)
    for v in x:
        out.append(Real(v))
    return (out^, before, after)
