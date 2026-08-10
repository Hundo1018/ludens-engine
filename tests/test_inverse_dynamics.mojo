"""Exact inverse dynamics: tau = ID(q, qd, qdd).

The load-bearing check is the ROUND TRIP. Forward dynamics solves
qdd = H⁻¹(tau − C) with a dense mass matrix; inverse dynamics recovers tau by
a single O(n) Newton-Euler sweep with no matrix at all. They are different
code paths through different algebra, so tau → qdd → tau agreeing to float
precision is strong evidence both are right — much stronger than either
against a hand-computed case, which would only exercise one configuration.

Run over chains, a branching tree and a forest, because the backward sweep's
parent accumulation is where a topology bug hides: a serial chain has one
child per link and never exercises the "several children fold into one parent"
path at all.
"""

from std.math import sqrt
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0)


def _link(axis: Vec3, pivot: Vec3) -> ChainLink:
    return ChainLink(
        axis, Vec3(0, 0, 0), pivot, 1.0, Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0)
    )


def _serial(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(_link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    return c^


def _tree() raises -> Chain:
    """Y shape: two children under one parent — exercises the fold."""
    var c = Chain()
    var root = c.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    _ = c.add_link_to(root, _link(Vec3(1, 0, 0), Vec3(0, -0.5, 0)))
    _ = c.add_link_to(root, _link(Vec3(0, 1, 0), Vec3(0, -0.5, 0)))
    return c^


def _forest() raises -> Chain:
    """Two independent roots in one Chain."""
    var c = Chain()
    var a = c.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    _ = c.add_link_to(a, _link(Vec3(1, 0, 0), Vec3(0, -0.5, 0)))
    var b = c.add_link_to(-1, _link(Vec3(0, 1, 0), Vec3(0, -0.5, 0)))
    _ = c.add_link_to(b, _link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    return c^


def _roundtrip(mut c: Chain, mut rng: SplitMix64) raises -> Real:
    """Worst |tau − ID(FD(tau))| over random states and torques."""
    var n = len(c.links)
    var worst = Real(0)
    for _ in range(20):
        for i in range(n):
            c.q[i] = Real(rng.next_f32()) * 2 - 1
            c.qd[i] = Real(rng.next_f32()) * 2 - 1
        var tau = List[Real]()
        for _ in range(n):
            tau.append(Real(rng.next_f32()) * 4 - 2)
        var qdd = c.dynamics(tau, G)
        var tau2 = c.inverse_dynamics(qdd, G)
        for i in range(n):
            var e = abs(tau[i] - tau2[i])
            if e > worst:
                worst = e
    return worst


def main() raises:
    var s = Suite("inverse_dynamics")
    var rng = SplitMix64.seeded(101)

    # 1. round trip on a serial chain
    var c2 = _serial(2)
    var w2 = _roundtrip(c2, rng)
    var c8 = _serial(8)
    var w8 = _roundtrip(c8, rng)
    print("  worst round-trip error: n=2", w2, " n=8", w8)
    s.check(w2 < 1e-3, "2-link chain: tau -> qdd -> tau round trips")
    s.check(w8 < 1e-2, "8-link chain: tau -> qdd -> tau round trips")

    # 2. branching tree and forest — the parent-fold path
    var t = _tree()
    var wt = _roundtrip(t, rng)
    var f = _forest()
    var wf = _roundtrip(f, rng)
    print("  worst round-trip error: tree", wt, " forest", wf)
    s.check(wt < 1e-3, "branching tree round trips")
    s.check(wf < 1e-3, "forest round trips")

    # 3. gravity compensation: at rest, ID(0) is the torque that HOLDS the
    #    pose, so applying it must produce zero acceleration.
    var g = _serial(3)
    g.q[0] = 0.4
    g.q[1] = -0.7
    g.q[2] = 0.2
    var zero_qdd = List[Real]()
    for _ in range(3):
        zero_qdd.append(0)
    var hold = g.inverse_dynamics(zero_qdd, G)
    var acc = g.dynamics(hold, G)
    var worst_hold = Real(0)
    for i in range(3):
        if abs(acc[i]) > worst_hold:
            worst_hold = abs(acc[i])
    print("  residual acceleration under holding torque:", worst_hold)
    s.check(worst_hold < 1e-3, "ID(qdd=0) is the torque that holds the pose")
    var nonzero = False
    for i in range(3):
        if abs(hold[i]) > 1e-3:
            nonzero = True
    s.check(nonzero, "the holding torque is not trivially zero")

    # 4. linearity in qdd: ID(a) - ID(0) must be linear, since H is
    #    configuration-dependent but NOT acceleration-dependent. A bug that
    #    leaked a velocity term into the qdd path would break this and pass
    #    the round trip.
    var lc = _serial(4)
    for i in range(4):
        lc.q[i] = Real(rng.next_f32()) - 0.5
        lc.qd[i] = Real(rng.next_f32()) - 0.5
    var z4 = List[Real]()
    var a4 = List[Real]()
    var two_a4 = List[Real]()
    for i in range(4):
        z4.append(0)
        var v = Real(i + 1) * 0.3
        a4.append(v)
        two_a4.append(2 * v)
    var t0 = lc.inverse_dynamics(z4, G)
    var t1 = lc.inverse_dynamics(a4, G)
    var t2 = lc.inverse_dynamics(two_a4, G)
    var worst_lin = Real(0)
    for i in range(4):
        # (ID(2a) - ID(0)) must equal 2*(ID(a) - ID(0))
        var e = abs((t2[i] - t0[i]) - 2 * (t1[i] - t0[i]))
        if e > worst_lin:
            worst_lin = e
    print("  worst linearity-in-qdd error:", worst_lin)
    s.check(worst_lin < 1e-3, "ID is affine in qdd (H is acceleration-free)")

    s.finish()
