# tier: component  (override: exercises the physics articulated-body code alone; numerics.dense and collision are chain's internal wiring, as in test_actuator)
"""Hill-type muscle curves on `Actuator.muscle` (ROADMAP 17.57).

  1. Ordinary: with all three curves switched off (`HillParams.identity()`
     through `add_hill`) a muscle-driven arm follows the plain
     `Actuator.muscle` trajectory bit for bit over 2 s of ramped commands;
     the isometric force-length curve peaks where the fiber is at its
     optimal length and is down to exp(-0.09 / 0.45) = 0.819 at +-30 %.
  2. Integration: force-velocity: shortening at half vmax gives 1/6 of the
     isometric force, at vmax 0, lengthening approaches 1.8; passive force is
     zero at or below optimal length and rises past it with no activation; a
     Hill flexor lifting a 1 kg arm against gravity settles where
     arm * F = m g r sin(q) within 1 %.
  3. Extreme: commands outside [0, 1] are clamped (activation stays in it);
     a fiber shorter than zero gives a finite, near-zero force-length value;
     a slack muscle with no activation pulls nothing.
"""

from std.math import sin, exp, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.actuator import Actuator, ActuatorBank, HillParams

comptime INER = Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0, 0)
comptime DT: Real = 1.0 / 480.0
comptime G = Vec3(0, -9.8, 0, 0)


def _arm() -> Chain:
    var c = Chain()
    c.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, -0.5, 0, 0), 1.0, INER))
    return c^


def _flexor() -> HillParams:
    # arm 4 cm; fiber at optimal length (0.1 m) when q = 0.5 rad
    return HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10)


def main() raises:
    var s = Suite("muscle_hill")

    # ---- identity curves == plain muscle, bit for bit ----------------------------------------
    var pa = _arm()
    var ha = _arm()
    var pb = ActuatorBank()
    var hb = ActuatorBank()
    _ = pb.add(Actuator.muscle(0, 30, 0.02, 0.05))
    _ = hb.add_hill(Actuator.muscle(0, 30, 0.02, 0.05), HillParams.identity())
    var same = True
    for k in range(960):
        var u = Real(0.5) + Real(0.5) * Real(sin(Float64(k) * 0.01))
        pb.ctrl[0] = u
        hb.ctrl[0] = u
        var t1: List[Real] = [0]
        var t2: List[Real] = [0]
        pb.apply(pa.q, pa.qd, DT, t1)
        hb.apply(ha.q, ha.qd, DT, t2)
        pa.step(DT, t1, G)
        ha.step(DT, t2, G)
        if pa.q[0] != ha.q[0] or pa.qd[0] != ha.qd[0] or t1[0] != t2[0]:
            same = False
    print("  identity curves vs plain muscle after 2 s: q", pa.q[0], ha.q[0])
    s.check(same, "identity Hill curves == Actuator.muscle, bit for bit")

    # ---- isometric force-length --------------------------------------------------------------
    var bank = ActuatorBank()
    _ = bank.add_hill(Actuator.muscle(0, 100, 0.02, 0.04), _flexor())
    bank.state[0] = 1
    var h = _flexor()
    h.use_fp = False
    var best_q = Real(-9)
    var best_f = Real(-1)
    for k in range(-100, 201):
        var q = Real(k) * 0.01
        var f = Real(100) * h.fl(q)
        if f > best_f:
            best_f = f
            best_q = q
    var at30 = h.fl(0.5 - 0.3 * 0.1 / 0.04)
    print("  force-length peak at q", best_q, "(fiber = l_opt at 0.5)  fl at +30 %", at30)
    s.check(abs(best_q - 0.5) <= 0.01 and abs(best_f - 100) < 1e-3, "isometric force peaks at optimal fiber length")
    s.check(abs(at30 - Real(exp(-0.09 / 0.45))) < 1e-4, "fl(0.7) = exp(-0.09 / 0.45)")

    # ---- force-velocity and passive ----------------------------------------------------------
    var v_half = h.fv(0.5 * 10 * 0.1 / 0.04)  # shortening at vmax / 2
    var v_max = h.fv(10 * 0.1 / 0.04)
    var v_len = h.fv(-50 * 10 * 0.1 / 0.04)  # fast lengthening
    print("  force-velocity: half vmax", v_half, " vmax", v_max, " fast lengthening", v_len)
    s.check(abs(v_half - Real(1.0 / 6.0)) < 1e-5 and v_max == 0 and v_len > 1.75 and v_len < 1.8, "fv: 1/6 at vmax/2, 0 at vmax, -> 1.8 lengthening")
    var hp = _flexor()
    var p_opt = hp.fp(0.5)
    var p_short = hp.fp(1.0)
    var p_long = hp.fp(0.5 - 0.6 * 0.1 / 0.04)
    var pass_bank = ActuatorBank()
    _ = pass_bank.add_hill(Actuator.muscle(0, 100, 0.02, 0.04), _flexor())
    var pt: List[Real] = [0]
    var qs: List[Real] = [-1.0]
    var qds: List[Real] = [0]
    pass_bank.apply(qs, qds, DT, pt)
    print("  passive: at l_opt", p_opt, " shortened", p_short, " +60 %", p_long, "  torque at q=-1 with no activation", pt[0])
    s.check(p_opt == 0 and p_short == 0 and abs(p_long - 1) < 1e-5 and pt[0] > 0, "passive force: 0 up to l_opt, f_peak at +e0, pulls with no activation")

    # ---- static equilibrium against gravity --------------------------------------------------------
    var arm = _arm()
    var mb = ActuatorBank()
    _ = mb.add_hill(Actuator.muscle(0, 400, 0.02, 0.04), _flexor())
    mb.ctrl[0] = 0.5
    for _ in range(4800):
        var t: List[Real] = [0]
        mb.apply(arm.q, arm.qd, DT, t)
        var damp: List[Real] = [t[0] - 0.5 * arm.qd[0]]
        arm.step(DT, damp, G)
    var fm = mb.muscle_force(0, arm.q[0], 0)
    var lhs = Real(0.04) * fm
    var rhs = Real(9.8 * 0.5) * Real(sin(Float64(arm.q[0])))
    print("  hill flexor at activation 0.5: q", arm.q[0], " arm * F", lhs, " m g r sin q", rhs, " qd", arm.qd[0])
    s.check(abs(lhs - rhs) <= 0.01 * rhs and abs(arm.qd[0]) < 1e-3, "static equilibrium: muscle torque balances gravity within 1 %")

    # ---- extremes ---------------------------------------------------------------------------------
    var xb = ActuatorBank()
    _ = xb.add_hill(Actuator.muscle(0, 100, 0.02, 0.04), _flexor())
    xb.ctrl[0] = 7
    var xt: List[Real] = [0]
    var q0: List[Real] = [0.5]
    for _ in range(200):
        xt[0] = 0
        xb.apply(q0, qds, DT, xt)
    s.check(xb.state[0] <= 1 and xt[0] <= 100 * 0.04 + 1e-4, "command 7 is clamped: activation <= 1")
    var gone = h.fl(9.0)  # fiber length 0.32 - 0.36 - 0.2 < 0
    s.check(isfinite(gone) and gone < 1e-6, "negative fiber length: force-length finite, ~0")
    var slack = ActuatorBank()
    _ = slack.add_hill(Actuator.muscle(0, 100, 0.02, 0.04), _flexor())
    var st: List[Real] = [0]
    var q1: List[Real] = [1.5]
    slack.apply(q1, qds, DT, st)
    s.check(st[0] == 0, "slack muscle, no activation: no force")
    s.finish()
