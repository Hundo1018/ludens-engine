"""Flat-vector primitives shared by the solvers.

Vectors are `List[Real]`, not `List[Vec3]`: a width-3 SIMD list loses its tail
elements when passed between functions on this nightly, and a Krylov solver
passes vectors across function boundaries thousands of times per solve.
`collision/hull.mojo` carries the reduced probe.
"""

from geometry.vec import Real


def zeros64(n: Int) -> List[Float64]:
    var v = List[Float64](capacity=n)
    for _ in range(n):
        v.append(0)
    return v^


def dot64(a: List[Float64], b: List[Float64]) -> Float64:
    var acc = Float64(0)
    for i in range(len(a)):
        acc += a[i] * b[i]
    return acc


def axpy64(alpha: Float64, x: List[Float64], mut y: List[Float64]):
    """In-place `y += alpha * x`."""
    for i in range(len(y)):
        y[i] += alpha * x[i]


def scale_add64(alpha: Float64, mut x: List[Float64], y: List[Float64]):
    """In-place `x = alpha * x + y`."""
    for i in range(len(x)):
        x[i] = alpha * x[i] + y[i]


def norm64(a: List[Float64]) -> Float64:
    from std.math import sqrt
    return sqrt(dot64(a, a))


def narrow(src: List[Float64], mut dst: List[Real]):
    for i in range(len(src)):
        dst[i] = Real(src[i])


def widen(src: List[Real], mut dst: List[Float64]):
    for i in range(len(src)):
        dst[i] = Float64(src[i])


def zeros(n: Int) -> List[Real]:
    var v = List[Real](capacity=n)
    for _ in range(n):
        v.append(0)
    return v^


def copy_into(src: List[Real], mut dst: List[Real]):
    for i in range(len(src)):
        dst[i] = src[i]


def dot_v(a: List[Real], b: List[Real]) -> Real:
    """Accumulated in float64. The engine is float32 everywhere else, but a CG
    residual is a sum over every degree of freedom and its float32 accumulation
    error is what makes the method appear to stall on large systems -- a
    numerical artefact that looks exactly like the ill-conditioning the
    preconditioner is supposed to fix, which would make the preconditioner rows
    of the benchmark meaningless."""
    var acc = Float64(0)
    for i in range(len(a)):
        acc += Float64(a[i]) * Float64(b[i])
    return Real(acc)


def axpy(alpha: Real, x: List[Real], mut y: List[Real]):
    """In-place `y += alpha * x`."""
    for i in range(len(y)):
        y[i] += alpha * x[i]


def scale_add(alpha: Real, mut x: List[Real], y: List[Real]):
    """In-place `x = alpha * x + y`."""
    for i in range(len(x)):
        x[i] = alpha * x[i] + y[i]


def scale(alpha: Real, mut x: List[Real]):
    for i in range(len(x)):
        x[i] *= alpha


def norm2(a: List[Real]) -> Real:
    from std.math import sqrt
    return Real(sqrt(Float64(dot_v(a, a))))
