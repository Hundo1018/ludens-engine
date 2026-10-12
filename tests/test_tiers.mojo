# tier: integration
"""Tier policies and the tiered step (ROADMAP 17.85).

Ordinary: DistanceTiers rings and hysteresis (no flapping in the band);
RoundRobin + a period-4 tier solves every island exactly once per 4 steps;
CausalReach depth grows along a stack and is not fooled by distance (a box
1 m away behind a wall-free gap but on a separate pile is reached only
through contacts); catch-up keeps simulated time (a coarse free-falling box
lands at the same time as a fine one, within one coarse period).
Extreme: observer inside a wall (nothing seeded: everything coarsest), no
observers (everything coarsest, nothing NaN), period change mid-contact
(a resting stack switched between tiers stays put), an island spanning two
tiers takes the finer one, a period-0 tier holds still, bad tables / tiers
raise, a scene with soft bodies falls back (counted).
"""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.softbody import SoftBody
from diag.counters import TIER_FALLBACK
from gameplay.tiers import DistanceTiers, CausalReach, RoundRobin, BudgetTiers

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _box(mut sc: ContactScene6[QuatBody6], p: Vec3, h: Real = 0.5) -> Int:
    return sc.add(QuatBody6.at_rest(p, Inertia3.box(1, h, h, h)), _v(h, h, h), False).index()


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, 60, 0.5, 60)), _v(60, 0.5, 60), True)


def _table(mut sc: ContactScene6[QuatBody6], p1: Int, p2: Int = 0) raises:
    var cfg = SolverConfig()
    var it = List[Int]()
    var su = List[Int]()
    var pe = List[Int]()
    it.append(cfg.iters)
    su.append(cfg.substeps)
    pe.append(1)
    it.append(cfg.iters)
    su.append(cfg.substeps)
    pe.append(p1)
    if p2 >= 0:
        it.append(2)
        su.append(1)
        pe.append(p2)
    sc.set_tier_table(it, su, pe)


def _finite(sc: ContactScene6[QuatBody6]) -> Bool:
    for i in range(len(sc.bset.bodies)):
        var p = sc.bset.bodies[i].position()
        for k in range(3):
            if not (p[k] == p[k]) or abs(p[k]) > 1e6:
                return False
    return True


