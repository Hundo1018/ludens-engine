# tier: integration
"""Reduced-coordinate joint properties and chain snapshots (ROADMAP 17.51).

One revolute link: 1 kg, centre of mass 0.5 m out, 0.01 kg m^2 about it,
so I = 0.26 kg m^2 about the joint.

  1. Ordinary:
     - a joint spring of stiffness 1e5 at dt = 1/60 (omega dt = 10.3): as
       an explicit PD torque it diverges; as the implicit field it never
       exceeds its starting deflection and decays;
     - armature 0.5 kg m^2 lengthens the small-swing pendulum period to
       2 pi sqrt((I + Ia) / (m g l)) = 2.474 s;
     - damping b: each step multiplies the speed by I / (I + b dt), the
       backward-Euler factor, and 1 s ends within 4 % of e^(-b t / I);
     - spring rest 0 against gravity: the link settles where
       k q = -m g l cos q.
  2. Integration: Coulomb friction 0.26 N m stops a link spinning at
     2 rad/s after 2 s (I w / f) and holds it; a 3-link chain with every
     property set, saved mid-run (`write_chain`) and restored
     (`read_chain`), steps bit-identically.
  3. Extreme / parity: all properties zero -- `step_implicit` tracks the
     explicit `step` within 1e-4 over 1 s; negative damping raises.
"""

from std.math import sqrt, cos, sin, exp, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink, write_chain, read_chain
from physics.serialize import BinWriter, BinReader

comptime DT: Real = 1.0 / 60.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime G = Vec3(0, -9.8, 0, 0)


def _link() -> ChainLink:
    return ChainLink.revolute(Vec3(0, 0, 1, 0), ZERO, Vec3(0.5, 0, 0, 0), 1, Vec3(0.01, 0.01, 0.01, 0))


def _one() -> Chain:
    var c = Chain()
    c.add_link(_link())
    return c^


