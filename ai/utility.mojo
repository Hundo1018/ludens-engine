"""Utility AI (ROADMAP 17.15).

Each action has a weight and a list of considerations. A consideration reads
one blackboard key, normalises it to [0, 1] over [lo, hi], and maps it
through a response curve:

- `CURVE_LINEAR`:    m * x + b
- `CURVE_POLY`:      m * (x - c)^k + b
- `CURVE_LOGISTIC`:  k / (1 + exp(-m * (x - c))) + b
- `CURVE_STEP`:      1 if x >= c else 0 (b added)
- `CURVE_STEP_BELOW`: 1 if x < c else 0 (b added)

clamped to [0, 1]. An unset key scores `missing` (default 0). The action score
is the product of its considerations with Dave Mark's compensation factor
(so adding considerations does not by itself drive scores to zero), times its
weight; the running action gets `momentum` added (hysteresis, so two near-equal
actions do not flicker). `UtilityAI.decide` returns the best action (lowest
index on ties) or -1 when every score is 0.
"""

from std.math import exp
from geometry.vec import Real
from ai.blackboard import Blackboard

comptime CURVE_LINEAR = 0
comptime CURVE_POLY = 1
comptime CURVE_LOGISTIC = 2
comptime CURVE_STEP = 3
comptime CURVE_STEP_BELOW = 4


@fieldwise_init
struct Consideration(Copyable, ImplicitlyCopyable, Movable):
    var key: Int
    var lo: Real
    var hi: Real
    var curve: Int
    var m: Real
    var k: Real
    var b: Real
    var c: Real
    var missing: Real  # score when the key is unset

    def score(self, bb: Blackboard) -> Real:
        if not bb.has(self.key):
            return self.missing
        var span = self.hi - self.lo
        var x = (bb.get(self.key) - self.lo) / span if span != 0 else Real(0)
        x = min(max(x, 0), 1)
        var y: Real
        match self.curve:
            case == CURVE_LINEAR:
                y = self.m * x + self.b
            case == CURVE_POLY:
                var d = x - self.c
                var p = Real(1)
                for _ in range(Int(self.k)):
                    p *= d
                y = self.m * p + self.b
            case == CURVE_LOGISTIC:
                y = self.k / (1 + exp(-self.m * (x - self.c))) + self.b
            case == CURVE_STEP:
                y = (Real(1) if x >= self.c else Real(0)) + self.b
            case _:
                y = (Real(1) if x < self.c else Real(0)) + self.b
        return min(max(y, 0), 1)


struct UtilityAI(Movable):
    var weight: List[Real]
    var cons: List[List[Consideration]]
    var momentum: Real
    var current: List[Int]  # per agent: running action (-1 none)

    def __init__(out self, momentum: Real = 0.0):
        self.weight = List[Real]()
        self.cons = List[List[Consideration]]()
        self.momentum = momentum
        self.current = List[Int]()

    def add_action(mut self, weight: Real = 1) -> Int:
        self.weight.append(weight)
        self.cons.append(List[Consideration]())
        return len(self.weight) - 1

    def consider(mut self, action: Int, c: Consideration):
        self.cons[action].append(c)

    def score(self, action: Int, bb: Blackboard) -> Real:
        var n = len(self.cons[action])
        var s = Real(1)
        if n > 0:
            var mod = 1 - Real(1) / Real(n)
            for c in self.cons[action]:
                var v = c.score(bb)
                v += (1 - v) * mod * v  # compensation factor
                s *= v
        return s * self.weight[action]

    def decide(mut self, agent: Int, bb: Blackboard) -> Int:
        while len(self.current) <= agent:
            self.current.append(-1)
        var best = -1
        var best_s = Real(0)
        for a in range(len(self.weight)):
            var s = self.score(a, bb)
            if s > 0 and a == self.current[agent]:
                s += self.momentum
            if s > best_s:
                best_s = s
                best = a
        self.current[agent] = best
        return best
