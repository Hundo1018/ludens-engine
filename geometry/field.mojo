"""Coefficient fields for the generic multivector (`geometry.gmv`).

`Field` is the arithmetic a `GMV` coefficient must provide. Mojo conformance is
nominal, so stdlib `SIMD` scalars cannot adopt it retroactively — `RealF` wraps
the engine scalar for that role, and `DualReal` (promoted from
`experiments/exp_autodiff.mojo`) is the forward-mode AD coefficient: compute in
`GMV[..., DualReal]` and every result carries d/dθ in its ε-lane.

`RevReal` + `Tape` are the REVERSE-mode members (ROADMAP 4.2): every operation
touching a seeded value records (operand indices, partial derivatives) on the
tape; one backward sweep (`Tape.grad`) then yields the gradient w.r.t. ALL
seeded inputs at once — the direction count is no longer capped by SIMD lanes
(`DualBatch`'s 4). The Field trait's static constructors (`const`/`zero`) have
no tape to talk to, so constants live OFF the tape (idx = -1, null pointer):
constant⊕constant stays off-tape, and any mixed operation borrows the tape
pointer from its taped operand. Adjoints of constants are discarded — correct,
since nothing differentiates w.r.t. a constant.
"""

from std.math import sqrt, cos, sin
from std.memory import UnsafePointer, alloc
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


@fieldwise_init
struct TapeNode(Copyable, ImplicitlyCopyable, Movable):
    """One recorded operation: operand node indices (-1 = off-tape constant)
    and the partial derivative of this node w.r.t. each operand."""

    var l: Int
    var r: Int
    var dl: Real
    var dr: Real


struct Tape(Movable, ImplicitlyDeletable):
    """Append-only operation record for reverse-mode AD. Declare one on the
    stack, hand `UnsafePointer(to=tape)` to `RevReal.seed`, run the
    computation, then `grad(output.idx)` sweeps backwards once and returns
    the adjoint of every node — read the inputs' entries for the gradient."""

    var nodes: List[TapeNode]

    def __init__(out self):
        self.nodes = List[TapeNode]()

    def push(mut self, l: Int, r: Int, dl: Real, dr: Real) -> Int:
        self.nodes.append(TapeNode(l, r, dl, dr))
        return len(self.nodes) - 1

    def input(mut self) -> Int:
        return self.push(-1, -1, 0, 0)

    def grad(self, out_idx: Int) -> List[Real]:
        """Adjoint of every node w.r.t. node `out_idx` (one backward sweep)."""
        var adj = List[Real]()
        for _ in range(len(self.nodes)):
            adj.append(0)
        if out_idx >= 0 and out_idx < len(self.nodes):
            adj[out_idx] = 1
        var k = len(self.nodes) - 1
        while k >= 0:
            var a = adj[k]
            if a != 0:
                var nd = self.nodes[k]
                if nd.l >= 0:
                    adj[nd.l] += nd.dl * a
                if nd.r >= 0:
                    adj[nd.r] += nd.dr * a
            k -= 1
        return adj^


# UnsafePointer is non-nullable in this nightly, and a stack address carries
# its own origin — the alloc-derived alias (the ecs backends' Slot idiom) plus
# Optional models "constant, no tape".
comptime TapePtr = type_of(alloc[Tape](1))


@fieldwise_init
struct RevReal(Field):
    """Reverse-mode AD scalar: primal value + tape node index. See the module
    docstring for the off-tape constant scheme."""

    var v: Real
    var idx: Int
    var tape: Optional[TapePtr]

    @staticmethod
    def seed(t: TapePtr, v: Real) -> Self:
        """A differentiation input: registers a tape node whose adjoint is
        this input's gradient entry after `Tape.grad`."""
        return Self(v, t[].input(), t)

    def _t(self, o: Self) -> TapePtr:
        return self.tape.value() if self.idx >= 0 else o.tape.value()

    def __add__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v + o.v, -1, None)
        var t = self._t(o)
        return Self(self.v + o.v, t[].push(self.idx, o.idx, 1, 1), t)

    def __sub__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v - o.v, -1, None)
        var t = self._t(o)
        return Self(self.v - o.v, t[].push(self.idx, o.idx, 1, -1), t)

    def __mul__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v * o.v, -1, None)
        var t = self._t(o)
        return Self(
            self.v * o.v, t[].push(self.idx, o.idx, o.v, self.v), t
        )

    @staticmethod
    def zero() -> Self:
        return Self(0, -1, None)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, -1, None)

    def value(self) -> Real:
        return self.v


def rev_seed(mut t: Tape, v: Real) -> RevReal:
    """Seed a differentiation input on a stack-declared tape (wraps the
    address-roundtrip conversion to the alloc-typed pointer)."""
    return RevReal.seed(
        TapePtr(unsafe_from_address=Int(UnsafePointer(to=t))), v
    )
