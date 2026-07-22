from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0)
comptime DT: Real = 1.0 / 240.0


def _make_chain(n: Int) raises -> Chain:
    """Deterministic 'random' chain: cycling axes, offset pivots, varying
    masses — no symmetry for parity to hide behind."""
    var ch = Chain()
    for i in range(n):
        var ax = Vec3(0, 0, 1)
        if i % 3 == 1:
            ax = Vec3(1, 0, 0)
        if i % 3 == 2:
            ax = Vec3(0, 1, 0)
        ch.add_link(
            ChainLink(
                ax,
                Vec3(0.1 * Real(i % 2), -0.5, 0.05 * Real(i % 3)),
                Vec3(0.02, -0.25, 0.01),
                1.0 + 0.2 * Real(i),
                Vec3(0.02 + 0.01 * Real(i), 0.015, 0.025),
            )
        )
    for i in range(n):
        ch.q[i] = 0.3 * Real(i) - 0.5
        ch.qd[i] = 0.7 - 0.15 * Real(i)
    return ch^


def _tau(n: Int) -> List[Real]:
    var t = List[Real]()
    for i in range(n):
        t.append(0.2 * Real(i) - 0.1)
    return t^


def main() raises:
    var s = Suite("aba")

    # 1. Parity vs the dense CRBA+RNEA path across chain lengths: two
    #    independent algorithms, one mechanics.
    var worst = Float64(0)
    for n in range(1, 7):
        var ch = _make_chain(n)
        var qdd_d = ch.dynamics(_tau(n), G)
        var qdd_a = ch.dynamics_aba(_tau(n), G)
        for i in range(n):
            var rel = abs(Float64(qdd_d[i]) - Float64(qdd_a[i])) / max(
                Float64(1), abs(Float64(qdd_d[i]))
            )
            if rel > worst:
                worst = rel
    print("  parity: worst relative qdd error (n=1..6):", worst)
    s.check(worst < 1e-3, "ABA == CRBA+RNEA on mixed chains (rel < 1e-3)")

    # 2. Analytic anchor: chain hanging straight down, at rest -> qdd = 0.
    var hang = Chain()
    for _ in range(4):
        hang.add_link(
            ChainLink(
                Vec3(0, 0, 1),
                Vec3(0, -0.5, 0),
                Vec3(0, -0.25, 0),
                1.0,
                Vec3(0.02, 0.015, 0.025),
            )
        )
    var zt = List[Real]()
    for _ in range(4):
        zt.append(0)
    var q0 = hang.dynamics_aba(zt, G)
    var mx = Float64(0)
    for i in range(4):
        if abs(Float64(q0[i])) > mx:
            mx = abs(Float64(q0[i]))
    print("  hanging equilibrium: max |qdd|", mx)
    s.check(mx < 1e-4, "straight-down chain at rest stays at rest")

    # 3. Energy: the SAME double pendulum test_chain runs with the dense
    #    path (q0 = 0.5/0.3, rod inertias, 3000 steps), integrated with
    #    step_aba — same conservation gate, second algorithm.
    var dp = Chain()
    for _ in range(2):
        dp.add_link(
            ChainLink(
                Vec3(0, 0, 1),
                Vec3(0, -1, 0),
                Vec3(0, -0.5, 0),
                1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
    # first pivot at the origin, like test_chain
    var l0 = dp.links[0]
    l0.pivot = Vec3(0, 0, 0)
    dp.links[0] = l0
    dp.q[0] = 0.5
    dp.q[1] = 0.3
    var e0 = Float64(dp.energy(G))
    var t2 = List[Real]()
    for _ in range(2):
        t2.append(0)
    for _ in range(3000):
        dp.step_aba(DT, t2, G)
    var e1 = Float64(dp.energy(G))
    var drift = abs(e1 - e0) / max(abs(e0), Float64(1e-9))
    print("  double pendulum via ABA: energy drift:", drift)
    s.check(drift < 2e-2, "ABA integration conserves energy (same gate)")

    s.finish()
