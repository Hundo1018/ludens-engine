"""GMV: the signature-generic multivector, generic over the coefficient field.

`Multivector[p,q,r]` is specialized to the engine scalar for speed; `GMV[p,q,r,
F: Field]` is the same algebra with the coefficient type as a parameter — the
foundation for automatic differentiation (`DualReal` coefficients push
derivatives through every geometric product) and, later, reverse-mode tape
nodes. The comptime blade tables (`_gp_sign`, `_swap_sign`, `_reverse_sign`)
are shared with `Multivector`, so both stay sign-identical by construction.
"""

from .field import Field
from .multivector import _gp_sign, _swap_sign, _reverse_sign


struct GMV[p: Int, q: Int, r: Int, F: Field](
    Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable
):
    comptime DIM: Int = Self.p + Self.q + Self.r
    comptime BLADES: Int = 1 << Self.DIM

    var c: InlineArray[Self.F, Self.BLADES]

    def __init__(out self):
        self.c = InlineArray[Self.F, Self.BLADES](fill=Self.F.zero())

    @staticmethod
    def basis(mask: Int, w: Self.F) -> Self:
        var out = Self()
        out.c[mask] = w
        return out^

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
    def __mul__(self, o: Self) -> Self:
        """Geometric product — same comptime sign table as `Multivector`."""
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime for j in range(Self.BLADES):
                comptime s = _gp_sign(i, j, Self.p, Self.q, Self.DIM)
                comptime if s > 0:
                    out.c[i ^ j] = out.c[i ^ j] + self.c[i] * o.c[j]
                comptime if s < 0:
                    out.c[i ^ j] = out.c[i ^ j] - self.c[i] * o.c[j]
        return out^

    @always_inline
    def wedge(self, o: Self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime for j in range(Self.BLADES):
                comptime if (i & j) == 0:
                    comptime s = _swap_sign(i, j)
                    comptime if s > 0:
                        out.c[i | j] = out.c[i | j] + self.c[i] * o.c[j]
                    comptime if s < 0:
                        out.c[i | j] = out.c[i | j] - self.c[i] * o.c[j]
        return out^

    @always_inline
    def reverse(self) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            comptime if _reverse_sign(i) > 0:
                out.c[i] = self.c[i]
            comptime if _reverse_sign(i) < 0:
                out.c[i] = Self.F.zero() - self.c[i]
        return out^

    @always_inline
    def scaled(self, s: Self.F) -> Self:
        var out = Self()
        comptime for i in range(Self.BLADES):
            out.c[i] = self.c[i] * s
        return out^