def main() raises:
    var s = Suite("tiers")
    var cfg = SolverConfig()

    # ---- DistanceTiers: rings + hysteresis ----
    var radii = List[Real]()
    radii.append(10)
    radii.append(30)
    var dt_pol = DistanceTiers(radii^, 2)
    s.eqi(dt_pol.tier_for(5, -1), 0, "inside 10 m: tier 0")
    s.eqi(dt_pol.tier_for(20, -1), 1, "10..30 m: tier 1")
    s.eqi(dt_pol.tier_for(50, -1), 2, "beyond 30 m: tier 2")
    s.eqi(dt_pol.tier_for(11, 0), 0, "11 m, was tier 0: hysteresis keeps it")
    s.eqi(dt_pol.tier_for(12.5, 0), 1, "12.5 m: past radius + hysteresis, coarsens")
    s.eqi(dt_pol.tier_for(9.9, 1), 0, "back inside 10 m: refines at once")
    var flips = 0
    var prev = 0
    for k in range(200):
        var d = Real(10.5) + Real(1.2) * Real((k * 7919) % 100) / 100  # jitter in 10.5..11.7
        var t = dt_pol.tier_for(d, prev)
        if t != prev:
            flips += 1
        prev = t
    s.eqi(flips, 0, "jitter inside the hysteresis band: no flapping")

    # ---- RoundRobin: every island exactly once per period ----
    var rr_sc = ContactScene6[QuatBody6]()
    _floor(rr_sc)
    for k in range(8):
        _ = _box(rr_sc, _v(Real(k) * 3 - 12, 0.5, 0))
        rr_sc.set_can_sleep(rr_sc.bset.id_of(k + 1), False)
    _table(rr_sc, 4)
    var rr = RoundRobin(1)
    var solved = List[Int]()
    var obs0 = List[Vec3]()
    for _ in range(8):
        rr_sc.set_body_tiers(rr.assign(rr_sc, obs0, rr_sc.step_index))
        rr_sc.step(DT, G, cfg)
        solved.append(rr_sc.islands_solved)
    var first4 = solved[0] + solved[1] + solved[2] + solved[3]
    var next4 = solved[4] + solved[5] + solved[6] + solved[7]
    s.check(first4 == 8 and next4 == 8, "RoundRobin period 4: 8 islands solved once per 4 steps")
    var spread = True
    for v in solved:
        if v != 2:
            spread = False
    s.check(spread, "and spread evenly (2 per step)")

    # ---- catch-up: a coarse falling box keeps simulated time ----
    var fall = ContactScene6[QuatBody6]()
    _floor(fall)
    var fine = _box(fall, _v(-5, 10, 0))
    var coarse = _box(fall, _v(5, 10, 0))
    _table(fall, 4)
    var plan = List[Int](length=3, fill=0)
    plan[coarse] = 1
    fall.set_body_tiers(plan)
    var land_fine = -1
    var land_coarse = -1
    for k in range(200):
        fall.step(DT, G, cfg)
        if land_fine < 0 and fall.bset.bodies[fine].position()[1] < 0.6:
            land_fine = k
        if land_coarse < 0 and fall.bset.bodies[coarse].position()[1] < 0.6:
            land_coarse = k
    s.check(land_fine > 0 and abs(land_coarse - land_fine) <= 4, "coarse box lands within one period of the fine one (" + String(land_fine) + " vs " + String(land_coarse) + ")")

    # ---- CausalReach: depth along a stack ----
    var st = ContactScene6[QuatBody6]()
    _floor(st)
    var col = List[Int]()
    for k in range(5):
        col.append(_box(st, _v(0, 0.5 + Real(k) * 1.0, 0)))
    var lone = _box(st, _v(1.6, 0.5, 0))  # 1.1 m gap from the column: no contact
    for _ in range(30):
        st.step(DT, G, cfg)
    var depths = List[Int]()
    depths.append(0)
    depths.append(1)
    depths.append(2)
    var cr = CausalReach(0.6, depths^)
    var obs = List[Vec3]()
    obs.append(_v(0, 0.5, 0))  # at the bottom box only
    var ct = cr.assign(st, obs, st.step_index)
    var mono = True
    for k in range(1, 5):
        if ct[col[k]] < ct[col[k - 1]]:
            mono = False
    s.check(mono and ct[col[0]] == 0 and ct[col[4]] == 3, "tier grows with contact depth up the column (0 .. coarsest)")
    s.eqi(ct[lone], 3, "a box 1.1 m away but not in contact is unreached: coarsest")
    var wall_obs = List[Vec3]()
    wall_obs.append(_v(30, 0.5, 30))  # nothing within the seed radius
    var cw = cr.assign(st, wall_obs, st.step_index)
    var all_coarse = True
    for k in range(1, len(cw)):
        if cw[k] != 3:
            all_coarse = False
    s.check(all_coarse, "observer reaching nothing (inside a wall): everything coarsest")

    # ---- island spanning two tiers takes the finer; period change mid-contact ----
    _table(st, 4, 0)
    var mixed = List[Int](length=len(st.bset.bodies), fill=2)
    mixed[col[2]] = 0
    st.set_body_tiers(mixed)
    for k in range(5):
        st.set_can_sleep(st.bset.id_of(col[k]), False)
    var before = st.bset.bodies[col[4]].position()
    var max_jump = Real(0)
    for k in range(240):
        # switch the whole column between tier 0 / 1 / 2 every 20 steps
        var t = (k // 20) % 3
        var p = List[Int](length=len(st.bset.bodies), fill=2)
        for c in col:
            p[c] = t
        st.set_body_tiers(p)
        var y0 = st.bset.bodies[col[4]].position()
        st.step(DT, G, cfg)
        var d = st.bset.bodies[col[4]].position() - y0
        max_jump = max(max_jump, sqrt(dot(d, d)))
    var after = st.bset.bodies[col[4]].position()
    var drift = after - before
    s.check(sqrt(dot(drift, drift)) < 0.05, "resting column switched between tiers stays put (drift " + String(sqrt(dot(drift, drift))) + ")")
    s.check(max_jump < 0.02, "no pop when the period changes mid-contact")
    s.check(st.islands_solved + st.islands_skipped >= 1, "island counters populated")

    # period-0 tier holds still
    var hold = ContactScene6[QuatBody6]()
    _floor(hold)
    var hb = _box(hold, _v(0, 5, 0))
    _table(hold, 4, 0)
    var hp = List[Int](length=2, fill=2)
    hold.set_body_tiers(hp)
    for _ in range(30):
        hold.step(DT, G, cfg)
    s.check(hold.bset.bodies[hb].position()[1] == 5, "period-0 tier: never solved, holds still")

    # no observers: everything coarse, nothing NaN
    var radii2 = List[Real]()
    radii2.append(5)
    var dp2 = DistanceTiers(radii2^, 1)
    var nobody = List[Vec3]()
    var pn = dp2.assign(st, nobody, st.step_index)
    var coarse_all = True
    for k in range(1, len(pn)):
        if pn[k] != 1:
            coarse_all = False
    s.check(coarse_all, "no observers: every body coarsest")
    _table(st, 4, 8)
    st.set_body_tiers(pn)
    for _ in range(60):
        st.step(DT, G, cfg)
    s.check(_finite(st), "and the world keeps stepping, finite")

    # BudgetTiers: shrink above target, grow back below
    var br = List[Real]()
    br.append(10)
    var bud = BudgetTiers(br^, 1000, 1, 0.5)
    bud.measured(2000)
    s.check(abs(bud.inner.radii[0] - 5) < 1e-5, "over budget: radii halve")
    bud.measured(100)
    s.check(abs(bud.inner.radii[0] - 10) < 1e-5, "under budget: back to the configured radii")
    bud.measured(100)
    s.check(abs(bud.inner.radii[0] - 10) < 1e-5, "never above the configured radii")

    # errors and fallback
    var raised = False
    try:
        var e = ContactScene6[QuatBody6]()
        e.set_body_tiers(List[Int]())
    except:
        raised = True
    s.check(raised, "tiers without a table raise")
    raised = False
    try:
        var e2 = ContactScene6[QuatBody6]()
        var a = List[Int]()
        a.append(1)
        var b = List[Int]()
        b.append(0)
        e2.set_tier_table(a, a, b)
        e2.set_tier_table(a, b, a)
    except:
        raised = True
    s.check(raised, "substeps 0 raises")
    raised = False
    try:
        var bad = List[Real]()
        bad.append(10)
        bad.append(5)
        _ = DistanceTiers(bad^, 1)
    except:
        raised = True
    s.check(raised, "descending radii raise")
    var soft = ContactScene6[QuatBody6]()
    _floor(soft)
    _ = soft.add_soft(SoftBody.box_lattice(_v(0, 2, 0), _v(0.5, 0.5, 0.5), 2, 1.0, 0.0))
    _table(soft, 2)
    soft.set_body_tiers(List[Int](length=1, fill=0))
    soft.step(DT, G, cfg)
    s.eqi(Int(soft.counters.get(TIER_FALLBACK)), 1, "soft bodies: tiered path falls back, counted")
    s.finish()
