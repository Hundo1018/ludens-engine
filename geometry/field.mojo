"""Coefficient fields for the generic multivector (`geometry.gmv`).

`Field` is the arithmetic a `GMV` coefficient must provide. Mojo conformance is
nominal, so stdlib `SIMD` scalars cannot adopt it retroactively — `RealF` wraps
the engine scalar for that role, and `DualReal` (promoted from
`experiments/exp_autodiff.mojo`) is the forward-mode AD coefficient: compute in
`GMV[..., DualReal]` and every result carries d/dθ in its ε-lane. A reverse-mode
tape node needs exactly this same trait — that is the "foundation" part.
"""

from std.math import sqrt, cos, sin
from .vec import WorldType, Real


trait Field(Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    def __add__(self, o: Self) -> Self: ...
    def __sub__(self, o: Self) -> Self: ...
    def __mul__(self, o: Self) -> Self: ...

    @staticmethod
    def zero() -> Self: ...

    @staticmethod
    def const(v: Real) -> Self: ...

    def value(self) -> Real: ...


@fieldwise_init
struct RealF(Field):
    """The engine scalar as a `Field` (thin wrapper; nominal conformance)."""

    var v: Real

    def __add__(self, o: Self) -> Self:
        return Self(self.v + o.v)

    def __sub__(self, o: Self) -> Self:
        return Self(self.v - o.v)

    def __mul__(self, o: Self) -> Self:
        return Self(self.v * o.v)

    @staticmethod
    def zero() -> Self:
        return Self(0)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v)

    def value(self) -> Real:
        return self.v


@fieldwise_init
struct DualReal(Field):
    """Dual number a + b·ε (ε² = 0) — forward-mode AD scalar."""

    var a: Real  # value
    var b: Real  # derivative w.r.t. the seeded parameter

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, 0)

    @staticmethod
    def seed(v: Real) -> Self:
        """The differentiation variable: d/dθ θ = 1."""
        return Self(v, 1)

    def __add__(self, o: Self) -> Self:
        return Self(self.a + o.a, self.b + o.b)

    def __sub__(self, o: Self) -> Self:
        return Self(self.a - o.a, self.b - o.b)

    def __mul__(self, o: Self) -> Self:
        return Self(self.a * o.a, self.a * o.b + self.b * o.a)

    @staticmethod
    def zero() -> Self:
        return Self(0, 0)

    def value(self) -> Real:
        return self.a


@fieldwise_init
struct DualBatch(Field):
    """Forward-mode AD with FOUR derivative directions in SIMD lanes — one
    rollout yields the gradient w.r.t. four parameters at once (the
    "SIMD lane = derivative direction" batch scheme from ROADMAP 3.1)."""

    var a: Real  # value
    var b: SIMD[WorldType, 4]  # derivative lanes

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, SIMD[WorldType, 4](0))

    @staticmethod
    def seed(v: Real, lane: Int) -> Self:
        """The differentiation variable for direction `lane`."""
        var b = SIMD[WorldType, 4](0)
        b[lane] = 1
        return Self(v, b)

    def __add__(self, o: Self) -> Self:
        return Self(self.a + o.a, self.b + o.b)

    def __sub__(self, o: Self) -> Self:
        return Self(self.a - o.a, self.b - o.b)

    def __mul__(self, o: Self) -> Self:
        return Self(self.a * o.a, self.b * o.a + o.b * self.a)

    @staticmethod
    def zero() -> Self:
        return Self(0, SIMD[WorldType, 4](0))

    def value(self) -> Real:
        return self.a


def dcos(x: DualReal) -> DualReal:
    return DualReal(cos(x.a), -sin(x.a) * x.b)


def dsin(x: DualReal) -> DualReal:
    return DualReal(sin(x.a), cos(x.a) * x.b)
