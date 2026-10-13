# tier: integration
"""Contact model variants (ROADMAP 17.50): friction cone, static vs kinetic
friction, rolling and spin resistance, per-body contact softness, adhesion.

Slopes are a flat floor under tilted gravity (angle θ, downhill direction d
in the floor plane), so the analytic slide is s = ½ g (sin θ − μ cos θ) t².

  1. Ordinary: a box sliding 1 s on a 30° slope (μ 0.3) along a tangent
     axis and along the diagonal: the elliptic cone gives the analytic
     distance both ways, the pyramid only along the axis (on the diagonal
     its cap is √2 μN, analytic ½ g (sin θ − √2 μ cos θ) t²); a ball of
     radius 0.5 rolling at 2 m/s with rolling resistance 0.05 m stops after
     7 r v0² / (10 c g); a ball spinning at 10 rad/s about the normal with
     spin resistance 0.05 m slows to ω0 − c m g t / I; static friction
     (μs 0.6, μk 0.3) holds a box at rest on a 25° slope that μk alone lets
     slide, while the same box started at 1 m/s keeps sliding at the
     kinetic rate; a box dropped on a soft pad (3 Hz) sinks deeper than on
     the default floor; adhesion of 20 N holds a 1 kg box under a ceiling
     and 5 N does not.
  2. Integration: a box at rest (landed under the pyramid) continues
     within 1e-5 m under both cones (not bit for bit: 3.1e-7 m); a ContactRule friction override replaces the
     static coefficient too; a snapshot round trip keeps the new per-body
     fields (continued runs bit-identical); invalid arguments raise;
     softness set to the step's own hertz / zeta is bit-identical to unset.
  3. Extreme: μ = 0 gives bit-identical runs under both cones; μ = 1e3
     under the elliptic cone holds the box; rolling resistance on a static
     pair's zero-mass side is a no-op (no NaN).
"""

from std.math import sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, FRICTION_PYRAMID, FRICTION_ELLIPTIC
from physics.contact6 import ContactRule, RULE_FRICTION
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime G: Real = 9.8
comptime DEG: Real = 0.017453292519943295


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 60, 0.5, 60)), Vec3(60, 0.5, 60, 0), True)


def _gravity(theta: Real, dx: Real, dz: Real) -> Vec3:
    var l = sqrt(dx * dx + dz * dz)
    var s = G * sin(theta)
    return Vec3(s * dx / l, -G * cos(theta), s * dz / l, 0)


def _cfg(mu: Real, cone: Int) -> SolverConfig:
    var c = SolverConfig()
    c.default_friction = mu
    c.friction_cone = cone
    return c


def _slide(theta: Real, dx: Real, dz: Real, mu: Real, cone: Int, steps: Int, v0: Real = 0, mu_s: Real = -1) raises -> Real:
    """Distance a 0.25-half cube slides downhill in `steps` steps."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var b = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_can_sleep(b, False)
    if mu_s >= 0:
        # both sides: an unset floor would fall back to its kinetic mu and
        # the averaged pair coefficient would be (mu_s + mu) / 2
        sc.set_static_friction(0, mu_s)
        sc.set_static_friction(b.index(), mu_s)
    var g = _gravity(theta, dx, dz)
    var cfg = _cfg(mu, cone)
    # settle onto the floor under straight-down gravity first
    for _ in range(20):
        sc.step(DT, Vec3(0, -G, 0, 0), cfg)
    var l = sqrt(dx * dx + dz * dz)
    sc.set_velocity(b, Vec3(v0 * dx / l, 0, v0 * dz / l, 0), Vec3(0, 0, 0, 0))
    var p0 = sc.pose(b).pos
    for _ in range(steps):
        sc.step(DT, g, cfg)
    var d = sc.pose(b).pos - p0
    return sqrt(d[0] * d[0] + d[2] * d[2])


def _ball(rolling: Real, spinning: Real, v0: Real, w0: Vec3, steps: Int) raises -> Tuple[Real, Real]:
    """(distance travelled, final |omega . y|) of a radius-0.5 ball."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var b = sc.add_sphere(QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    sc.set_can_sleep(b, False)
    if rolling > 0:
        sc.set_rolling_resistance(b.index(), rolling)
    if spinning > 0:
        sc.set_spinning_resistance(b.index(), spinning)
    for _ in range(10):
        sc.step_soft(DT, Vec3(0, -G, 0, 0))
    sc.set_velocity(b, Vec3(v0, 0, 0, 0), w0)
    var x0 = sc.pose(b).pos[0]
    for _ in range(steps):
        sc.step_soft(DT, Vec3(0, -G, 0, 0))
    return (sc.pose(b).pos[0] - x0, abs(sc.angular_velocity(b)[1]))


