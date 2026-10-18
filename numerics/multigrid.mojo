"""Geometric multigrid for the periodic 2-D Poisson problem, as a CG
preconditioner (ROADMAP 17.84).

`MacFluid2.project` solves -lap p = rhs on an n x n periodic cell grid every
step. Jacobi-preconditioned CG needs O(n) iterations there (the Laplacian's
condition number grows as n^2): measured in `bench_grid_fluid`. One
multigrid V-cycle reduces every error frequency by a roughly constant
factor, so CG preconditioned with it (MGPCG, McAdams, Sifakis & Teran 2010)
needs a near-constant number of iterations whatever n is.

The hierarchy halves n per level down to 2 x 2 (n must be a power of two,
>= 2). Level l's operator is the 5-point stencil rediscretised at spacing
2^l: (4 x_c - sum of 4 neighbours) / 4^l in the finest level's dx^2 = 1
units. Restriction averages the 4 children of a coarse cell; prolongation
copies a coarse value to its 4 children. The smoother is red-black
Gauss-Seidel, `sweeps` sweeps red then black before the coarse correction
and black then red after it, so the V-cycle is a symmetric operator, as CG
requires of a preconditioner. The coarsest level gets 8 sweeps.

The periodic Laplacian is singular (constants are its null space): every
level's correction has its mean removed, and so does the V-cycle's output,
so the preconditioner never adds a constant that CG would then have to
carry. All arithmetic is Float64 like the Krylov recurrences.
"""

from geometry.vec import Real
from .sparse import LinearOperator
from .cg import CgResult
from .vecops import zeros64, dot64, norm64, widen, narrow


