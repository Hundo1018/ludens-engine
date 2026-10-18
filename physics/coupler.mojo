"""Partitioned coupling of two solvers: schedule, substeps, conservation
check (ROADMAP 17.61).

A `CoupledPart` is any solver that meets a partner across an interface:

  * `send()`: its interface state now (positions, temperatures, ...);
  * `recv(data)`: the partner's interface state it should use in its next
    `advance`;
  * `advance(dt)`: step by dt seconds;
  * `impulse()`: what crossed the interface into it during the last
    `advance` (momentum, heat, ...), same layout for both parts, so the
    two sum to zero when the exchange conserves it;
  * `save()` / `restore()`: one checkpoint, for the iterated scheme;
  * `write_state` / `read_state`: a snapshot through `state_io` (the
    part's evolving state and the interface data it last received), so
    `Coupler.write_state` can snapshot the coupled pair and a restored
    pair continues bit for bit (`test_coupler`, `test_cloth_air_parts`).

`Coupler[A, B]` steps A with dt and B with `ratio` substeps of dt / ratio
(each solver at its own stable step). Schemes:

  * `EXPLICIT`: A gets B's state at the start, advances; every B substep
    gets A's end-of-step state (Gauss-Seidel staggering).
  * `INTERP`: as `EXPLICIT`, but B substep k gets A's state interpolated
    linearly between start and end at (k + 1) / ratio. With ratio 1 it is
    `EXPLICIT` exactly.
  * `ITERATED`: repeat the step from the checkpoint, feeding A the
    midpoint of B's start and end-of-step states, Aitken-relaxed
    (Irons-Tuck), until that midpoint changes less than `tol` (relative)
    or `max_iters` passes. (Feeding the end state instead made the energy
    error 5x larger on the spring test in `tests/test_coupler.mojo`.)

After each step `imbalance` is |sum of A's and B's impulses| (2-norm)
and `max_imbalance` its running maximum: the conservation error of the
partitioned exchange, per step. Interface data that is not finite is
not passed on: the receiver keeps the last finite data it got, the
counter `COUPLING_REJECTED` counts the rejections, and the sender's own
solver isolates its failure as it would uncoupled.
"""

from std.math import isfinite, sqrt
from geometry.vec import Real
from diag.counters import Counters, COUPLING_REJECTED
from .state_io import StateWriter, StateReader, f64_bits, f64_from_bits

comptime EXPLICIT = 0
comptime INTERP = 1
comptime ITERATED = 2


trait CoupledPart(Movable, Deinitable):
    def advance(mut self, dt: Real) raises: ...
    def send(self) -> List[Real]: ...
    def recv(mut self, data: List[Real]): ...
    def impulse(self) -> List[Real]: ...
    def save(mut self): ...
    def restore(mut self): ...
    def write_state[W: StateWriter](self, mut w: W): ...
    def read_state[R: StateReader](mut self, mut r: R) raises: ...


def _finite(d: List[Real]) -> Bool:
    for x in d:
        if not isfinite(x):
            return False
    return True


def write_reals[W: StateWriter](mut w: W, d: List[Real]):
    w.wi(len(d))
    for x in d:
        w.wf(x)


def read_reals[R: StateReader](mut r: R) raises -> List[Real]:
    var n = r.ri()
    if n < 0 or n > (1 << 40):
        raise Error("read_reals: bad length")
    var d = List[Real](capacity=n)
    for _ in range(n):
        d.append(r.rf())
    return d^


def _norm(a: List[Real]) -> Real:
    var s = Real(0)
    for x in a:
        s += x * x
    return sqrt(s)


