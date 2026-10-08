# tier: unit
"""Dense solves (`numerics.dense`) for the small, fully assembled systems that
articulated dynamics produces (`physics.chain`, `physics.floating`).

Normal systems against known answers, a matrix that needs row pivoting, an
ill-conditioned (Hilbert) one judged by its residual rather than by the
solution, singular input in both flavours (`solve_dense` returns non-finite,
`solve_dense_checked` raises), and the 0x0 / 1x1 edges.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real
from numerics.dense import solve_dense, solve_dense_checked


def _list(*vals: Real) -> List[Real]:
    var out = List[Real]()
    for v in vals:
        out.append(v)
    return out^


def _residual(a: List[Real], x: List[Real], b: List[Real], n: Int) -> Real:
    """max_i |(A x - b)_i|."""
    var worst = Real(0)
    for i in range(n):
        var acc = -b[i]
        for j in range(n):
            acc += a[i * n + j] * x[j]
        if abs(acc) > worst:
            worst = abs(acc)
    return worst


def _raises_checked(var a: List[Real], var b: List[Real], n: Int) -> Bool:
    try:
        _ = solve_dense_checked(a^, b^, n)
    except:
        return True
    return False


def main() raises:
    var s = Suite("dense")

    # ---- normal: SPD 3x3 with a known solution x = (1, -2, 3) ----
    var a3 = _list(4, 1, 0, 1, 3, 1, 0, 1, 2)
    var b3 = _list(4 - 2, 1 - 6 + 3, -2 + 6)  # A x
    var x3 = solve_dense(a3.copy(), b3.copy(), 3)
    s.almost(Float64(x3[0]), 1.0, "3x3 x0", tol=1e-5)
    s.almost(Float64(x3[1]), -2.0, "3x3 x1", tol=1e-5)
    s.almost(Float64(x3[2]), 3.0, "3x3 x2", tol=1e-5)
    s.check(_residual(a3, x3, b3, 3) < 1e-5, "3x3 residual")

    # checked variant agrees bit for bit on a regular system
    var x3c = solve_dense_checked(a3.copy(), b3.copy(), 3)
    var same = True
    for i in range(3):
        if x3c[i] != x3[i]:
            same = False
    s.check(same, "checked == unchecked on a regular matrix")

    # ---- pivoting: zero on the diagonal, solvable only with a row swap ----
    var ap = _list(0, 2, 1, 0)
    var xp = solve_dense(ap.copy(), _list(4, 3), 2)
    s.almost(Float64(xp[0]), 3.0, "pivot x0", tol=1e-6)
    s.almost(Float64(xp[1]), 2.0, "pivot x1", tol=1e-6)

    # ---- ill-conditioned: Hilbert 4x4 (cond ~ 1.5e4) ----
    var hil = List[Real]()
    for i in range(4):
        for j in range(4):
            hil.append(Real(1) / Real(i + j + 1))
    var bh = _list(1, 1, 1, 1)
    var xh = solve_dense(hil.copy(), bh.copy(), 4)
    s.check(_residual(hil, xh, bh, 4) < 1e-4, "Hilbert residual is small")
    var xhc = solve_dense_checked(hil.copy(), bh.copy(), 4)
    s.check(
        _residual(hil, xhc, bh, 4) < 1e-4,
        "default tolerance accepts Hilbert 4x4 (not flagged singular)",
    )
    var strict_raises = False
    try:
        _ = solve_dense_checked(hil.copy(), bh.copy(), 4, tol=0.1)
    except:
        strict_raises = True
    s.check(strict_raises, "a coarse tol flags the ill-conditioned matrix")

    # ---- singular: unchecked yields non-finite, checked raises ----
    var asg = _list(1, 2, 2, 4)
    var bsg = _list(1, 2)
    var xs = solve_dense(asg.copy(), bsg.copy(), 2)
    s.check(
        not (isfinite(xs[0]) and isfinite(xs[1])),
        "unchecked singular solve is non-finite, not a crash",
    )
    s.check(_raises_checked(asg.copy(), bsg.copy(), 2), "checked: singular raises")
    s.check(
        _raises_checked(_list(1, 1, 1, 1 + 1e-9), _list(1, 1), 2),
        "checked: singular to working precision raises",
    )
    s.check(_raises_checked(_list(0, 0, 0, 0), _list(1, 1), 2), "checked: zero matrix raises")
    s.check(
        _raises_checked(_list(1, 2, 3), _list(1, 2), 2),
        "checked: wrong matrix size raises",
    )

    # ---- edges: 1x1 and 0x0 ----
    var x1 = solve_dense(_list(4), _list(2), 1)
    s.eqi(len(x1), 1, "1x1 length")
    s.almost(Float64(x1[0]), 0.5, "1x1 value", tol=1e-7)
    s.check(_raises_checked(_list(0), _list(1), 1), "checked 1x1: zero raises")
    var x1c = solve_dense_checked(_list(-8), _list(4), 1)
    s.almost(Float64(x1c[0]), -0.5, "checked 1x1 value", tol=1e-7)

    var x0 = solve_dense(List[Real](), List[Real](), 0)
    s.eqi(len(x0), 0, "0x0 returns an empty solution")
    var x0c = solve_dense_checked(List[Real](), List[Real](), 0)
    s.eqi(len(x0c), 0, "checked 0x0 returns an empty solution")

    s.finish()
