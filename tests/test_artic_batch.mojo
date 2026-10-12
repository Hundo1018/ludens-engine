# tier: integration
"""Batched articulations (ROADMAP 17.17): the GPU kernel body run on the host.

`ArticBatch` runs `aba_instance` (flat arrays, workspace, general motion
subspace) once per instance. Checks:
1. revolute chain and Y-tree: qdd == `Chain.dynamics_aba` (the same sweeps,
   so near bit-equal) and == `Chain.dynamics` (CRBA + RNEA, independent);
2. mixed prismatic / revolute tree: qdd == `Chain.dynamics` (the existing
   ABA cannot do prismatic joints, CRBA can);
3. 64 instances with different states: each equals its own 1-instance run
   bit-for-bit (no cross-talk through the workspace);
2b. analytic bead on a spinning rod (prismatic under a rotating parent):
   batch ABA, `Chain.dynamics` and `Chain.energy` against closed form;
4. 2 s of `step_host` vs `Chain.step` on the mixed tree with tau = 0: same
   trajectory within float noise, energy drift below 0.5 J and equal in
   size to the CPU path's (semi-implicit Euler drift, not a model error).
"""

from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.artic_batch import ArticBatch

comptime G = Vec3(0, -9.8, 0, 0)


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def serial(n: Int) -> Chain:
    var c = Chain()
    for i in range(n):
        var axis = _v(0, 0, 1) if i % 2 == 0 else _v(1, 0, 0)
        var piv = _v(0, 0, 0) if i == 0 else _v(0, -0.5, 0)
        c.add_link(ChainLink.revolute(axis, piv, _v(0.05, -0.25, 0.02), 1.0 + 0.1 * Real(i), _v(0.02, 0.01, 0.02)))
    return c^


def ytree() raises -> Chain:
    var c = Chain()
    c.add_link(ChainLink.revolute(_v(0, 0, 1), _v(0, 0, 0), _v(0, -0.3, 0), 1.5, _v(0.03, 0.01, 0.03)))
    var l = c.add_link_to(0, ChainLink.revolute(_v(1, 0, 0), _v(-0.2, -0.6, 0), _v(0, -0.25, 0), 0.8, _v(0.02, 0.01, 0.02)))
    var r = c.add_link_to(0, ChainLink.revolute(_v(0, 0, 1), _v(0.2, -0.6, 0), _v(0, -0.25, 0), 0.9, _v(0.02, 0.01, 0.02)))
    _ = c.add_link_to(l, ChainLink.revolute(_v(0, 1, 0), _v(0, -0.5, 0), _v(0.03, -0.2, 0), 0.5, _v(0.01, 0.005, 0.01)))
    _ = c.add_link_to(r, ChainLink.revolute(_v(1, 0, 0), _v(0, -0.5, 0), _v(0, -0.2, 0.04), 0.5, _v(0.01, 0.005, 0.01)))
    return c^


def mixed() raises -> Chain:
    """Prismatic joints under rotating parents and vice versa."""
    var c = Chain()
    c.add_link(ChainLink.revolute(_v(0, 0, 1), _v(0, 0, 0), _v(0, -0.3, 0), 1.5, _v(0.03, 0.01, 0.03)))
    var s = c.add_link_to(0, ChainLink.prismatic(_v(0, -1, 0), _v(0, -0.6, 0), _v(0, -0.1, 0.02), 0.8, _v(0.02, 0.01, 0.02)))
    _ = c.add_link_to(s, ChainLink.revolute(_v(1, 0, 0), _v(0, -0.3, 0), _v(0, -0.25, 0), 0.6, _v(0.01, 0.005, 0.01)))
    _ = c.add_link_to(0, ChainLink.prismatic(_v(1, 0, 0), _v(0.2, -0.4, 0), _v(0.05, 0, 0), 0.7, _v(0.01, 0.01, 0.01)))
    return c^


def set_state(mut c: Chain, seed: Int):
    for i in range(len(c.links)):
        var x = Real(seed * 7 + i * 3)
        c.q[i] = 0.4 * sin(x * 1.3) + 0.1
        c.qd[i] = 0.8 * cos(x * 0.7)


def tau_of(n: Int, seed: Int) -> List[Real]:
    var t = List[Real]()
    for i in range(n):
        t.append(0.5 * sin(Real(seed + 5 * i)))
    return t^


def max_rel(a: List[Real], b: List[Real]) -> Float64:
    var worst = Float64(0)
    for i in range(len(a)):
        var d = abs(Float64(a[i] - b[i])) / (1 + abs(Float64(b[i])))
        if d > worst:
            worst = d
    return worst


def batch_qdd(c: Chain, tau: List[Real]) raises -> List[Real]:
    var b = ArticBatch(c, 1)
    for i in range(len(c.links)):
        b.set_tau(0, i, tau[i])
    b.dynamics_host(G)
    var out = List[Real]()
    for i in range(len(c.links)):
        out.append(b.qdd[i])
    return out^


