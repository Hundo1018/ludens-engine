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
number of the matrix (about `cond * epsilon` relative error in `Real`), which
this module does not estimate.
"""

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