def main() raises:
    var s = Suite("contact_model")
    var th = 30 * DEG
    var mu = Real(0.3)
    var t = Real(1)
    var want = 0.5 * G * (sin(th) - mu * cos(th)) * t * t
    var want_pyr45 = 0.5 * G * (sin(th) - sqrt(Real(2)) * mu * cos(th)) * t * t
    var e0 = _slide(th, 1, 0, mu, FRICTION_ELLIPTIC, 60)
    var e45 = _slide(th, 1, 1, mu, FRICTION_ELLIPTIC, 60)
    var p0 = _slide(th, 1, 0, mu, FRICTION_PYRAMID, 60)
    var p45 = _slide(th, 1, 1, mu, FRICTION_PYRAMID, 60)
    print("  30 deg slope, mu 0.3, 1 s: analytic", want, " pyramid 45 deg analytic", want_pyr45)
    print("    elliptic: along axis", e0, " diagonal", e45, "   pyramid: along axis", p0, " diagonal", p45)
    s.check(abs(e0 - want) < 0.03 * want and abs(e45 - want) < 0.03 * want, "elliptic cone: analytic slide on the axis and on the diagonal (3 %)")
    s.check(abs(p0 - want) < 0.03 * want, "pyramid on the axis: analytic slide (3 %)")
    s.check(abs(p45 - want_pyr45) < 0.05 * want_pyr45, "pyramid on the diagonal: cap sqrt(2) mu N (5 %)")
    s.check(abs(e0 - p0) < 1e-3, "on a tangent axis the two cones agree (1 mm)")

    # ---- rolling resistance ---------------------------------------------------
    var c = Real(0.05)
    var r = Real(0.5)
    var v0 = Real(2)
    var stop = 7 * r * v0 * v0 / (10 * c * G)
    var roll = _ball(c, 0, v0, Vec3(0, 0, -v0 / r, 0), 300)
    var free = _ball(0, 0, v0, Vec3(0, 0, -v0 / r, 0), 300)
    print("  ball r 0.5 at 2 m/s, rolling resistance 0.05: stops after", roll[0], "m (analytic", stop, ")  without:", free[0], "m in 5 s")
    s.check(abs(roll[0] - stop) < 0.03 * stop, "rolling ball stops at 7 r v0^2 / (10 c g) (3 %)")
    s.check(abs(free[0] - v0 * 5) < 0.05, "without rolling resistance it keeps rolling (5 s at 2 m/s)")

    # ---- spin resistance ---------------------------------------------------
    var cs = Real(0.05)
    var w0 = Real(10)
    var inertia = Real(0.4) * r * r
    var want_w = w0 - cs * G / inertia * 1.0
    var spin = _ball(0, cs, 0, Vec3(0, w0, 0, 0), 60)
    var spin_free = _ball(0, 0, 0, Vec3(0, w0, 0, 0), 60)
    print("  ball spinning at 10 rad/s, spin resistance 0.05: omega after 1 s", spin[1], "(analytic", want_w, ")  without:", spin_free[1])
    s.check(abs(spin[1] - want_w) < 0.03 * w0, "spin decays at c m g / I (3 % of omega0)")
    s.check(abs(spin_free[1] - w0) < 1e-3, "without spin resistance the spin is kept")

    # ---- static vs kinetic ---------------------------------------------------
    var th2 = 25 * DEG
    var held = _slide(th2, 1, 0, 0.3, FRICTION_PYRAMID, 120, 0, 0.6)
    var slips = _slide(th2, 1, 0, 0.3, FRICTION_PYRAMID, 120)
    var moving = _slide(th2, 1, 0, 0.3, FRICTION_PYRAMID, 60, 1, 0.6)
    var want_k = 1.0 + 0.5 * G * (sin(th2) - 0.3 * cos(th2))
    print("  25 deg slope, mu_k 0.3: with mu_s 0.6 moved", held, " without", slips, "  started at 1 m/s:", moving, "(kinetic analytic", want_k, ")")
    s.check(held < 1e-3, "static friction holds the box (< 1 mm in 2 s)")
    s.check(slips > 1, "kinetic friction alone lets it slide (control)")
    s.check(abs(moving - want_k) < 0.03 * want_k, "a sliding box keeps the kinetic rate (3 %)")

    # ---- integration ---------------------------------------------------------
    var ra = ContactScene6[QuatBody6]()
    var rb = ContactScene6[QuatBody6]()
    _floor(ra)
    _floor(rb)
    var ia = ra.add(QuatBody6.at_rest(Vec3(0.1, 0.3, -0.2, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var ib = rb.add(QuatBody6.at_rest(Vec3(0.1, 0.3, -0.2, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    ra.set_can_sleep(ia, False)
    rb.set_can_sleep(ib, False)
    for _ in range(60):  # landing (friction may reach its cap) under one cone
        ra.step(DT, Vec3(0, -G, 0, 0), _cfg(0.5, FRICTION_PYRAMID))
        rb.step(DT, Vec3(0, -G, 0, 0), _cfg(0.5, FRICTION_PYRAMID))
    var worst_rest = Real(0)
    for _ in range(90):
        ra.step(DT, Vec3(0, -G, 0, 0), _cfg(0.5, FRICTION_PYRAMID))
        rb.step(DT, Vec3(0, -G, 0, 0), _cfg(0.5, FRICTION_ELLIPTIC))
        var dd = ra.pose(ia).pos - rb.pose(ib).pos
        worst_rest = max(worst_rest, sqrt(dot(dd, dd)))
    print("  resting box, pyramid vs elliptic: worst position gap", worst_rest)
    # not bit-identical (3.1e-7 m measured): somewhere a point's friction
    # still reaches its cap, where the two cones clamp differently
    s.check(worst_rest < 1e-5, "resting box: pyramid and elliptic within 1e-5 m")

    var ru = ContactScene6[QuatBody6]()
    _floor(ru)
    var bu = ru.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    ru.set_can_sleep(bu, False)
    ru.set_static_friction(bu.index(), 0.9)
    _ = ru.add_contact_rule(ContactRule(RULE_FRICTION, bu.index(), Vec3(0, 0, 0, 0), 0.05))
    for _ in range(10):
        ru.step(DT, Vec3(0, -G, 0, 0), _cfg(0.3, FRICTION_PYRAMID))
    var u0 = ru.pose(bu).pos
    for _ in range(60):
        ru.step(DT, _gravity(th2, 1, 0), _cfg(0.3, FRICTION_PYRAMID))
    var du = ru.pose(bu).pos - u0
    print("  rule friction 0.05 over mu_s 0.9 on 25 deg: moved", sqrt(dot(du, du)))
    s.check(sqrt(dot(du, du)) > 1, "a ContactRule friction override replaces the static coefficient too")

    var sa = ContactScene6[QuatBody6]()
    _floor(sa)
    var ba = sa.add_sphere(QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    sa.set_can_sleep(ba, False)
    sa.set_rolling_resistance(ba.index(), 0.03)
    sa.set_spinning_resistance(ba.index(), 0.02)
    sa.set_static_friction(ba.index(), 0.8)
    sa.set_velocity(ba, Vec3(1, 0, 0, 0), Vec3(0, 3, -2, 0))
    for _ in range(20):
        sa.step_soft(DT, Vec3(0, -G, 0, 0))
    var sb = scene_from_bytes(scene_to_bytes(sa))
    var snap_same = sb.bset.any_contact_model and sb.bset.rolling[ba.index()] == 0.03
    for _ in range(40):
        sa.step_soft(DT, Vec3(0, -G, 0, 0))
        sb.step_soft(DT, Vec3(0, -G, 0, 0))
        if sa.pose(ba).pos != sb.pose(ba).pos or sa.angular_velocity(ba) != sb.angular_velocity(ba):
            snap_same = False
    s.check(snap_same, "snapshot keeps static / rolling / spin fields (continued runs bit-identical)")

    var raised = 0
    try:
        sa.set_static_friction(ba.index(), -1)
    except:
        raised += 1
    try:
        sa.set_rolling_resistance(ba.index(), -0.1)
    except:
        raised += 1
    try:
        sa.set_spinning_resistance(99, 0.1)
    except:
        raised += 1
    var bad = SolverConfig()
    bad.friction_cone = 7
    try:
        _ = bad.validated()
    except:
        raised += 1
    s.check(raised == 4, "negative coefficients, bad index and unknown cone raise")

    # ---- per-body softness ------------------------------------------------------
    var pen = List[Real]()
    var traj = List[List[Real]]()
    for v in range(3):
        var sd = ContactScene6[QuatBody6]()
        _floor(sd)
        if v == 1:
            sd.set_contact_softness(0, 3, 1)  # a soft pad
        elif v == 2:
            sd.set_contact_softness(0, 30, 10)  # the step's own values
        var bd = sd.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        var lowest = Real(1e9)
        var ys = List[Real]()
        for _ in range(90):
            sd.step_soft(DT, Vec3(0, -G, 0, 0))
            lowest = min(lowest, sd.pose(bd).pos[1])
            ys.append(sd.pose(bd).pos[1])
        pen.append(0.25 - lowest)
        traj.append(ys^)
    print("  box dropped 0.5 m: peak penetration default", pen[0], " soft pad (3 Hz)", pen[1])
    s.check(pen[1] > 5 * pen[0], "a soft pad (3 Hz) lets the box sink > 5x deeper than the default floor")
    var same_soft = True
    for k in range(90):
        if traj[0][k] != traj[2][k]:
            same_soft = False
    s.check(same_soft, "softness equal to the step's hertz / zeta: bit-identical (contact-model branch on)")

    # ---- adhesion ----------------------------------------------------------------
    var drops = List[Real]()
    for force in [Real(20), Real(5)]:
        var sh = ContactScene6[QuatBody6]()
        _ = sh.add(QuatBody6.at_rest(Vec3(0, 1.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
        sh.set_adhesion(0, force)
        var bh = sh.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        sh.set_can_sleep(bh, False)
        for _ in range(120):
            sh.step_soft(DT, Vec3(0, -G, 0, 0))
        drops.append(0.75 - sh.pose(bh).pos[1])
    print("  1 kg box under a ceiling: drop in 2 s with adhesion 20 N", drops[0], " 5 N", drops[1])
    s.check(abs(drops[0]) < 0.01, "adhesion 20 N holds a 9.8 N box on the ceiling (< 1 cm)")
    s.check(drops[1] > 1, "adhesion 5 N does not (it falls)")

    # ---- extremes -------------------------------------------------------------
    var z0 = _slide(th, 1, 1, 0, FRICTION_PYRAMID, 60)
    var z1 = _slide(th, 1, 1, 0, FRICTION_ELLIPTIC, 60)
    s.check(z0 == z1, "mu 0: both cones bit-identical")
    var big = _slide(th, 1, 1, 1e3, FRICTION_ELLIPTIC, 60)
    print("  mu 0: slide", z0, "   mu 1e3 elliptic: slide", big)
    s.check(big < 1e-3, "mu 1e3 under the elliptic cone holds the box")
    var st = ContactScene6[QuatBody6]()
    _floor(st)
    st.set_rolling_resistance(0, 0.1)
    st.set_spinning_resistance(0, 0.1)
    var bt = st.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    st.set_velocity(bt, Vec3(0, 0, 0, 0), Vec3(0, 5, 0, 0))
    for _ in range(60):
        st.step_soft(DT, Vec3(0, -G, 0, 0))
    var wt = st.angular_velocity(bt)
    s.check(wt[1] == wt[1] and abs(wt[1]) < 1e-3, "resistance set on the static floor stops a spinning box, no NaN")
    s.finish()