def main() raises:
    var s = Suite("artic_batch")

    # 1. revolute: batch == dynamics_aba == CRBA
    var worst_aba = Float64(0)
    var worst_crba = Float64(0)
    for seed in range(5):
        var c = serial(6)
        set_state(c, seed)
        var tau = tau_of(6, seed)
        var got = batch_qdd(c, tau)
        worst_aba = max(worst_aba, max_rel(got, c.dynamics_aba(tau, G)))
        worst_crba = max(worst_crba, max_rel(got, c.dynamics(tau, G)))
        var t = ytree()
        set_state(t, seed + 11)
        var tt = tau_of(5, seed + 3)
        var gt = batch_qdd(t, tt)
        worst_aba = max(worst_aba, max_rel(gt, t.dynamics_aba(tt, G)))
        worst_crba = max(worst_crba, max_rel(gt, t.dynamics(tt, G)))
    print("  revolute: max rel diff vs dynamics_aba", worst_aba, " vs CRBA", worst_crba)
    s.check(worst_aba < 1e-5, "batch ABA == Chain.dynamics_aba (serial 6 + Y-tree, 5 states)")
    s.check(worst_crba < 1e-3, "batch ABA == Chain.dynamics (CRBA + RNEA)")

    # 2. prismatic + revolute: batch == CRBA
    var worst_mixed = Float64(0)
    for seed in range(5):
        var m = mixed()
        set_state(m, seed + 20)
        var tau = tau_of(4, seed + 7)
        worst_mixed = max(worst_mixed, max_rel(batch_qdd(m, tau), m.dynamics(tau, G)))
    print("  mixed prismatic/revolute: max rel diff vs CRBA", worst_mixed)
    s.check(worst_mixed < 1e-3, "batch ABA handles prismatic joints (== CRBA on a mixed tree)")

    # 2b. analytic: bead (point mass m, prismatic along x) on a rod spinning
    # about z (inertia I0), no gravity: theta'' = -2 m r r' theta' / (I0 + m r^2),
    # r'' = r theta'^2. Pins the prismatic Coriolis coefficient that
    # Chain.link_motion had doubled before 17.17 (CRBA gave -1.4757 here).
    var bead = Chain()
    bead.add_link(ChainLink.revolute(_v(0, 0, 1), _v(0, 0, 0), _v(0, 0, 0), 1.0, _v(0.5, 0.5, 0.5)))
    _ = bead.add_link_to(0, ChainLink.prismatic(_v(1, 0, 0), _v(0, 0, 0), _v(0, 0, 0), 2.0, _v(1e-6, 1e-6, 1e-6)))
    bead.q[0] = 0.3
    bead.q[1] = 0.7
    bead.qd[0] = 1.3
    bead.qd[1] = 0.4
    var z2 = List[Real](length=2, fill=0)
    var thdd = -2 * 2.0 * 0.7 * 0.4 * 1.3 / (0.5 + 2.0 * 0.49 + 1e-6)
    var rdd = 0.7 * 1.3 * 1.3
    var g0 = _v(0, 0, 0)
    var bq = ArticBatch(bead, 1)
    bq.dynamics_host(g0)
    var cq = bead.dynamics(z2, g0)
    s.almost(Float64(bq.qdd[0]), thdd, "bead: batch theta'' == analytic", tol=1e-5)
    s.almost(Float64(bq.qdd[1]), rdd, "bead: batch r'' == analytic", tol=1e-5)
    s.almost(Float64(cq[0]), thdd, "bead: Chain.dynamics theta'' == analytic", tol=1e-5)
    var ke = 0.5 * (0.5 + 2.0 * 0.49 + 1e-6) * 1.69 + 0.5 * 2.0 * 0.16
    s.almost(Float64(bead.energy(g0)), ke, "bead: Chain.energy counts the slider's velocity", tol=1e-5)

    # 3. instances are independent
    var base = ytree()
    var nb = 64
    var batch = ArticBatch(base, nb)
    for k in range(nb):
        var c = ytree()
        set_state(c, k)
        for i in range(5):
            batch.set_q(k, i, c.q[i])
            batch.set_qd(k, i, c.qd[i])
            batch.set_tau(k, i, tau_of(5, k)[i])
    batch.dynamics_host(G)
    var mismatched = 0
    for k in range(nb):
        var c = ytree()
        set_state(c, k)
        var single = batch_qdd(c, tau_of(5, k))
        for i in range(5):
            if single[i].to_bits() != batch.qdd[k * 5 + i].to_bits():
                mismatched += 1
    s.eqi(mismatched, 0, "64 instances: each qdd bit-equal to its 1-instance run")

    # 4. trajectories and energy, mixed tree, tau = 0
    var ref_c = mixed()
    set_state(ref_c, 3)
    var bt = ArticBatch(ref_c, 1)
    var zero = List[Real](length=4, fill=0)
    var dt = Real(1.0 / 960.0)
    var e0 = ref_c.energy(G)
    for _ in range(1920):
        ref_c.step(dt, zero, G)
        bt.step_host(dt, G)
    var worst_q = Float64(0)
    var probe = mixed()
    for i in range(4):
        worst_q = max(worst_q, abs(Float64(bt.q(0, i) - ref_c.q[i])))
        probe.q[i] = bt.q(0, i)
        probe.qd[i] = bt.qd(0, i)
    var drift_cpu = abs(Float64(ref_c.energy(G) - e0))
    var drift_batch = abs(Float64(probe.energy(G) - e0))
    print("  2 s mixed tree: max |q_batch - q_cpu|", worst_q, " energy drift cpu", drift_cpu, " batch", drift_batch)
    s.check(worst_q < 1e-2, "2 s trajectory follows Chain.step (CRBA path) within 1e-2 rad / m")
    s.check(drift_batch < 2 * drift_cpu + 1e-3, "energy drift of the batch path no larger than the CPU path's")
    s.check(drift_batch < 0.5, "energy drift over 2 s below 0.5 J (semi-implicit Euler at dt = 1/960)")
    s.finish()