struct Coupler[A: CoupledPart, B: CoupledPart](Movable):
    var a: Self.A
    var b: Self.B
    var ratio: Int
    var scheme: Int
    var max_iters: Int
    var tol: Real
    var imbalance: Real
    var max_imbalance: Real
    var iterations: Int  # passes used by the last ITERATED step
    var _last_a: List[Real]  # last finite interface data, per sender
    var _last_b: List[Real]

    def __init__(out self, var a: Self.A, var b: Self.B, ratio: Int = 1, scheme: Int = EXPLICIT, max_iters: Int = 20, tol: Real = 1e-6) raises:
        if ratio < 1:
            raise Error("Coupler: ratio must be >= 1")
        if scheme < EXPLICIT or scheme > ITERATED:
            raise Error("Coupler: unknown scheme")
        if max_iters < 1 or not (tol > 0):
            raise Error("Coupler: max_iters >= 1 and tol > 0 required")
        self._last_a = a.send()
        self._last_b = b.send()
        self.a = a^
        self.b = b^
        self.ratio = ratio
        self.scheme = scheme
        self.max_iters = max_iters
        self.tol = tol
        self.imbalance = 0
        self.max_imbalance = 0
        self.iterations = 0

    def _take_a(mut self, mut counters: Counters) -> List[Real]:
        var d = self.a.send()
        if _finite(d) and len(d) == len(self._last_a):
            self._last_a = d.copy()
        else:
            counters.incr(COUPLING_REJECTED)
        return self._last_a.copy()

    def _take_b(mut self, mut counters: Counters) -> List[Real]:
        var d = self.b.send()
        if _finite(d) and len(d) == len(self._last_b):
            self._last_b = d.copy()
        else:
            counters.incr(COUPLING_REJECTED)
        return self._last_b.copy()

    def _pass(mut self, xb_in: List[Real], xa0: List[Real], dt: Real, mut counters: Counters) raises -> List[Real]:
        """A with B's data `xb_in`, then B's substeps; returns the summed
        interface impulse (A's + B's)."""
        self.a.recv(xb_in)
        self.a.advance(dt)
        var total = self.a.impulse()
        var xa1 = self._take_a(counters)
        var h = dt / Real(self.ratio)
        for k in range(self.ratio):
            if self.scheme == EXPLICIT:
                self.b.recv(xa1)
            else:
                var s = Real(k + 1) / Real(self.ratio)
                var x = List[Real](length=len(xa1), fill=0)
                for i in range(len(xa1)):
                    x[i] = xa0[i] + (xa1[i] - xa0[i]) * s
                self.b.recv(x)
            self.b.advance(h)
            var ib = self.b.impulse()
            for i in range(min(len(total), len(ib))):
                total[i] += ib[i]
        return total^

    def step(mut self, dt: Real, mut counters: Counters) raises:
        var xa0 = self._take_a(counters)
        var xb0 = self._take_b(counters)
        var total: List[Real]
        if self.scheme != ITERATED:
            total = self._pass(xb0, xa0, dt, counters)
            self.iterations = 1
        else:
            self.a.save()
            self.b.save()
            var guess = xb0.copy()
            var r_prev = List[Real]()
            var omega = Real(0.5)
            total = self._pass(guess, xa0, dt, counters)
            var it = 1
            while True:
                var xb1 = self._take_b(counters)
                var r = List[Real](length=len(xb1), fill=0)
                for i in range(len(xb1)):
                    r[i] = 0.5 * (xb0[i] + xb1[i]) - guess[i]
                if _norm(r) <= self.tol * (_norm(xb1) + 1) or it >= self.max_iters:
                    break
                if len(r_prev) == len(r):
                    # Aitken: omega <- -omega (r_prev . (r - r_prev)) / |r - r_prev|^2
                    var num = Real(0)
                    var den = Real(0)
                    for i in range(len(r)):
                        var d = r[i] - r_prev[i]
                        num += r_prev[i] * d
                        den += d * d
                    if den > 0:
                        omega = -omega * num / den
                for i in range(len(guess)):
                    guess[i] += omega * r[i]
                r_prev = r^
                self.a.restore()
                self.b.restore()
                self._last_a = xa0.copy()
                self._last_b = xb0.copy()
                total = self._pass(guess, xa0, dt, counters)
                it += 1
            self.iterations = it
        self.imbalance = _norm(total)
        if self.imbalance > self.max_imbalance:
            self.max_imbalance = self.imbalance

    def write_state[W: StateWriter](self, mut w: W):
        """Snapshot: the schedule (ratio, scheme), the conservation record,
        the last finite interface data of each side, then both parts."""
        w.wi(self.ratio)
        w.wi(self.scheme)
        w.wi(f64_bits(Float64(self.imbalance)))
        w.wi(f64_bits(Float64(self.max_imbalance)))
        w.wi(self.iterations)
        write_reals(w, self._last_a)
        write_reals(w, self._last_b)
        self.a.write_state(w)
        self.b.write_state(w)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        if r.ri() != self.ratio or r.ri() != self.scheme:
            raise Error("Coupler.read_state: snapshot of a different schedule")
        self.imbalance = Real(f64_from_bits(r.ri()))
        self.max_imbalance = Real(f64_from_bits(r.ri()))
        self.iterations = r.ri()
        self._last_a = read_reals(r)
        self._last_b = read_reals(r)
        self.a.read_state(r)
        self.b.read_state(r)
