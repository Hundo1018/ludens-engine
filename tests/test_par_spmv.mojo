# tier: component
"""Parallel SpMV (ROADMAP 17.84, `numerics.sparse.ParallelCsr`).

  1. Parity: on 2D Poisson 128 x 128 (n = 16384, 8 blocks of 2048 rows) the
     parallel product equals `CsrMatrix.apply` bit for bit, with the default
     width and with 1, 2 and 3 workers, and with a block size (100) that
     does not divide n.
  2. Solver: CG on the `ParallelCsr` returns the same iterations and the
     same x, bit for bit, as CG on the plain matrix.
  3. Extreme: one block (n = 16 < block) takes the serial path; n = 1.
"""

from std.math import sin
from harness.runner import Suite
from geometry.vec import Real
from numerics.sparse import CsrMatrix, ParallelCsr
from numerics.cg import cg


def poisson(m: Int) -> CsrMatrix:
    var r = List[Int]()
    var c = List[Int]()
    var v = List[Real]()
    for i in range(m):
        for j in range(m):
            var k = i * m + j
            r.append(k)
            c.append(k)
            v.append(4.01)
            var nb: List[Int] = [k - m if i > 0 else -1, k + m if i + 1 < m else -1, k - 1 if j > 0 else -1, k + 1 if j + 1 < m else -1]
            for q in nb:
                if q >= 0:
                    r.append(k)
                    c.append(q)
                    v.append(-1)
    return CsrMatrix.from_triplets(m * m, r, c, v)


def vec(n: Int) -> List[Real]:
    var x = List[Real](capacity=n)
    for i in range(n):
        x.append(sin(Real(i) * 0.37) + 0.5)
    return x^


def same(a: List[Real], b: List[Real]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def product(var p: ParallelCsr, x: List[Real]) -> List[Real]:
    var y = List[Real](length=p.size(), fill=0)
    p.apply(x, y)
    return y^


def main() raises:
    var s = Suite("par_spmv")
    var m = 128
    var n = m * m
    var x = vec(n)
    var a = poisson(m)
    var ref_y = List[Real](length=n, fill=0)
    a.apply(x, ref_y)
    var ok = same(product(ParallelCsr(poisson(m)), x), ref_y)
    for w in range(1, 4):
        ok = ok and same(product(ParallelCsr(poisson(m), 2048, w), x), ref_y)
    s.check(ok, "parallel product == serial, default width and 1-3 workers")
    s.check(same(product(ParallelCsr(poisson(m), 100), x), ref_y), "block size 100 (not dividing n) == serial")

    var b = vec(n)
    var x1 = List[Real](length=n, fill=0)
    var x2 = List[Real](length=n, fill=0)
    var r1 = cg(a, b, x1, 1e-6, 4 * n)
    var r2 = cg(ParallelCsr(poisson(m)), b, x2, 1e-6, 4 * n)
    print("CG n", n, ": serial", r1.iters, "iterations, parallel", r2.iters)
    s.check(r1.converged and r1.iters == r2.iters and same(x1, x2), "CG on ParallelCsr == CG on CsrMatrix, bit for bit")

    var small = poisson(4)
    var xs = vec(16)
    var ys = List[Real](length=16, fill=0)
    small.apply(xs, ys)
    var one = CsrMatrix.from_triplets(1, [0], [0], [3.0])
    s.check(same(product(ParallelCsr(poisson(4)), xs), ys) and product(ParallelCsr(one^), [2.0])[0] == 6, "one block (serial path) and n = 1")
    s.finish()
