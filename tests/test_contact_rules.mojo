# tier: integration
"""Contact modification rules (ROADMAP 17.26).

  ordinary     a one-way platform: a crate launched from below passes up
               through it and lands on it; without the rule it bounces off
               the underside.
  seam parity  rules that match no contact, and a conveyor at zero speed,
               step bit-identically to a scene without rules.
  integration  a conveyor belt drags a resting crate up to belt speed;
               a friction override of 0 lets a crate slide undisturbed and
               of 1 stops it sooner than the default.
  extreme      a rule on an out-of-range body raises; a crate resting on a
               one-way platform stays on it (not dropped by the rule).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.contact6 import ContactRule, RULE_ONE_WAY, RULE_CONVEYOR, RULE_FRICTION

comptime DT: Real = 1.0 / 60.0


def _static(mut sc: ContactScene6[QuatBody6], c: Vec3, h: Vec3) -> Int:
    return sc.add(QuatBody6.at_rest(c, Inertia3.box(1, h[0], h[1], h[2])), h, True).index()


def _crate(mut sc: ContactScene6[QuatBody6], c: Vec3, v: Vec3) raises -> Int:
    var b = QuatBody6.at_rest(c, Inertia3.box(1, 0.2, 0.2, 0.2))
    b.vel = v
    var id = sc.add(b^, Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_can_sleep(id, False)
    return id.index()


def _run(mut sc: ContactScene6[QuatBody6], frames: Int) -> Real:
    var top = Real(-1e9)
    for _ in range(frames):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0))
        top = max(top, sc.bset.bodies[len(sc.bset.bodies) - 1].position()[1])
    return top


def main() raises:
    var s = Suite("contact_rules")

    # ---- one-way platform ----------------------------------------------------
    var ow = ContactScene6[QuatBody6]()
    _ = _static(ow, Vec3(0, -0.5, 0, 0), Vec3(5, 0.5, 5, 0))
    var plat = _static(ow, Vec3(0, 2, 0, 0), Vec3(1, 0.1, 1, 0))
    _ = ow.add_contact_rule(ContactRule(RULE_ONE_WAY, plat, Vec3(0, 1, 0, 0), 0.05))
    var cr = _crate(ow, Vec3(0, 0.3, 0, 0), Vec3(0, 8, 0, 0))
    var top = _run(ow, 180)
    var rest = ow.bset.bodies[cr].position()[1]
    print("  one-way: highest", top, " rest", rest)
    s.check(top > 2.3, "one-way: the crate passes up through the platform")
    s.check(abs(rest - 2.3) < 0.03, "one-way: and lands on top of it")
    var solid = ContactScene6[QuatBody6]()
    _ = _static(solid, Vec3(0, -0.5, 0, 0), Vec3(5, 0.5, 5, 0))
    _ = _static(solid, Vec3(0, 2, 0, 0), Vec3(1, 0.1, 1, 0))
    _ = _crate(solid, Vec3(0, 0.3, 0, 0), Vec3(0, 8, 0, 0))
    var top2 = _run(solid, 180)
    s.check(top2 < 1.9, "without the rule the platform blocks it from below")

    # ---- parity: rules that never apply ----------------------------------------
    var pa = ContactScene6[QuatBody6]()
    var pb = ContactScene6[QuatBody6]()
    var g0 = _static(pa, Vec3(0, -0.5, 0, 0), Vec3(5, 0.5, 5, 0))
    _ = _static(pb, Vec3(0, -0.5, 0, 0), Vec3(5, 0.5, 5, 0))
    var far = _static(pa, Vec3(30, 0, 0, 0), Vec3(1, 1, 1, 0))
    _ = _static(pb, Vec3(30, 0, 0, 0), Vec3(1, 1, 1, 0))
    _ = _crate(pa, Vec3(0.1, 1, 0, 0), Vec3(1, 0, 0.5, 0))
    _ = _crate(pb, Vec3(0.1, 1, 0, 0), Vec3(1, 0, 0.5, 0))
    _ = pa.add_contact_rule(ContactRule(RULE_ONE_WAY, far, Vec3(0, 1, 0, 0), 0.05))
    _ = pa.add_contact_rule(ContactRule(RULE_CONVEYOR, g0, Vec3(0, 0, 0, 0), 0))
    for _ in range(120):
        pa.step_soft(DT, Vec3(0, -9.8, 0, 0))
        pb.step_soft(DT, Vec3(0, -9.8, 0, 0))
    var dp = pa.bset.bodies[2].position() - pb.bset.bodies[2].position()
    s.check(dp[0] == 0 and dp[1] == 0 and dp[2] == 0, "non-matching rules + zero-speed conveyor: bit-identical")

    # ---- conveyor ----------------------------------------------------------------
    var cv = ContactScene6[QuatBody6]()
    var belt = _static(cv, Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 5, 0))
    _ = cv.add_contact_rule(ContactRule(RULE_CONVEYOR, belt, Vec3(2, 0, 0, 0), 0))
    var cc = _crate(cv, Vec3(0, 0.2, 0, 0), Vec3(0, 0, 0, 0))
    _ = _run(cv, 120)
    var vx = cv.bset.bodies[cc].linear_velocity()[0]
    print("  conveyor: crate vx", vx)
    s.check(abs(vx - 2) < 0.1, "conveyor drags a resting crate up to belt speed")

    # ---- friction override -----------------------------------------------------
    var f0 = ContactScene6[QuatBody6]()
    var fg0 = _static(f0, Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 5, 0))
    _ = f0.add_contact_rule(ContactRule(RULE_FRICTION, fg0, Vec3(0, 0, 0, 0), 0))
    var c0 = _crate(f0, Vec3(0, 0.2, 0, 0), Vec3(3, 0, 0, 0))
    var fd = ContactScene6[QuatBody6]()
    _ = _static(fd, Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 5, 0))
    var cd = _crate(fd, Vec3(0, 0.2, 0, 0), Vec3(3, 0, 0, 0))
    var f1 = ContactScene6[QuatBody6]()
    var fg1 = _static(f1, Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 5, 0))
    _ = f1.add_contact_rule(ContactRule(RULE_FRICTION, fg1, Vec3(0, 0, 0, 0), 1))
    var c1 = _crate(f1, Vec3(0, 0.2, 0, 0), Vec3(3, 0, 0, 0))
    _ = _run(f0, 30)
    _ = _run(fd, 30)
    _ = _run(f1, 30)
    var v0 = f0.bset.bodies[c0].linear_velocity()[0]
    var vd = fd.bset.bodies[cd].linear_velocity()[0]
    var v1 = f1.bset.bodies[c1].linear_velocity()[0]
    print("  friction override: mu=0", v0, " default", vd, " mu=1", v1)
    s.check(abs(v0 - 3) < 1e-3, "friction override 0: slides undisturbed")
    s.check(v1 < vd and vd < v0, "friction override 1 stops it sooner than the default")

    # ---- extremes ------------------------------------------------------------------
    var raised = False
    try:
        _ = ow.add_contact_rule(ContactRule(RULE_ONE_WAY, 99, Vec3(0, 1, 0, 0), 0.05))
    except:
        raised = True
    s.check(raised, "a rule on an out-of-range body raises")
    var rs = ContactScene6[QuatBody6]()
    _ = _static(rs, Vec3(0, -0.5, 0, 0), Vec3(5, 0.5, 5, 0))
    var p2 = _static(rs, Vec3(0, 2, 0, 0), Vec3(1, 0.1, 1, 0))
    _ = rs.add_contact_rule(ContactRule(RULE_ONE_WAY, p2, Vec3(0, 1, 0, 0), 0.05))
    var onp = _crate(rs, Vec3(0, 2.31, 0, 0), Vec3(0, 0, 0, 0))
    _ = _run(rs, 120)
    s.check(abs(rs.bset.bodies[onp].position()[1] - 2.3) < 0.03, "a crate resting on a one-way platform stays on it")

    s.finish()
