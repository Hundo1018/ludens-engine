"""Source-to-source style adjoint vs the runtime tape and finite differences.

Three independent gradient routes must agree on the same rollout: the emitted
adjoint (`rollout_ctrl_adjoint`), the runtime reverse tape (`RevReal`+`Tape`),
and central finite differences. Agreement of all three is what makes the
adjoint believable — the tape and the adjoint share no code, and FD shares no
assumptions with either.

The branch checkpoint is the part worth testing hardest. The ground penalty is
a discrete decision, so the backward pass replays a recorded bit per step; if
that recording were off by one step the gradient would still look plausible in
magnitude while being wrong. The projectile is launched so that it genuinely
crosses in and out of contact, and the check runs at several parameter counts
so a mis-indexed burst boundary cannot hide.
"""

from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RealF, Tape, RevReal, rev_seed
from physics.diffsim import rollout_ctrl, rollout_ctrl_adjoint


def _fd_grad(base: List[Real], burst: Int, dt: Real, k: Int, h: Real) -> Real:
    var up = List[RealF]()
    var dn = List[RealF]()
    for j in range(len(base)):
        up.append(RealF(base[j] + (h if j == k else Real(0))))
        dn.append(RealF(base[j] - (h if j == k else Real(0))))
    var su = rollout_ctrl[RealF](up, burst, dt)
    var sd = rollout_ctrl[RealF](dn, burst, dt)
    return (su.x.value() - sd.x.value()) / (2 * h)


def main() raises:
    var s = Suite("adjoint")
    comptime DT: Real = 0.001

    var counts = List[Int]()
    counts.append(2)
    counts.append(8)
    counts.append(20)

    var bursts = List[Int]()
    bursts.append(1000)
    bursts.append(250)
    bursts.append(100)

    var primal_ok = True
    var tape_ok = True
    var fd_ok = True
    var worst_tape = Real(0)
    var worst_fd = Real(0)

    for ci in range(len(counts)):
        var n = counts[ci]
        var burst = bursts[ci]
        var base = List[Real]()
        for k in range(n):
            base.append(0.3 + 0.05 * Real(k))

        # 1. emitted adjoint
        var g_adj = List[Real]()
        var x_adj = rollout_ctrl_adjoint(base, burst, DT, g_adj)

        # 2. primal must match the Field-generic rollout exactly
        var u0 = List[RealF]()
        for k in range(n):
            u0.append(RealF(base[k]))
        var s0 = rollout_ctrl[RealF](u0, burst, DT)
        if abs(x_adj - s0.x.value()) > 1e-3:
            primal_ok = False
            print("  primal mismatch n=", n, " adj=", x_adj, " ref=", s0.x.value())

        # 3. runtime reverse tape
        var tape = Tape()
        var ur = List[RevReal]()
        for k in range(n):
            ur.append(rev_seed(tape, base[k]))
        var sr = rollout_ctrl[RevReal](ur, burst, DT)
        var adj = tape.grad(sr.x.idx)
        for k in range(n):
            var e = abs(g_adj[k] - adj[ur[k].idx])
            if e > worst_tape:
                worst_tape = e
            if e > 1e-2:
                tape_ok = False

        # 4. central finite differences
        for k in range(n):
            var e = abs(g_adj[k] - _fd_grad(base, burst, DT, k, 1e-3))
            if e > worst_fd:
                worst_fd = e
            if e > 1e-1:
                fd_ok = False

    print("  worst |adjoint - tape| :", worst_tape)
    print("  worst |adjoint - fd|   :", worst_fd)
    s.check(primal_ok, "adjoint's forward pass reproduces the generic rollout")
    s.check(tape_ok, "adjoint gradient == runtime reverse tape")
    s.check(fd_ok, "adjoint gradient == central finite differences")

    # 5. the gradient is not trivially zero (a silent all-zero would pass a
    #    sloppy tolerance check against nothing)
    var base2 = List[Real]()
    for k in range(8):
        base2.append(0.3 + 0.05 * Real(k))
    var g2 = List[Real]()
    _ = rollout_ctrl_adjoint(base2, 250, DT, g2)
    var nonzero = 0
    for k in range(8):
        if abs(g2[k]) > 1e-6:
            nonzero += 1
    s.eqi(nonzero, 8, "every control has a non-zero gradient")

    s.finish()
