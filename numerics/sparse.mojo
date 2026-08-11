"""Compressed-sparse-row matrices, and the operator interface that lets a
solver avoid building one.

This package is the global-solve half of the engine. Everything else solves
constraints LOCALLY and iteratively — PBD projections, projected Gauss-Seidel,
Jacobi sweeps, per-vertex Newton. Those are fast, trivially parallel, and
stiffness-limited: a stiff system has to be walked to convergence one neighbour
at a time, so the step size is bounded by how far information travels per
iteration. A global linear solve removes that bound, and it is the missing piece
under implicit FEM, pressure projection for Eulerian fluids, and barrier-based
non-penetration.

`CsrMatrix` is the ordinary thing: values, column indices, row starts. It is
useful for small systems, for tests that need an explicit matrix to check
against, and for preconditioners that need to see the diagonal.

`LinearOperator` is the more important half. Implicit FEM does not want to
assemble a global stiffness matrix — it is large, it changes every step as
elements rotate, and assembling it costs more than the solve. What conjugate
gradients actually needs is not a matrix but the ability to compute `A @ x`, so
that is what the trait asks for. `physics/fem.mojo` implements it by looping
over elements and accumulating each one's contribution directly into the output,
which is the standard matrix-free formulation.

Row and column indices are `Int`; values are `Real` (float32), matching the rest
of the engine. Vectors are flat `List[Real]` — a `List[Vec3]` loses its tail
elements when passed between functions on this nightly, and a solver that hands
vectors to an operator does nothing else all day (`collision/hull.mojo` carries
the reduced probe).
"""

from geometry.vec import Real


trait LinearOperator:
    """Anything that can apply itself to a vector.

    `apply` must be linear and, for the solvers here, symmetric positive
    (semi)definite — conjugate gradients is not merely slower on a
    non-symmetric operator, it converges to the wrong thing, so this is a
    precondition and not a hint."""

    def size(self) -> Int: ...

    def apply(self, x: List[Real], mut out: List[Real]): ...

    # `diagonal` fills `out` with the operator's diagonal, for Jacobi
    # preconditioning. An operator that cannot cheaply produce it should fill
    # `out` with ones, which turns the preconditioner into the identity and
    # costs only the extra multiply.
    def diagonal(self, mut out: List[Real]): ...


struct CsrMatrix(LinearOperator, Movable, ImplicitlyDeletable):
    """Square sparse matrix in compressed sparse row form."""

    var n: Int
    var row_start: List[Int]  # n + 1 entries
    var col: List[Int]
    var val: List[Real]

    def __init__(out self, n: Int):
        self.n = n
        self.row_start = List[Int](capacity=n + 1)
        for _ in range(n + 1):
            self.row_start.append(0)
        self.col = List[Int]()
        self.val = List[Real]()

    def size(self) -> Int:
        return self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        for i in range(self.n):
            var acc = Real(0)
            for k in range(self.row_start[i], self.row_start[i + 1]):
                acc += self.val[k] * x[self.col[k]]
            out[i] = acc

    def diagonal(self, mut out: List[Real]):
        for i in range(self.n):
            var d = Real(0)
            for k in range(self.row_start[i], self.row_start[i + 1]):
                if self.col[k] == i:
                    d += self.val[k]
            out[i] = d

    @staticmethod
    def from_triplets(
        n: Int, rows: List[Int], cols: List[Int], vals: List[Real]
    ) -> Self:
        """Build from an unordered (row, col, value) list, summing duplicates.

        Summing rather than overwriting is what makes element-by-element
        assembly work: two elements sharing a node both contribute to the same
        entry, and the matrix is the sum of their contributions."""
        var m = Self(n)
        var count = List[Int](capacity=n)
        for _ in range(n):
            count.append(0)
        for k in range(len(rows)):
            count[rows[k]] += 1
        var start = List[Int](capacity=n + 1)
        start.append(0)
        for i in range(n):
            start.append(start[i] + count[i])
        var nnz = start[n]

        var col = List[Int](capacity=nnz)
        var val = List[Real](capacity=nnz)
        for _ in range(nnz):
            col.append(-1)
            val.append(0)
        var cursor = List[Int](capacity=n)
        for i in range(n):
            cursor.append(start[i])
        for k in range(len(rows)):
            var r = rows[k]
            # find an existing entry for this column in the row written so far
            var found = -1
            for q in range(start[r], cursor[r]):
                if col[q] == cols[k]:
                    found = q
                    break
            if found >= 0:
                val[found] += vals[k]
            else:
                col[cursor[r]] = cols[k]
                val[cursor[r]] = vals[k]
                cursor[r] += 1

        # compact: duplicates left holes at the end of each row
        m.row_start = List[Int](capacity=n + 1)
        m.col = List[Int](capacity=nnz)
        m.val = List[Real](capacity=nnz)
        m.row_start.append(0)
        for i in range(n):
            for q in range(start[i], cursor[i]):
                m.col.append(col[q])
                m.val.append(val[q])
            m.row_start.append(len(m.col))
        return m^

    def is_symmetric(self, tol: Real = 1e-5) -> Bool:
        """Whether A == A^T within `tol`. Not used by the solvers — they take
        symmetry as a precondition — but tests need to be able to say that the
        matrix they built actually has the property the solver assumes."""
        for i in range(self.n):
            for k in range(self.row_start[i], self.row_start[i + 1]):
                var j = self.col[k]
                var found = False
                for q in range(self.row_start[j], self.row_start[j + 1]):
                    if self.col[q] == i:
                        found = True
                        if abs(self.val[q] - self.val[k]) > tol:
                            return False
                        break
                if not found and abs(self.val[k]) > tol:
                    return False
        return True


def poisson_1d(n: Int, h: Real = 1) -> CsrMatrix:
    """The 1D Poisson operator with Dirichlet ends: tridiagonal (-1, 2, -1)/h^2.

    Kept here rather than in the test because it is the reference every part of
    this package is checked against — it is symmetric positive definite, its
    condition number is known to grow as n^2, and its solution against a
    constant right-hand side has a closed form. That combination is what makes
    it the standard first test of a CG implementation."""
    var rows = List[Int]()
    var cols = List[Int]()
    var vals = List[Real]()
    var inv = Real(1) / (h * h)
    for i in range(n):
        rows.append(i)
        cols.append(i)
        vals.append(2 * inv)
        if i > 0:
            rows.append(i)
            cols.append(i - 1)
            vals.append(-inv)
        if i < n - 1:
            rows.append(i)
            cols.append(i + 1)
            vals.append(-inv)
    return CsrMatrix.from_triplets(n, rows, cols, vals)