struct PeriodicPoissonMG(Movable):
    var n: Int
    var levels: Int
    var sweeps: Int
    var sizes: List[Int]
    var x: List[List[Float64]]  # per-level correction
    var b: List[List[Float64]]  # per-level right-hand side
    var r: List[List[Float64]]  # per-level residual scratch

    def __init__(out self, n: Int, sweeps: Int = 2) raises:
        if n < 2 or (n & (n - 1)) != 0:
            raise Error("PeriodicPoissonMG: n must be a power of two >= 2")
        self.n = n
        self.sweeps = max(1, sweeps)
        self.sizes = List[Int]()
        self.x = List[List[Float64]]()
        self.b = List[List[Float64]]()
        self.r = List[List[Float64]]()
        var m = n
        while True:
            self.sizes.append(m)
            self.x.append(zeros64(m * m))
            self.b.append(zeros64(m * m))
            self.r.append(zeros64(m * m))
            if m == 2:
                break
            m //= 2
        self.levels = len(self.sizes)

    def _smooth(mut self, l: Int, first_parity: Int):
        """One red-black sweep, parity `first_parity` first."""
        var m = self.sizes[l]
        for half in range(2):
            var par = (first_parity + half) % 2
            for j in range(m):
                var jm = (j + m - 1) % m
                var jp = (j + 1) % m
                for i in range((j + par) % 2, m, 2):
                    var im = (i + m - 1) % m
                    var ip = (i + 1) % m
                    # (4 x - sum nb) s = b, s = 4^-l  =>  x = (b / s + sum nb) / 4
                    var nb = self.x[l][j * m + im] + self.x[l][j * m + ip] + self.x[l][jm * m + i] + self.x[l][jp * m + i]
                    self.x[l][j * m + i] = (self.b[l][j * m + i] * Float64(1 << (2 * l)) + nb) * 0.25

    def _remove_mean(mut self, l: Int):
        var m = self.sizes[l]
        var s = Float64(0)
        for k in range(m * m):
            s += self.x[l][k]
        s /= Float64(m * m)
        for k in range(m * m):
            self.x[l][k] -= s

    def _vcycle(mut self, l: Int):
        var m = self.sizes[l]
        for k in range(m * m):
            self.x[l][k] = 0
        if l == self.levels - 1:
            for _ in range(8):
                self._smooth(l, 0)
            self._remove_mean(l)
            return
        for _ in range(self.sweeps):
            self._smooth(l, 0)
        # residual, restricted by averaging
        var s = Float64(1) / Float64(1 << (2 * l))
        for j in range(m):
            var jm = (j + m - 1) % m
            var jp = (j + 1) % m
            for i in range(m):
                var im = (i + m - 1) % m
                var ip = (i + 1) % m
                var ax = (4 * self.x[l][j * m + i] - self.x[l][j * m + im] - self.x[l][j * m + ip] - self.x[l][jm * m + i] - self.x[l][jp * m + i]) * s
                self.r[l][j * m + i] = self.b[l][j * m + i] - ax
        var mc = m // 2
        for j in range(mc):
            for i in range(mc):
                var a = self.r[l][(2 * j) * m + 2 * i] + self.r[l][(2 * j) * m + 2 * i + 1]
                a += self.r[l][(2 * j + 1) * m + 2 * i] + self.r[l][(2 * j + 1) * m + 2 * i + 1]
                self.b[l + 1][j * mc + i] = 0.25 * a
        self._vcycle(l + 1)
        for j in range(m):
            for i in range(m):
                self.x[l][j * m + i] += self.x[l + 1][(j // 2) * mc + i // 2]
        for _ in range(self.sweeps):
            self._smooth(l, 1)
        self._remove_mean(l)

    def apply64(mut self, r: List[Float64], mut z: List[Float64]):
        """Apply one V-cycle to r: z approximates A^-1 r."""
        for k in range(self.n * self.n):
            self.b[0][k] = r[k]
        self._vcycle(0)
        for k in range(self.n * self.n):
            z[k] = self.x[0][k]


def pcg_mg[Op: LinearOperator](
    a: Op, mut mg: PeriodicPoissonMG, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0,
) -> CgResult:
    """CG preconditioned with one V-cycle per iteration. `a` must be the
    operator `mg` approximates (-lap, periodic, dx^2 = 1) and b mean-free.
    Same reporting as `cg`: relative residual ||b - A x|| / ||b|| in the
    Float64 recurrence."""
    var n = a.size()
    var limit = max_iters if max_iters > 0 else n
    var b64 = zeros64(n)
    widen(b, b64)
    var bn = norm64(b64)
    if bn == 0:
        for i in range(n):
            x[i] = 0
        return CgResult(True, False, 0, 0)
    var xs = zeros64(n)
    widen(x, xs)
    var tmp = List[Real](length=n, fill=0)
    var tmpo = List[Real](length=n, fill=0)
    a.apply(x, tmpo)
    var r = zeros64(n)
    for i in range(n):
        r[i] = b64[i] - Float64(tmpo[i])
    var res = norm64(r) / bn
    if res <= Float64(tol):
        return CgResult(True, False, 0, Real(res))
    var z = zeros64(n)
    mg.apply64(r, z)
    var p = z.copy()
    var ap = zeros64(n)
    var rz = dot64(r, z)
    var it = 0
    var stalled = False
    while it < limit and res > Float64(tol):
        narrow(p, tmp)
        a.apply(tmp, tmpo)
        for i in range(n):
            ap[i] = Float64(tmpo[i])
        var pap = dot64(p, ap)
        if not (pap > 0):
            stalled = True
            break
        var alpha = rz / pap
        for i in range(n):
            xs[i] += alpha * p[i]
            r[i] -= alpha * ap[i]
        it += 1
        res = norm64(r) / bn
        if res <= Float64(tol):
            break
        mg.apply64(r, z)
        var rz2 = dot64(r, z)
        var beta = rz2 / rz
        rz = rz2
        for i in range(n):
            p[i] = z[i] + beta * p[i]
    narrow(xs, x)
    return CgResult(res <= Float64(tol), stalled, it, Real(res))
