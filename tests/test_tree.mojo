from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0)
comptime DT: Real = 1.0 / 240.0


def _link(ax: Vec3, pivot: Vec3) -> ChainLink:
    return ChainLink.revolute(ax, pivot, Vec3(0, -0.25, 0), 1.0, Vec3(0.02, 0.015, 0.025))


def _ytree() raises -> Chain:
    """Torso root with two 2-link arms — the smallest honest ragdoll shape.
    Mixed axes so nothing decouples by accident."""
    var ch = Chain()
    var torso = ch.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, 0, 0)))
    var l1 = ch.add_link_to(torso, _link(Vec3(1, 0, 0), Vec3(-0.3, -0.2, 0)))
    _ = ch.add_link_to(l1, _link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    var r1 = ch.add_link_to(torso, _link(Vec3(0, 0, 1), Vec3(0.3, -0.2, 0)))
    _ = ch.add_link_to(r1, _link(Vec3(1, 0, 0), Vec3(0, -0.5, 0)))
    return ch^


def _tau(n: Int) -> List[Real]:
    var t = List[Real]()
    for i in range(n):
        t.append(0.1 * Real(i) - 0.15)
    return t^


def main() raises:
    var s = Suite("tree")

    # 1. add_link_to(i-1) == add_link: the serial chain is the tree's
    #    special case, bit for bit.
    var a = Chain()
    var b = Chain()
    for i in range(4):
        var lk = _link(
            Vec3(0, 0, 1) if i % 2 == 0 else Vec3(1, 0, 0),
            Vec3(0, -0.5, 0.1),
        )
        a.add_link(lk)
        _ = b.add_link_to(i - 1, lk)
    for i in range(4):
        a.q[i] = 0.3 * Real(i) - 0.4
        b.q[i] = a.q[i]
        a.qd[i] = 0.5 - 0.2 * Real(i)
        b.qd[i] = a.qd[i]
    var qa = a.dynamics(_tau(4), G)
    var qb = b.dynamics(_tau(4), G)
    var qa2 = a.dynamics_aba(_tau(4), G)
    var qb2 = b.dynamics_aba(_tau(4), G)
    var same = True
    for i in range(4):
        if qa[i] != qb[i] or qa2[i] != qb2[i]:
            same = False
    s.check(same, "explicit parents == serial chain (bit-identical)")

    # 2. Forest decoupling: two chains in one Chain (two roots) behave
    #    exactly like two separate Chains.
    var f = Chain()
    var r0 = f.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, 0, 0)))
    _ = f.add_link_to(r0, _link(Vec3(1, 0, 0), Vec3(0, -0.5, 0)))
    var r1 = f.add_link_to(-1, _link(Vec3(1, 0, 0), Vec3(2, 0, 0)))
    _ = f.add_link_to(r1, _link(Vec3(0, 0, 1), Vec3(0, -0.5, 0)))
    f.q[0] = 0.4
    f.q[1] = -0.2
    f.q[2] = 0.7
    f.q[3] = 0.1
    f.qd[0] = 1.0
    f.qd[2] = -0.5
    var qf = f.dynamics_aba(_tau(4), G)
    var c1 = Chain()
    c1.add_link(_link(Vec3(0, 0, 1), Vec3(0, 0, 0)))
    c1.add_link(_link(Vec3(1, 0, 0), Vec3(0, -0.5, 0)))
    c1.q[0] = 0.4
    c1.q[1] = -0.2
    c1.qd[0] = 1.0
    var t1 = List[Real]()
    t1.append(_tau(4)[0])
    t1.append(_tau(4)[1])
    var q1 = c1.dynamics_aba(t1, G)
    var dec = qf[0] == q1[0] and qf[1] == q1[1]
    s.check(dec, "forest: two roots solve as two independent chains")

    # 3. Y-tree: ABA vs dense CRBA+RNEA parity on a branched topology.
    var y = _ytree()
    y.q[0] = 0.3
    y.q[1] = -0.6
    y.q[2] = 0.4
    y.q[3] = 0.5
    y.q[4] = -0.3
    y.qd[0] = 0.8
    y.qd[1] = -0.4
    y.qd[2] = 0.2
    y.qd[3] = -0.7
    y.qd[4] = 0.5
    var qd_d = y.dynamics(_tau(5), G)
    var qd_a = y.dynamics_aba(_tau(5), G)
    var worst = Float64(0)
    for i in range(5):
        var rel = abs(Float64(qd_d[i]) - Float64(qd_a[i])) / max(
            Float64(1), abs(Float64(qd_d[i]))
        )
        if rel > worst:
            worst = rel
    print("  Y-tree ABA vs dense worst rel err:", worst)
    s.check(worst < 1e-3, "branched ABA == branched CRBA+RNEA")

    # 4. Hanging Y-tree at rest: qdd = 0 (both arms straight down).
    var h = Chain()
    var ht = h.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, 0, 0)))
    _ = h.add_link_to(ht, _link(Vec3(0, 0, 1), Vec3(-0.3, -0.5, 0)))
    _ = h.add_link_to(ht, _link(Vec3(0, 0, 1), Vec3(0.3, -0.5, 0)))
    var zt = List[Real]()
    for _ in range(3):
        zt.append(0)
    var qh = h.dynamics_aba(zt, G)
    var mx = Float64(0)
    for i in range(3):
        if abs(Float64(qh[i])) > mx:
            mx = abs(Float64(qh[i]))
    print("  hanging Y max |qdd|:", mx)
    s.check(mx < 1e-4, "hanging branched tree at rest stays at rest")

    # 5. Energy conservation on the swinging Y-tree via step_aba.
    var e = _ytree()
    e.q[1] = 0.8
    e.q[3] = -0.8
    var e0 = Float64(e.energy(G))
    var t5 = List[Real]()
    for _ in range(5):
        t5.append(0)
    # dt/2 vs the double-pendulum gates: the +-0.8 double-arm swing is a
    # harder integration target; halving dt (same 12.5 s horizon) keeps the
    # drift within the shared 2e-2 gate and pins the residual on the
    # first-order integrator, not the tree dynamics (parity: 2e-7)
    for _ in range(6000):
        e.step_aba(DT / 2, t5, G)
    var e1 = Float64(e.energy(G))
    var drift = abs(e1 - e0) / max(abs(e0), Float64(1e-9))
    print("  Y-tree energy drift:", drift)
    s.check(drift < 2e-2, "branched tree conserves energy (step_aba)")

    s.finish()
