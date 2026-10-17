"""Pose-space deformation: RBF-driven corrective shapes (ROADMAP 17.65;
Lewis, Cordner & Fong 2000).

A `PoseSpaceRbf` maps a pose coordinate vector (d numbers, e.g. joint
angles in radians) to m outputs (e.g. the weights of corrective
`MorphSet` targets). It interpolates the samples exactly:

    out(x) = sum_s c_s phi(|x - x_s|),   phi(r) = exp(-(r / sigma)^2)

with the coefficients c solved once from Phi c = y (Gaussian elimination
with partial pivoting; the Gaussian kernel matrix is positive definite for
distinct samples). `solve()` raises on duplicate samples (a zero pivot) or
on sigma <= 0; `eval` before `solve` raises.

Example: elbow angle samples 0, 60, 120 degrees with corrective weight
0, 0.3, 1: the elbow at 120 degrees gets exactly 1, at 90 degrees a value
between, and the corrective `MorphSet` adds the volume back.
"""

from std.math import exp, sqrt
from .vec import Real


struct PoseSpaceRbf(Movable):
    var dims: Int
    var outs: Int
    var sigma: Real
    var xs: List[Real]  # samples, [s * dims + j]
    var ys: List[Real]  # targets, [s * outs + k]
    var coef: List[Real]  # [s * outs + k]

    def __init__(out self, dims: Int, outs: Int, sigma: Real) raises:
        if dims < 1 or outs < 1 or not (sigma > 0):
            raise Error("PoseSpaceRbf: dims >= 1, outs >= 1, sigma > 0")
        self.dims = dims
        self.outs = outs
        self.sigma = sigma
        self.xs = List[Real]()
        self.ys = List[Real]()
        self.coef = List[Real]()

    def samples(self) -> Int:
        return len(self.xs) // self.dims

    def add(mut self, x: List[Real], y: List[Real]) raises:
        if len(x) != self.dims or len(y) != self.outs:
            raise Error("PoseSpaceRbf.add: x needs dims values, y needs outs values")
        for v in x:
            self.xs.append(v)
        for v in y:
            self.ys.append(v)
        self.coef = List[Real]()

    def _phi(self, a: Int, x: List[Real], b: Int) -> Real:
        """phi between sample a (or x when a < 0) and sample b."""
        var r2 = Real(0)
        for j in range(self.dims):
            var xa = x[j] if a < 0 else self.xs[a * self.dims + j]
            var d = xa - self.xs[b * self.dims + j]
            r2 += d * d
        return exp(-r2 / (self.sigma * self.sigma))

    def solve(mut self) raises:
        var n = self.samples()
        if n == 0:
            raise Error("PoseSpaceRbf.solve: no samples")
        var w = n + self.outs
        var a = List[Float64](length=n * w, fill=0)
        var none = List[Real]()
        for r in range(n):
            for c in range(n):
                a[r * w + c] = Float64(self._phi(r, none, c))
            for k in range(self.outs):
                a[r * w + n + k] = Float64(self.ys[r * self.outs + k])
        for col in range(n):
            var piv = col
            for r in range(col + 1, n):
                if abs(a[r * w + col]) > abs(a[piv * w + col]):
                    piv = r
            if abs(a[piv * w + col]) < 1e-12:
                raise Error("PoseSpaceRbf.solve: singular system (duplicate samples?)")
            if piv != col:
                for c in range(w):
                    var t = a[col * w + c]
                    a[col * w + c] = a[piv * w + c]
                    a[piv * w + c] = t
            for r in range(n):
                if r == col:
                    continue
                var f = a[r * w + col] / a[col * w + col]
                if f == 0:
                    continue
                for c in range(col, w):
                    a[r * w + c] -= f * a[col * w + c]
        self.coef = List[Real](length=n * self.outs, fill=0)
        for r in range(n):
            for k in range(self.outs):
                self.coef[r * self.outs + k] = Real(a[r * w + n + k] / a[r * w + r])

    def eval(self, x: List[Real]) raises -> List[Real]:
        if len(self.coef) == 0:
            raise Error("PoseSpaceRbf.eval: call solve() first")
        if len(x) != self.dims:
            raise Error("PoseSpaceRbf.eval: x needs dims values")
        var out = List[Real](length=self.outs, fill=0)
        for s in range(self.samples()):
            var p = self._phi(-1, x, s)
            for k in range(self.outs):
                out[k] += self.coef[s * self.outs + k] * p
        return out^
