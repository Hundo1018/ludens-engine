# tier: integration
"""Musculotendon unit: Hill fiber + elastic series tendon along a spatial
path (ROADMAP 17.57, `physics.muscle_tendon.MuscleTendon`).

  1. Ordinary (rigid limit): with eps0 = 0 the force equals
     `ActuatorBank.muscle_force` with the same `HillParams` at the same fiber
     length and velocity (constant-arm model, 5 joint states, relative 1e-5).
  2. Integration (series elasticity): isometric (l_mt fixed) from rest,
     activation stepped 0 -> 1: the rigid unit reaches its force in one
     step; the compliant one (eps0 = 0.04) rises over tens of ms (time to
     90 % printed) and settles where fiber and tendon balance,
     F / f_peak == a fl(l_m) + fp(l_m) (1e-3), at a shorter fiber than the
     rigid one; a stiff tendon (eps0 = 1e-3) ends within 2 % of the rigid
     force.
  3. Path moment arms: the unit routed through a `SpatialTendon` over two
     joints puts tau_i = -F dL/dq_i on both (central difference of the path
     length, within 1e-3 of the largest; joint 0 turns both sites rigidly,
     so its arm is 0), and the arm changes with the pose (unlike the
     constant-arm model); driving the 2-link arm for 1 s stays finite.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.actuator import Actuator, ActuatorBank, HillParams
from physics.tendon import SpatialTendon
from physics.muscle_tendon import MuscleTendon

comptime DT: Real = 1.0 / 2000.0


def flexor() -> HillParams:
    return HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10)


def chain2() -> Chain:
    var c = Chain()
    for _ in range(2):
        c.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0.6, 0, 0, 0), Vec3(0.3, 0, 0, 0), 1.0, Vec3(0.02, 0.02, 0.02, 0)))
    return c^


def main() raises:
    var s = Suite("muscle_tendon")
    var h = flexor()
    var bank = ActuatorBank()
    var i = bank.add_hill(Actuator.muscle(0, 100.0, 0.01), h)
    bank.state[i] = 0.7
    var mt = MuscleTendon(h, 100.0, h.tendon_slack, 0)
    var worst = Real(0)
    for st in [(0.0, 0.0), (0.5, 0.0), (0.9, 0.0), (0.5, -2.0), (0.3, 1.5)]:
        var q = Real(st[0])
        var qd = Real(st[1])
        var want = bank.muscle_force(i, q, qd)
        var got = mt.step(0.7, h.l_mt0 - h.arm * q, -h.arm * qd, DT)
        worst = max(worst, abs(got - want) / max(abs(want), Real(1e-6)))
    print("rigid tendon vs ActuatorBank.muscle_force: worst relative difference", worst)
    s.check(worst < 1e-5, "eps0 = 0 reproduces the constant-arm rigid-tendon Hill force")

    var l_mt = Real(0.31)
    var rigid = MuscleTendon(h, 100.0, h.tendon_slack, 0)
    var comp = MuscleTendon(h, 100.0, h.tendon_slack, 0.04)
    var stiff = MuscleTendon(h, 100.0, h.tendon_slack, 1e-3)
    comp.equilibrate(0, l_mt)
    stiff.equilibrate(0, l_mt)
    var f_rigid = rigid.step(1, l_mt, 0, DT)
    var f_final = Real(0)
    var t90 = Real(-1)
    var f_stiff = Real(0)
    var n = 1000  # 0.5 s
    var fc = List[Real]()
    for k in range(n):
        fc.append(comp.step(1, l_mt, 0, DT))
        f_stiff = stiff.step(1, l_mt, 0, DT)
    f_final = fc[n - 1]
    for k in range(n):
        if t90 < 0 and fc[k] >= 0.9 * f_final:
            t90 = Real(k + 1) * DT
    var bal = comp.fl(comp.l_m) + comp.fp(comp.l_m)
    print("isometric step 0 -> 1: rigid", f_rigid, "N at once;  compliant", f_final, "N after 0.5 s, 90 % at", t90, "s;  fiber", comp.l_m, "vs rigid", rigid.l_m, ";  balance", f_final / 100.0, bal, ";  stiff tendon", f_stiff)
    s.check(t90 > 0.01 and abs(f_final / 100.0 - bal) < 1e-3 and comp.l_m < rigid.l_m, "compliant tendon: delayed rise, fiber and tendon balance at a shorter fiber")
    s.check(abs(f_stiff / f_rigid - 1) < 0.02, "a stiff tendon ends within 2 % of the rigid force")

    var c = chain2()
    c.q[0] = 0.3
    c.q[1] = 0.8
    var path = SpatialTendon()
    path.add_site(0, Vec3(0.2, 0.08, 0, 0))
    path.add_site(1, Vec3(0.3, 0.08, 0, 0))
    var L = path.length(c)
    # slack sized to the path: the fiber starts near its optimal length
    var unit = MuscleTendon(h, 100.0, L - h.l_opt, 0.04)
    unit.equilibrate(0.5, L)
    var f = unit.step(0.5, L, 0, DT)
    var tau: List[Real] = [0.0, 0.0]
    path.apply_tension(c, f, tau)
    var arms = List[Real]()
    for j in range(2):
        var save = c.q[j]
        c.q[j] = save + 1e-3
        var lp = path.length(c)
        c.q[j] = save - 1e-3
        var lm = path.length(c)
        c.q[j] = save
        var dl = (lp - lm) / 2e-3
        arms.append(dl)
    # joint 0 turns both sites rigidly: its dL/dq is 0 up to f32 noise, so
    # both joints are judged against the largest |F dL/dq|
    var scale = max(abs(f * arms[0]), abs(f * arms[1]))
    var worst_arm = max(abs(tau[0] + f * arms[0]), abs(tau[1] + f * arms[1])) / scale
    c.q[1] = 0.2
    var arm_other = path.moment_arms(c)[1]
    print("path unit: force", f, "N;  tau", tau[0], tau[1], " vs -F dL/dq", -f * arms[0], -f * arms[1], ";  joint-1 arm at q1 0.8", arms[1], "at 0.2", arm_other)
    s.check(f > 0 and worst_arm < 1e-3, "tau_i = -F dL/dq_i on every joint the path crosses")
    s.check(abs(arm_other - arms[1]) > 1e-3, "the moment arm changes with the pose")

    var arm = chain2()
    var l0 = path.length(arm)
    var u = MuscleTendon(h, 100.0, l0 - h.l_opt, 0.04)
    u.equilibrate(0, l0)
    var prev = l0
    var fine = True
    for _ in range(2000):
        var l = path.length(arm)
        var fo = u.step(0.6, l, (l - prev) / DT, DT)
        prev = l
        var t2: List[Real] = [0.0, 0.0]
        path.apply_tension(arm, fo, t2)
        arm.step(DT, t2, Vec3(0, -9.8, 0, 0))
        fine = fine and isfinite(arm.q[0]) and isfinite(arm.q[1]) and isfinite(fo)
    print("driven 2-link arm, 1 s: q", arm.q[0], arm.q[1], " force", u.force)
    s.check(fine, "a path-routed compliant muscle drives the arm for 1 s, finite")
    s.finish()
