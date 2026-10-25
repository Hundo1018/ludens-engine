# tier: component
"""Checkpointed reverse-mode gradients (ROADMAP 17.84,
`geometry.checkpoint`).

  1. Ordinary: a chain of 8 masses on springs (stiffness k, damping c, a
     nonlinear sqrt(1 + x^2) term) stepped 600 times; the gradient of the
     final energy-like loss with respect to (k, c) and the initial state is
     the same, bit for bit, from one full tape and from checkpoints every
     1, 50 and 600 steps (and 7, which does not divide 600).
  2. Integration: the gradient matches central finite differences of the
     loss in Float64-accumulated f32 (relative 1e-2 at h = 1e-3); the peak
     tape length falls from the whole rollout to one segment (printed:
     600 / 50 = 12x fewer nodes).
  3. Extreme: zero steps gives the loss's own gradient in both; a stride
     larger than the rollout is one segment (same as full).
"""

from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RevReal
from geometry.checkpoint import RevSystem, RevGrad, grad_full, grad_checkpointed

comptime N = 8
comptime DT: Real = 0.01


struct Chain(RevSystem):
    def __init__(out self):
        pass

    def state_dim(self) -> Int:
        return 2 * N

    def param_dim(self) -> Int:
        return 2

    def step(self, mut state: List[RevReal], params: List[RevReal]):
        var k = params[0]
        var c = params[1]
        var h = RevReal.const(DT)
        var one = RevReal.const(1)
        for i in range(N):
            var x = state[i]
            var v = state[N + i]
            var left = state[i - 1] if i > 0 else RevReal.const(0)
            var right = state[i + 1] if i + 1 < N else x
            var f = k * (left + right - x - x) - c * v - (one + x * x).root() + one
            state[N + i] = v + h * f
        for i in range(N):
            state[i] = state[i] + h * state[N + i]

    def loss(self, state: List[RevReal]) -> RevReal:
        var acc = RevReal.const(0)
        for i in range(2 * N):
            acc = acc + state[i] * state[i]
        return acc


def _x0() -> List[Real]:
    var x = List[Real]()
    for i in range(2 * N):
        x.append(Real(0.3) * Real((i * 5) % 7) - 0.8 if i < N else Real(0))
    return x^


def _same(a: RevGrad, b: RevGrad) -> Bool:
    if a.loss != b.loss or len(a.d_params) != len(b.d_params) or len(a.d_state0) != len(b.d_state0):
        return False
    for i in range(len(a.d_params)):
        if a.d_params[i] != b.d_params[i]:
            return False
    for i in range(len(a.d_state0)):
        if a.d_state0[i] != b.d_state0[i]:
            return False
    return True


def main() raises:
    var s = Suite("checkpoint")
    var sys = Chain()
    var p: List[Real] = [40.0, 0.5]
    var x0 = _x0()
    var full = grad_full(sys, x0, p, 600)
    var all_same = True
    var peaks = List[Int]()
    for every in [1, 7, 50, 600]:
        var g = grad_checkpointed(sys, x0, p, 600, every)
        all_same = all_same and _same(full, g)
        peaks.append(g.peak_nodes)
    print("  600 steps: loss", full.loss, " dL/dk", full.d_params[0], " dL/dc", full.d_params[1], " dL/dx0[0]", full.d_state0[0])
    print("  peak tape nodes: full", full.peak_nodes, " every 1 / 7 / 50 / 600:", peaks[0], peaks[1], peaks[2], peaks[3])
    s.check(all_same, "checkpoints every 1, 7, 50, 600 steps give the full tape's gradient bit for bit")
    s.check(peaks[2] * 10 < full.peak_nodes and peaks[3] == full.peak_nodes, "every 50: >10x fewer nodes at once; one segment = the full tape")

    # finite differences on (k, c)
    var fd = List[Real]()
    for j in range(2):
        var hp = p.copy()
        var hm = p.copy()
        var h = Real(1e-3) * max(abs(p[j]), Real(1))
        hp[j] += h
        hm[j] -= h
        fd.append((grad_full(sys, x0, hp, 600).loss - grad_full(sys, x0, hm, 600).loss) / (2 * h))
    print("  finite differences: dL/dk", fd[0], " dL/dc", fd[1])
    var ok = True
    for j in range(2):
        ok = ok and abs(fd[j] - full.d_params[j]) <= 1e-2 * max(abs(full.d_params[j]), Real(1e-3))
    s.check(ok, "the gradient matches central differences (1 %)")

    var z0 = grad_full(sys, x0, p, 0)
    var z1 = grad_checkpointed(sys, x0, p, 0, 10)
    s.check(_same(z0, z1) and z0.d_state0[0] == 2 * x0[0], "zero steps: the loss's own gradient, both ways")
    var big = grad_checkpointed(sys, x0, p, 600, 5000)
    s.check(_same(full, big), "a stride longer than the rollout is the full tape")
    s.finish()
