# tier: integration
"""Solver stress cases (ROADMAP 17.19).

The solver had only been checked on stacks up to 6 boxes. These are the
cases the ROADMAP item lists, each with the measured quantity printed:

  1. Mass ratio: 100, 1000 and 10000 kg boxes resting on a 1 kg box on the
     floor for 5 s. The overlap follows the soft-contact sag law
     M g / (m_eff w^2) (a soft contact is a spring of stiffness m_eff w^2):
     3 cm at 1:100, and at 1:1000 the light box is crushed into the floor.
     That is the current limit, asserted so a fix shows up here; raising
     the contact hertz globally does not fix it (above 240 Hz the heavy box
     passes through, measured).
     With `max_mass_ratio = 10` (in contact and joint rows each body acts
     with at least 1/10 of the heaviest body of its contact / joint group):
     1:1000 and 1:1e4 sink 3 mm (R g / w^2, independent of the ratio); a
     1000 / 1 / 1 kg tower's worst overlap is under 1 cm; the price,
     measured: the floor's force under 1000 kg on 1 kg reads (M + M / R) g
     instead of (M + m) g. A ratio below 1 is rejected by `validated`.
  2. Long chain under load: 20 ball-jointed links holding a 100 kg weight
     (100:1 against a link) for 5 s - the chain's stretch, and with
     `max_mass_ratio = 10` under 3 %.
  3. One island of 1000 boxes (a 10 x 10 x 10 block resting on the floor)
     for 300 steps - worst overlap, energy kept bounded, all finite.
  4. Dominoes: 60 tiles, the first pushed - every tile falls.
  5. Teleport into a stack: a box placed overlapping the middle of a
     resting 6-box stack by 10 cm - separated within 1 s with no body
     faster than 5 m/s.
  6. Degenerate: two boxes at the same position separate, finite.
"""

from std.math import isfinite, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from geometry.quat import Quat
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.solver_config import SolverConfig
from physics.body_set import BodyId

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)


def _floor_force(heavy: Real, ratio: Real) raises -> Real:
    """The floor's contact force on the light box after 1 s (N, upward;
    true value (M + m) g); sleeping off so the solve runs."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    cfg.lin_sleep_tol = 0
    cfg.ang_sleep_tol = 0
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var l = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(heavy, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(60):
        sc.step(DT, G, cfg)
    var f = Real(0)
    for r in sc.contacts_of(l):
        if r.other == 0:
            f += r.force[1]
    return f


def _heavy_on_light(heavy: Real, ratio: Real = 0) raises -> Tuple[Real, Real, Real]:
    """Returns (light box floor penetration, light/heavy overlap, max
    horizontal drift) over 5 s; `ratio` > 0 steps with that
    `max_mass_ratio`, otherwise `step_soft`'s defaults."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var l = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var h = sc.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(heavy, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var pen = Real(0)
    var ov = Real(0)
    var drift = Real(0)
    for _ in range(300):
        if ratio > 0:
            sc.step(DT, G, cfg)
        else:
            sc.step_soft(DT, G)
        var yl = sc.pose(l).pos[1]
        var yh = sc.pose(h).pos[1]
        pen = max(pen, 0.25 - yl)
        ov = max(ov, 0.5 - (yh - yl))
        drift = max(drift, max(abs(sc.pose(h).pos[0]), abs(sc.pose(l).pos[0])))
    return (pen, ov, drift)


