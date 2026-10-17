"""Sparse Cholesky and incomplete Cholesky (ROADMAP 17.84).

`SparseCholesky.factor(a)` factors a symmetric positive definite `CsrMatrix`
(both triangles stored) as P A P^T = L L^T:

  * ordering: reverse Cuthill-McKee (George & Liu 1981) per connected
    component, started from a minimum-degree node; it narrows the band, which
    bounds the fill of a mesh-like matrix (AMD is the usual stronger choice;
    the fill is reported, so the ordering can be compared);
  * symbolic: the elimination tree (Liu's algorithm with path compression)
    and each row's pattern by walking it (`ereach`, as in CSparse's up-looking
    `cs_chol`, Davis 2006), first to count the columns, then to fill them;
  * numeric: up-looking, in Float64 (Real is f32);
  * `solve(b, x)`: forward and back substitution, then the inverse ordering.
A non-positive pivot (the matrix is not SPD) makes `factor` raise.

`IncompleteCholesky` (IC(0), Meijerink & van der Vorst 1977) keeps only the
lower pattern of A, no fill; a non-positive pivot is replaced by the original
diagonal and counted in `shifted`. `pcg_ic0` is conjugate gradients with it
as the preconditioner, Float64 recurrences like `cg`, the same `CgResult`.
"""

from std.math import sqrt
from geometry.vec import Real
from .sparse import CsrMatrix, LinearOperator
from .cg import CgResult
from .vecops import zeros64, dot64, norm64, widen, narrow


def rcm_order(a: CsrMatrix) -> List[Int]:
    """New-to-old permutation: reverse Cuthill-McKee over the matrix graph."""
    var n = a.n
    var deg = List[Int](length=n, fill=0)
    for i in range(n):
        deg[i] = a.row_start[i + 1] - a.row_start[i]
    var seen = List[Bool](length=n, fill=False)
    var order = List[Int](capacity=n)
    while len(order) < n:
        # start each component at its unvisited node of least degree
        var start = -1
        for i in range(n):
            if not seen[i] and (start < 0 or deg[i] < deg[start]):
                start = i
        seen[start] = True
        var head = len(order)
        order.append(start)
        while head < len(order):
            var u = order[head]
            head += 1
            var nb = List[Int]()
            for p in range(a.row_start[u], a.row_start[u + 1]):
                var v = a.col[p]
                if not seen[v]:
                    seen[v] = True
                    nb.append(v)
            # neighbours by increasing degree (insertion sort: rows are short)
            for i in range(1, len(nb)):
                var key = nb[i]
                var j = i - 1
                while j >= 0 and (deg[nb[j]] > deg[key] or (deg[nb[j]] == deg[key] and nb[j] > key)):
                    nb[j + 1] = nb[j]
                    j -= 1
                nb[j + 1] = key
            for v in nb:
                order.append(v)
    var rev = List[Int](capacity=n)
    for i in range(n - 1, -1, -1):
        rev.append(order[i])
    return rev^


