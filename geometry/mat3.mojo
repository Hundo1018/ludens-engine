"""Linear 3x3 matrix: the plain-algebra counterpart to `mat.mojo`'s affine `Mat3`.

`geometry/mat.mojo`'s `Mat3` (= `Mat[3]`) is documented and used elsewhere as a
2-D affine transform (implicit `[0, 0, 1]` last row) and stays exactly that.
FEM's deformation gradient, MPM's affine velocity field, and the articulated
chain solver's spatial-inertia rows are genuine 3x3 LINEAR algebra with no
such implicit row — `Mat3x3` is their shared, self-documenting home, replacing
the private per-module `_det3`/`_Rows3`/`_skew` copies this used to force
(audit F8).

Storage is row-major flat `Array[Real, 9]`, matching `mat.mojo`'s convention,
so `get`/`set`/`mul`(`__mul__`)/`transpose` are the same formulas `Mat[n]`
already uses (bit-identical to the `Mat3`-typed code in `physics/fem.mojo` and
`physics/mpm.mojo` this replaces). `matvec` is built from `geometry.vec.dot`
specifically so it stays bit-identical to the `dot(row, v)` calls it replaces
in `physics/chain.mojo`.
"""

from .vec import Real, Vec3, dot


struct Mat3x3(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var m: Array[Real, 9]

    def __init__(out self):
        self.m = Array[Real, 9](fill=Real(0))

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` stopped being `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one can no longer have its copy
        constructor synthesised."""
        self.m = copy.m.copy()

    @staticmethod
    def zero() -> Self:
        return Self()

    @staticmethod
    def identity() -> Self:
        var r = Self()
        comptime for i in range(3):
            r.m[i * 3 + i] = Real(1)
        return r^

    @staticmethod
    def from_rows(r0: Vec3, r1: Vec3, r2: Vec3) -> Self:
        var r = Self()
        comptime for j in range(3):
            r.m[j] = r0[j]
            r.m[3 + j] = r1[j]
            r.m[6 + j] = r2[j]
        return r^

    @staticmethod
    def from_cols(c0: Vec3, c1: Vec3, c2: Vec3) -> Self:
        var r = Self()
        comptime for i in range(3):
            r.m[i * 3] = c0[i]
            r.m[i * 3 + 1] = c1[i]
            r.m[i * 3 + 2] = c2[i]
        return r^

    @staticmethod
    def skew(v: Vec3) -> Self:
        """Skew-symmetric cross-product matrix `[v]x`, so that
        `skew(v).matvec(u) == cross(v, u)` for every `u`."""
        return Self.from_rows(
            Vec3(0, -v[2], v[1], 0),
            Vec3(v[2], 0, -v[0], 0),
            Vec3(-v[1], v[0], 0, 0),
        )

    def get(self, row: Int, col: Int) -> Real:
        return self.m[row * 3 + col]

    def set(mut self, row: Int, col: Int, v: Real):
        self.m[row * 3 + col] = v

    def row(self, i: Int) -> Vec3:
        return Vec3(self.m[i * 3], self.m[i * 3 + 1], self.m[i * 3 + 2], 0)

    def matvec(self, v: Vec3) -> Vec3:
        return Vec3(
            dot(self.row(0), v), dot(self.row(1), v), dot(self.row(2), v), 0
        )

    def mul(self, o: Self) -> Self:
        var r = Self()
        comptime for i in range(3):
            comptime for j in range(3):
                var s = Real(0)
                comptime for k in range(3):
                    s += self.m[i * 3 + k] * o.m[k * 3 + j]
                r.m[i * 3 + j] = s
        return r^

    def __mul__(self, o: Self) -> Self:
        return self.mul(o)

    def transpose(self) -> Self:
        var r = Self()
        comptime for i in range(3):
            comptime for j in range(3):
                r.m[j * 3 + i] = self.m[i * 3 + j]
        return r^

    def det(self) -> Real:
        return (
            self.m[0] * (self.m[4] * self.m[8] - self.m[5] * self.m[7])
            - self.m[1] * (self.m[3] * self.m[8] - self.m[5] * self.m[6])
            + self.m[2] * (self.m[3] * self.m[7] - self.m[4] * self.m[6])
        )
