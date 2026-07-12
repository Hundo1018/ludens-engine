"""Signature-generic Clifford (geometric) algebra: `Multivector[p, q, r]`.

One implementation covers every algebra the engine needs — 2D PGA Cl(2,0,1),
3D PGA Cl(3,0,1), CGA Cl(4,1,0) — by comptime signature: `p` basis vectors
square to +1, then `q` to -1, then `r` to 0 (degenerate). A basis blade is a
bitmask over basis vectors (bit i = e_i present); the geometric product is
generated at compile time (canonical-reorder swap sign × metric of contracted
vectors), so every product is fully unrolled straight-line FMA code — no loops,
no calls, no tables at runtime (verified via --emit asm).

`__mul__` is the geometric product (mirroring `Quat.__mul__`); `wedge` is the
outer product, `lcont` the left contraction. The dual uses the right complement
(`e_A ∧ rc(e_A) = I`), which stays well-defined under PGA's degenerate metric
where multiplying by the pseudoscalar inverse would not be.
"""

from .vec import Real


# --- comptime blade arithmetic (evaluated during product generation) ---


def _grade(a: Int) -> Int:
    """Number of basis vectors in blade `a` (popcount)."""
    var x = a
    var n = 0
    while x != 0:
        n += 1
        x &= x - 1
    return n


def _swap_sign(a: Int, b: Int) -> Int:
    """Canonical reorder sign of e_A e_B (parity of transpositions to sort)."""
    var x = a >> 1
    var total = 0
    while x != 0:
        var y = x & b
        while y != 0:
            total += 1
            y &= y - 1
        x >>= 1
    return 1 if (total & 1) == 0 else -1


def _metric_sign(common: Int, p: Int, q: Int, dim: Int) -> Int:
    """Product of squares of the contracted (shared) basis vectors."""
    var s = 1
    for i in range(dim):
        if (common & (1 << i)) != 0:
            if i < p:
                pass  # e_i^2 = +1
            elif i < p + q:
                s = -s  # e_i^2 = -1
            else:
                return 0  # e_i^2 = 0 (degenerate)
    return s


def _gp_sign(a: Int, b: Int, p: Int, q: Int, dim: Int) -> Int:
    """Sign of e_A e_B in the geometric product (0 if killed by the metric)."""
    var m = _metric_sign(a & b, p, q, dim)
    if m == 0:
        return 0
    return m * _swap_sign(a, b)


def _reverse_sign(a: Int) -> Int:
    """Sign of the reverse of a grade-k blade: (-1)^(k(k-1)/2)."""
    var k = _grade(a)
    return 1 if ((k * (k - 1)) // 2) & 1 == 0 else -1


def _involute_sign(a: Int) -> Int:
    """Grade involution sign: (-1)^k."""
    return 1 if _grade(a) & 1 == 0 else -1


struct Multivector[p: Int, q: Int, r: Int](
    Copyable, ImplicitlyCopyable, Movable, Defaultable, ImplicitlyDeletable
):
    comptime DIM: Int = Self.p + Self.q + Self.r
    comptime BLADES: Int = 1 << Self.DIM
    comptime PSS: Int = Self.BLADES - 1  # pseudoscalar blade mask

    var c: InlineArray[Real, Self.BLADES]  # coefficient per basis blade

    def __init__(out self):
        self.c = InlineArray[Real, Self.BLADES](fill=0)

    @staticmethod
    def scalar(w: Real) -> Self:
        var out = Self()
        out.c[0] = w
        return out^

    @staticmethod
    def basis(mask: Int, w: Real = 1) -> Self:
        """Blade `w * e_mask` (bit i of `mask` = basis vector e_i present)."""
        var out = Self()
        out.c[mask] = w
        return out^

    # --- linear ops ---
    @always_inline
    def __add__(self, o: Self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = self.c[i] + o.c[i]
        return out^

    @always_inline
    def __sub__(self, o: Self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = self.c[i] - o.c[i]
        return out^

    @always_inline
    def scaled(self, s: Real) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = self.c[i] * s
        return out^

    # --- products (comptime-unrolled) ---
    @always_inline
    def __mul__(self, o: Self) -> Self:
        """Geometric product."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime for j in range(Self.BLADES):
                comptime s = _gp_sign(i, j, Self.p, Self.q, Self.DIM)
                comptime if s != 0:
                    out.c[i ^ j] = out.c[i ^ j] + Real(s) * self.c[i] * o.c[j]
        return out^

    @always_inline
    def wedge(self, o: Self) -> Self:
        """Outer product (only disjoint blades survive; no metric)."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime for j in range(Self.BLADES):
                comptime if (i & j) == 0:
                    comptime s = _swap_sign(i, j)
                    out.c[i | j] = out.c[i | j] + Real(s) * self.c[i] * o.c[j]
        return out^

    @always_inline
    def lcont(self, o: Self) -> Self:
        """Left contraction: e_A ⌋ e_B — geometric-product terms with A ⊆ B."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime for j in range(Self.BLADES):
                comptime if (i & ~j) == 0:
                    comptime s = _gp_sign(i, j, Self.p, Self.q, Self.DIM)
                    comptime if s != 0:
                        out.c[i ^ j] = out.c[i ^ j] + Real(s) * self.c[i] * o.c[j]
        return out^

    # --- involutions / projections ---
    @always_inline
    def reverse(self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = Real(_reverse_sign(i)) * self.c[i]
        return out^

    @always_inline
    def involute(self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = Real(_involute_sign(i)) * self.c[i]
        return out^

    @always_inline
    def grade(self, k: Int) -> Self:
        """Grade-k projection."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime g = _grade(i)
            if g == k:
                out.c[i] = self.c[i]
        return out^

    @always_inline
    def right_complement(self) -> Self:
        """Right complement `e_A ∧ rc(e_A) = I` — the PGA dual (degenerate-safe)."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime comp = Self.PSS ^ i
            comptime s = _swap_sign(i, comp)
            out.c[comp] = Real(s) * self.c[i]
        return out^

    # --- scalar-valued helpers ---
    @always_inline
    def scalar_part(self) -> Real:
        return self.c[0]

    @always_inline
    def norm_sq(self) -> Real:
        """<reverse(a) a>_0 — may be negative or zero in mixed/degenerate metrics."""
        var s = Real(0)
        comptime for i in range(Self.BLADES):
            comptime sg = _gp_sign(i, i, Self.p, Self.q, Self.DIM)
            comptime if sg != 0:
                s += Real(sg * _reverse_sign(i)) * self.c[i] * self.c[i]
        return s

    def approx_eq(self, o: Self, tol: Real = 1e-4) -> Bool:
        comptime for i in range(Self.BLADES):
            if abs(self.c[i] - o.c[i]) > tol:
                return False
        return True


# --- the engine's algebras ---
comptime PGA2 = Multivector[2, 0, 1]  # plane-based 2D: e1,e2 (+1), e0 (0)
comptime PGA3 = Multivector[3, 0, 1]  # plane-based 3D: e1..e3 (+1), e0 (0)
comptime CGA3 = Multivector[4, 1, 0]  # conformal 3D: e1..e4 (+1), e5 (-1)