struct SparseCholesky(Movable):
    var n: Int
    var perm: List[Int]  # new -> old
    var pinv: List[Int]  # old -> new
    var parent: List[Int]  # elimination tree
    var lp: List[Int]  # column starts of L (CSC), n + 1
    var li: List[Int]  # row indices; the first entry of a column is its diagonal
    var lx: List[Float64]

    def __init__(out self):
        self.n = 0
        self.perm = List[Int]()
        self.pinv = List[Int]()
        self.parent = List[Int]()
        self.lp = List[Int]()
        self.li = List[Int]()
        self.lx = List[Float64]()

    def nnz(self) -> Int:
        return len(self.li)

    def factor(mut self, a: CsrMatrix, perm: List[Int]) raises:
        """Factor P A P^T with the given new-to-old permutation (`rcm_order`
        or the identity). Raises when a pivot is not positive."""
        var n = a.n
        if len(perm) != n:
            raise Error("SparseCholesky.factor: permutation length != n")
        self.n = n
        self.perm = perm.copy()
        self.pinv = List[Int](length=n, fill=-1)
        for k in range(n):
            if perm[k] < 0 or perm[k] >= n or self.pinv[perm[k]] >= 0:
                raise Error("SparseCholesky.factor: not a permutation")
            self.pinv[perm[k]] = k
        # permuted rows: entries (new col, value) of new row k
        var cs = List[Int](length=n + 1, fill=0)
        var ci = List[Int]()
        var cx = List[Float64]()
        for k in range(n):
            var o = perm[k]
            for p in range(a.row_start[o], a.row_start[o + 1]):
                ci.append(self.pinv[a.col[p]])
                cx.append(Float64(a.val[p]))
            cs[k + 1] = len(ci)
        # elimination tree
        self.parent = List[Int](length=n, fill=-1)
        var anc = List[Int](length=n, fill=-1)
        for k in range(n):
            for p in range(cs[k], cs[k + 1]):
                var i = ci[p]
                while i != -1 and i < k:
                    var nxt = anc[i]
                    anc[i] = k
                    if nxt == -1:
                        self.parent[i] = k
                    i = nxt
        # column counts by walking every row's pattern once
        var w = List[Int](length=n, fill=-1)
        var stack = List[Int](length=n, fill=0)
        var count = List[Int](length=n, fill=1)  # the diagonal
        for k in range(n):
            var top = _ereach(cs, ci, k, self.parent, w, stack)
            for t in range(top, n):
                count[stack[t]] += 1
        self.lp = List[Int](length=n + 1, fill=0)
        for j in range(n):
            self.lp[j + 1] = self.lp[j] + count[j]
        var total = self.lp[n]
        self.li = List[Int](length=total, fill=0)
        self.lx = List[Float64](length=total, fill=0)
        var nextp = List[Int](length=n, fill=0)
        for j in range(n):
            nextp[j] = self.lp[j] + 1  # slot 0 of each column is the diagonal
            self.li[self.lp[j]] = j
        # numeric, up-looking
        var x = List[Float64](length=n, fill=0)
        for j in range(n):
            w[j] = -1
        for k in range(n):
            var top = _ereach(cs, ci, k, self.parent, w, stack)
            for p in range(cs[k], cs[k + 1]):
                if ci[p] <= k:
                    x[ci[p]] += cx[p]
            var d = x[k]
            x[k] = 0
            for t in range(top, n):
                var i = stack[t]
                var lki = x[i] / self.lx[self.lp[i]]
                x[i] = 0
                for p in range(self.lp[i] + 1, nextp[i]):
                    x[self.li[p]] -= self.lx[p] * lki
                d -= lki * lki
                var q = nextp[i]
                nextp[i] += 1
                self.li[q] = k
                self.lx[q] = lki
            if not (d > 0):
                raise Error("SparseCholesky.factor: matrix is not positive definite (pivot " + String(k) + ")")
            self.lx[self.lp[k]] = sqrt(d)

    def solve(self, b: List[Real], mut x: List[Real]):
        """Solve A x = b with the stored factor."""
        var n = self.n
        var y = zeros64(n)
        for k in range(n):
            y[k] = Float64(b[self.perm[k]])
        for j in range(n):
            y[j] /= self.lx[self.lp[j]]
            for p in range(self.lp[j] + 1, self.lp[j + 1]):
                y[self.li[p]] -= self.lx[p] * y[j]
        for j in range(n - 1, -1, -1):
            var acc = y[j]
            for p in range(self.lp[j] + 1, self.lp[j + 1]):
                acc -= self.lx[p] * y[self.li[p]]
            y[j] = acc / self.lx[self.lp[j]]
        for k in range(n):
            x[self.perm[k]] = Real(y[k])


def _ereach(cs: List[Int], ci: List[Int], k: Int, parent: List[Int], mut w: List[Int], mut stack: List[Int]) -> Int:
    """Pattern of row k of L (excluding the diagonal) in stack[top:], in an
    order where every entry comes after the entries it depends on."""
    var n = len(parent)
    var top = n
    w[k] = k
    for p in range(cs[k], cs[k + 1]):
        var i = ci[p]
        if i > k:
            continue
        var ln = 0
        while w[i] != k:
            stack[ln] = i
            ln += 1
            w[i] = k
            i = parent[i]
        while ln > 0:
            ln -= 1
            top -= 1
            stack[top] = stack[ln]
    return top