def _tower(ratio: Real) raises -> Tuple[Real, Real]:
    """1000 kg on 1 kg on 1 kg for 5 s: (worst overlap of any contact, top
    box height drop from rest)."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var ids = List[BodyId]()
    var masses: List[Real] = [1, 1, 1000]
    for k in range(3):
        ids.append(sc.add(QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(k), 0, 0), Inertia3.box(masses[k], 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False))
    var ov = Real(0)
    for _ in range(300):
        sc.step(DT, G, cfg)
        var prev = Real(-0.25)  # the floor's top seen as a box centre
        for k in range(3):
            var y = sc.pose(ids[k]).pos[1]
            ov = max(ov, 0.5 - (y - prev))
            prev = y
    return (ov, 1.25 - sc.pose(ids[2]).pos[1])


def _chain(ratio: Real) raises -> Real:
    """20 ball-jointed 1 kg links holding 100 kg for 5 s: anchor-to-weight length."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    var ch = ContactScene6[QuatBody6]()
    var anchor = ch.add(QuatBody6.at_rest(Vec3(0, 20, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var prev = anchor.index()
    for k in range(20):
        var b = ch.add(QuatBody6.at_rest(Vec3(0, 20 - 0.5 * Real(k + 1), 0, 0), Inertia3.box(1, 0.05, 0.25, 0.05)), Vec3(0.05, 0.2, 0.05, 0), False)
        _ = ch.add_joint(Joint6.ball(prev, b.index(), Vec3(0, Real(-0.25) if k > 0 else Real(-0.1), 0, 0), Vec3(0, 0.25, 0, 0)))
        prev = b.index()
    var w = ch.add(QuatBody6.at_rest(Vec3(0, 20 - 0.5 * 21, 0, 0), Inertia3.box(100, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    _ = ch.add_joint(Joint6.ball(prev, w.index(), Vec3(0, -0.25, 0, 0), Vec3(0, 0.2, 0, 0)))
    for _ in range(300):
        if ratio > 0:
            ch.step(DT, G, cfg)
        else:
            ch.step_soft(DT, G)
    return 20 - ch.pose(w).pos[1]


def main() raises:
    var s = Suite("solver_stress")

    # ---- mass ratios ------------------------------------------------------------------------------
    var r2 = _heavy_on_light(100)
    var r3 = _heavy_on_light(1000)
    var r4 = _heavy_on_light(10000)
    # soft contact sag law: a contact is a spring of stiffness m_eff w^2
    # (w = 2 pi 30 Hz), so a load M g compresses it by M g / (m_eff w^2)
    var k = Real(1) * (2 * 3.14159265 * 30) * (2 * 3.14159265 * 30)
    var law2 = Real(100 * 9.8) / k
    var law3 = Real(1000 * 9.8) / k
    print("  1:100   light box floor penetration", r2[0], " overlap with heavy", r2[1], " drift", r2[2], " sag law", law2)
    print("  1:1000  light box floor penetration", r3[0], " overlap with heavy", r3[1], " drift", r3[2], " sag law", law3)
    print("  1:1e4   light box floor penetration", r4[0], " overlap with heavy", r4[1], " drift", r4[2])
    s.check(abs(r2[1] / law2 - 1) < 0.1 and abs(r3[1] / law3 - 1) < 0.1, "heavy-on-light sag follows M g / (m_eff w^2) (1:100 and 1:1000)")
    s.check(r3[0] > 0.2 and isfinite(r4[1]), "1:1000 crushes the light box into the floor (current limit of the soft contact; finite at 1:1e4)")

    var m3 = _heavy_on_light(1000, 10)
    var m4 = _heavy_on_light(10000, 10)
    var t0 = _tower(0)
    var t1 = _tower(10)
    print("  max_mass_ratio 10:  1:1000 penetration", m3[0], " overlap", m3[1], " drift", m3[2], "   1:1e4 penetration", m4[0], " overlap", m4[1])
    var f0 = _floor_force(1000, 0)
    var f1 = _floor_force(1000, 10)
    print("  floor force under 1000 kg on 1 kg (true 9809.8 N): off", f0, " ratio 10", f1)
    print("  1000 / 1 / 1 tower: worst overlap off", t0[0], " ratio 10", t1[0], "  top drop off", t0[1], " ratio 10", t1[1])
    var bad = SolverConfig()
    bad.max_mass_ratio = 0.5
    var rejected = False
    try:
        _ = bad.validated()
    except:
        rejected = True
    s.check(m3[0] < 0.01 and m3[1] < 0.01 and m4[0] < 0.01 and m4[1] < 0.01 and t1[0] < 0.01, "max_mass_ratio 10: 1:1000 and 1:1e4 sink < 1 cm, 3-box tower < 1 cm")
    s.check(abs(f1 / (1100 * 9.8) - 1) < 0.01 and rejected, "the price: floor force reads (M + M/R) g; ratio < 1 rejected")

    # ---- loaded chain -------------------------------------------------------------------------------
    var rest_len = Real(0.1 + 20 * 0.5 + 0.2)
    var got_len = _chain(0)
    var got_r = _chain(10)
    print("  20-link chain + 100 kg: length", got_len, " rest", rest_len, " stretch", (got_len - rest_len) / rest_len * 100, "%   max_mass_ratio 10:", (got_r - rest_len) / rest_len * 100, "%")
    s.check(isfinite(got_len) and (got_len - rest_len) / rest_len < 0.15, "100:1 loaded 20-link chain: finite, stretch under 15 % (soft joints)")
    s.check((got_r - rest_len) / rest_len < 0.03, "max_mass_ratio 10: the loaded chain stretches under 3 %")

    # ---- one big island ------------------------------------------------------------------------------
    var big = ContactScene6[QuatBody6]()
    _floor(big)
    for k in range(1000):
        var i = k % 10
        var j = (k // 10) % 10
        var l2 = k // 100
        _ = big.add(QuatBody6.at_rest(Vec3(Real(i) * 0.5 - 2.25, 0.25 + Real(l2) * 0.5, Real(j) * 0.5 - 2.25, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.249, 0.249, 0.249, 0), False)
    var vmax = Real(0)
    for _ in range(300):
        big.step_soft(DT, G)
    var low = Real(1e9)
    var fin = True
    for b in range(1, len(big.bset.bodies)):
        var p = big.bset.bodies[b].pos
        if not isfinite(p[1]):
            fin = False
        low = min(low, p[1])
        vmax = max(vmax, length(big.bset.bodies[b].vel))
    print("  1000-box block, 300 steps: lowest centre", low, "(rest 0.25)  max speed", vmax, " finite", fin)
    s.check(fin and low > 0.24 and vmax < 0.01, "1000 boxes in one island: finite, bottom layer within 1 cm, settled")

    # ---- dominoes ----------------------------------------------------------------------------------------
    var dm = ContactScene6[QuatBody6]()
    _floor(dm)
    var first = 1
    for k in range(60):
        _ = dm.add(QuatBody6.at_rest(Vec3(Real(k) * 0.35 - 10, 0.5, 0, 0), Inertia3.box(1, 0.05, 0.5, 0.2)), Vec3(0.05, 0.5, 0.2, 0), False)
    dm.bset.bodies[first].vel = Vec3(0, 0, 0, 0)
    dm.apply_impulse(dm.bset.id_of(first), Vec3(0.6, 0, 0, 0), Vec3(-10, 0.95, 0, 0))
    for _ in range(900):
        dm.step_soft(DT, G)
    var fallen = 0
    for b in range(1, len(dm.bset.bodies)):
        var up = dm.bset.bodies[b].q.rotate(Vec3(0, 1, 0, 0))
        if up[1] < 0.9:
            fallen += 1
    print("  60 dominoes after 15 s: fallen", fallen)
    s.check(fallen == 60, "all 60 dominoes fall")

    # ---- teleport into a stack ------------------------------------------------------------------------
    var st = ContactScene6[QuatBody6]()
    _floor(st)
    for k in range(6):
        _ = st.add(QuatBody6.at_rest(Vec3(0, 0.25 + Real(k) * 0.5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(120):
        st.step_soft(DT, G)
    var intruder = st.add(QuatBody6.at_rest(Vec3(0.4, 1.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var sp = Real(0)
    for _ in range(60):
        st.step_soft(DT, G)
        for b in range(1, len(st.bset.bodies)):
            sp = max(sp, length(st.bset.bodies[b].vel))
    var gap = abs(st.pose(intruder).pos[0] - st.bset.bodies[3].pos[0])
    print("  box teleported 10 cm into a stack: max speed", sp, " horizontal separation after 1 s", gap)
    s.check(sp < 5 and gap > 0.45, "teleport 10 cm into a stack: pushed out within 1 s, no body above 5 m/s")

    # ---- coincident boxes ----------------------------------------------------------------------------------
    var co = ContactScene6[QuatBody6]()
    _floor(co)
    var c1 = co.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var c2 = co.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(120):
        co.step_soft(DT, G)
    var dsep = length(co.pose(c1).pos - co.pose(c2).pos)
    print("  two boxes at the same point: separation after 2 s", dsep)
    s.check(dsep > 0.45, "coincident boxes separate")
    s.finish()