def main() raises:
    var s = Suite("chain_props")
    var inertia = Real(0.26)

    # ---- stiff spring: explicit vs implicit ------------------------------
    var k = Real(1e5)
    var ex = _one()
    ex.q[0] = 0.1
    var worst_ex = Real(0)
    for _ in range(60):
        var tau: List[Real] = [-k * ex.q[0]]
        ex.step(DT, tau, ZERO)
        worst_ex = max(worst_ex, abs(ex.q[0]))
    var im = _one()
    im.q[0] = 0.1
    im.set_joint_props(0, stiffness=k)
    var worst_im = Real(0)
    for _ in range(60):
        im.step_implicit(DT, [Real(0)], ZERO)
        worst_im = max(worst_im, abs(im.q[0]))
    print("  stiffness 1e5 at dt 1/60: explicit max |q|", worst_ex, " implicit max |q|", worst_im, " implicit final", im.q[0])
    s.check(worst_ex > 1e3, "explicit PD of stiffness 1e5 diverges at dt = 1/60")
    s.check(worst_im <= 0.1 and abs(im.q[0]) < 0.01, "implicit spring stays within its start and decays")

    # ---- armature: pendulum period ---------------------------------------
    var ar = _one()
    var hang = Real(-pi / 2)
    ar.q[0] = hang + 0.05
    ar.set_joint_props(0, armature=0.5)
    var h = Real(1.0 / 1000.0)
    var prev = ar.q[0] - hang
    var cross_t = List[Real]()
    for n in range(6000):
        ar.step_implicit(h, [Real(0)], G)
        var cur = ar.q[0] - hang
        if prev > 0 and cur <= 0:
            cross_t.append(Real(n + 1) * h - h * cur / (cur - prev))
        prev = cur
    var period = (cross_t[len(cross_t) - 1] - cross_t[0]) / Real(len(cross_t) - 1)
    var want_t = Real(2 * pi) * sqrt((inertia + 0.5) / (1 * 9.8 * 0.5))
    print("  armature 0.5: period", period, " analytic", want_t)
    s.check(abs(period - want_t) < 0.01 * want_t, "armature lengthens the period to 2 pi sqrt((I + Ia) / (m g l)) (1 %)")

    # ---- damping: exact backward-Euler factor ----------------------------
    var dm = _one()
    dm.qd[0] = 1
    var b = Real(0.52)
    dm.set_joint_props(0, damping=b)
    for _ in range(60):
        dm.step_implicit(DT, [Real(0)], ZERO)
    var disc = (inertia / (inertia + b * DT)) ** 60
    print("  damping 0.52: speed after 1 s", dm.qd[0], " backward Euler", disc, " e^-2", exp(Real(-2)))
    s.check(abs(dm.qd[0] - disc) < 1e-4 * disc, "damping: speed x I / (I + b dt) per step")
    s.check(abs(dm.qd[0] - exp(Real(-2))) < 0.04 * exp(Real(-2)), "within 4 % of e^(-b t / I)")

    # ---- spring vs gravity equilibrium ------------------------------------
    var sp = _one()
    sp.set_joint_props(0, stiffness=50, damping=2)
    for _ in range(600):
        sp.step_implicit(DT, [Real(0)], G)
    var qe = Real(0)
    for _ in range(30):  # Newton on 50 q + 4.9 cos q = 0
        qe -= (50 * qe + 4.9 * cos(qe)) / (50 - 4.9 * sin(qe))
    print("  spring 50 vs gravity: settles at", sp.q[0], " root of k q = -m g l cos q", qe)
    s.check(abs(sp.q[0] - qe) < 1e-4, "spring and gravity balance at the analytic angle")

    # ---- friction ----------------------------------------------------------
    var fr = _one()
    fr.qd[0] = 2
    fr.set_joint_props(0, friction=0.26)
    var t_stop = Real(-1)
    var held = True
    for n in range(240):
        fr.step_implicit(DT, [Real(0)], ZERO)
        if fr.qd[0] == 0 and t_stop < 0:
            t_stop = Real(n + 1) * DT
        if t_stop >= 0 and fr.qd[0] != 0:
            held = False
    print("  friction 0.26 N m from 2 rad/s: stopped at", t_stop, "s  (I w / f = 2)")
    s.check(abs(t_stop - 2) < 2 * DT and held, "Coulomb friction stops it at I w / f and holds it")

    # ---- snapshot round trip -----------------------------------------------
    var c3 = Chain()
    c3.add_link(_link())
    c3.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(1, 0, 0, 0), Vec3(0.5, 0, 0, 0), 1, Vec3(0.01, 0.01, 0.01, 0)))
    c3.add_link(ChainLink.revolute(Vec3(1, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(0.3, 0, 0, 0), 0.5, Vec3(0.01, 0.01, 0.01, 0)))
    for i in range(3):
        c3.set_joint_props(i, Real(0.3) * Real(i + 1), Real(20), Real(0.1), Real(0.05), Real(0.02))
    var tz: List[Real] = [0, 0, 0]
    for _ in range(30):
        c3.step_implicit(DT, tz, G)
    var w = BinWriter()
    write_chain(c3, w)
    var rd = BinReader(w.b.copy())
    var r3 = read_chain(rd)
    for _ in range(60):
        c3.step_implicit(DT, tz, G)
        r3.step_implicit(DT, tz, G)
    var same = True
    for i in range(3):
        if c3.q[i] != r3.q[i] or c3.qd[i] != r3.qd[i]:
            same = False
    s.check(same, "chain snapshot: restored mid-run, next 60 steps bit-identical")

    # ---- parity and extremes ------------------------------------------------
    var pa = Chain()
    var pb = Chain()
    for c in range(3):
        var l = ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(1, 0, 0, 0) if c > 0 else ZERO, Vec3(0.5, 0, 0, 0), 1, Vec3(0.01, 0.01, 0.01, 0))
        pa.add_link(l)
        pb.add_link(l)
    var worst = Real(0)
    for _ in range(60):
        pa.step(DT, tz, G)
        pb.step_implicit(DT, tz, G)
        for i in range(3):
            worst = max(worst, abs(pa.q[i] - pb.q[i]))
    print("  all properties zero: step vs step_implicit worst |dq|", worst)
    s.check(worst < 1e-4, "all properties zero: step_implicit tracks step (1e-4)")
    var raised = False
    try:
        pa.set_joint_props(0, damping=-1)
    except:
        raised = True
    s.check(raised, "negative damping raises")
    s.finish()