struct IncompleteCholesky(Movable):
    """IC(0): L on the lower pattern of A, rows sorted, diagonal last."""

    var n: Int
    var rs: List[Int]
    var col: List[Int]
    var val: List[Float64]
    var shifted: Int  # pivots replaced by the original diagonal

    def __init__(out self, a: CsrMatrix):
        var n = a.n
        self.n = n
        self.rs = List[Int](length=n + 1, fill=0)
        self.col = List[Int]()
        self.val = List[Float64]()
        self.shifted = 0
        for i in range(n):
            # lower entries of row i, sorted by column (rows are short)
            var cols = List[Int]()
            var vals = List[Float64]()
            for p in range(a.row_start[i], a.row_start[i + 1]):
                if a.col[p] <= i:
                    var c = a.col[p]
                    var j = len(cols)
                    cols.append(c)
                    vals.append(Float64(a.val[p]))
                    while j > 0 and cols[j - 1] > c:
                        cols[j] = cols[j - 1]
                        vals[j] = vals[j - 1]
                        j -= 1
                    cols[j] = c
                    vals[j] = Float64(a.val[p])
            for q in range(len(cols)):
                self.col.append(cols[q])
                self.val.append(vals[q])
            self.rs[i + 1] = len(self.col)
        for i in range(n):
            var s = self.rs[i]
            var e = self.rs[i + 1]
            for q in range(s, e):
                var k = self.col[q]
                # L[i,k] -= sum over shared columns j < k of L[i,j] L[k,j]
                var acc = self.val[q]
                var pi = s
                var pk = self.rs[k]
                while pi < q and pk < self.rs[k + 1] - 1:
                    if self.col[pi] == self.col[pk]:
                        acc -= self.val[pi] * self.val[pk]
                        pi += 1
                        pk += 1
                    elif self.col[pi] < self.col[pk]:
                        pi += 1
                    else:
                        pk += 1
                if k < i:
                    var dk = self.val[self.rs[k + 1] - 1]
                    self.val[q] = acc / dk
                else:
                    if acc > 0:
                        self.val[q] = sqrt(acc)
                    else:
                        self.shifted += 1
                        self.val[q] = sqrt(abs(self.val[q])) if self.val[q] != 0 else 1

    def apply64(self, r: List[Float64], mut z: List[Float64]):
        """Apply the preconditioner: z = (L L^T)^-1 r."""
        var n = self.n
        for i in range(n):
            var acc = r[i]
            for q in range(self.rs[i], self.rs[i + 1] - 1):
                acc -= self.val[q] * z[self.col[q]]
            z[i] = acc / self.val[self.rs[i + 1] - 1]
        for i in range(n - 1, -1, -1):
            z[i] /= self.val[self.rs[i + 1] - 1]
            for q in range(self.rs[i], self.rs[i + 1] - 1):
                z[self.col[q]] -= self.val[q] * z[i]


def pcg_ic0[Op: LinearOperator](
    a: Op, ic: IncompleteCholesky, b: List[Real], mut x: List[Real], tol: Real = 1e-6, max_iters: Int = 0,
) -> CgResult:
    """Conjugate gradients preconditioned with IC(0)."""
    var n = a.size()
    var limit = max_iters if max_iters > 0 else 2 * n
    var xs = zeros64(n)
    widen(x, xs)
    var b64 = zeros64(n)
    widen(b, b64)
    var bn = norm64(b64)
    if bn == 0:
        bn = 1
    var tmp = List[Real](length=n, fill=0)
    var tmpo = List[Real](length=n, fill=0)
    var r = zeros64(n)
    narrow(xs, tmp)
    a.apply(tmp, tmpo)
    for i in range(n):
        r[i] = b64[i] - Float64(tmpo[i])
    var z = zeros64(n)
    ic.apply64(r, z)
    var p = z.copy()
    var ap = zeros64(n)
    var rz = dot64(r, z)
    var res = norm64(r) / bn
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
        res = norm64(r) / bn
        it += 1
        if res <= Float64(tol):
            break
        ic.apply64(r, z)
        var rz1 = dot64(r, z)
        var beta = rz1 / rz
        rz = rz1
        for i in range(n):
            p[i] = z[i] + beta * p[i]
    narrow(xs, x)
    return CgResult(res <= Float64(tol), stalled, it, Real(res))
