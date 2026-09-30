"""Contact rules (17.26) and joint break checks (17.29): what they cost.

Rules: N crates resting on the ground, stepped with no rules, with one rule
that matches every contact (a friction override on the ground), and with
eight rules none of which matches -- the per-contact rule scan is the cost
axis. Breaks: N boxes each hanging on a distance joint, unbreakable vs with
a (never reached) threshold on every joint.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.contact6 import ContactRule, RULE_FRICTION, RULE_ONE_WAY

comptime DT: Real = 1.0 / 60.0
comptime FRAMES = 60


def _crates(n: Int, mode: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var gid = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    for i in range(n):
        var id = sc.add(
            QuatBody6.at_rest(Vec3(Real(i % 32) * 0.6 - 9, 0.2, Real(i // 32) * 0.6 - 9, 0), Inertia3.box(1, 0.2, 0.2, 0.2)),
            Vec3(0.2, 0.2, 0.2, 0), False,
        )
        sc.set_can_sleep(id, False)
    if mode == 1:
        _ = sc.add_contact_rule(ContactRule(RULE_FRICTION, gid.index(), Vec3(0, 0, 0, 0), 0.5))
    elif mode == 2:
        var far = sc.add(QuatBody6.at_rest(Vec3(200, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
        for _ in range(8):
            _ = sc.add_contact_rule(ContactRule(RULE_ONE_WAY, far.index(), Vec3(0, 1, 0, 0), 0.05))
    return sc^


def _hangers(n: Int, breakable: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    for i in range(n):
        var x = Real(i) * 2
        var a = sc.add(QuatBody6.at_rest(Vec3(x, 3, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
        var b = sc.add(QuatBody6.at_rest(Vec3(x, 2, 0, 0), Inertia3.box(2, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        sc.set_can_sleep(b, False)
        var j = sc.add_joint(Joint6.distance(a.index(), b.index(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1))
        if breakable:
            sc.set_joint_break(j, 1e6, 1e6)
    return sc^


def _time(mut sc: ContactScene6[QuatBody6]) -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(FRAMES):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), broadphase=True)
    var d = Int(perf_counter_ns()) - t0
    keep(sc.bset.bodies[1].position()[1])
    return d


def main() raises:
    var t = BenchTable("Contact rules and joint break checks: per-frame cost")
    for n in [64, 512]:
        var a = _crates(n, 0)
        t.add("crates, no rules", n, "frame", _time(a), FRAMES)
        var b = _crates(n, 1)
        t.add("crates, 1 rule matching every contact", n, "frame", _time(b), FRAMES)
        var c = _crates(n, 2)
        t.add("crates, 8 rules matching none", n, "frame", _time(c), FRAMES)
    for n in [64, 512]:
        var a = _hangers(n, False)
        t.add("hanging joints, unbreakable", n, "frame", _time(a), FRAMES)
        var b = _hangers(n, True)
        t.add("hanging joints, with break thresholds", n, "frame", _time(b), FRAMES)
    t.print_report()
