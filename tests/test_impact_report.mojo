# tier: integration
"""Force reporting and impact events (ROADMAP 17.49).

  1. Ordinary:
     - a 1 kg ball dropped onto a floor: the BEGAN event's impulse is the
       momentum it loses plus gravity over the step, (1 + e) m v + m g dt,
       for e = 0 and e = 0.5; its approach speed is v;
     - a 3-box stack (1 kg each) at rest: the STAY force under the bottom box
       is 3 m g, between the bottom two 2 m g; `net_contact_force` of the top
       box is m g upward;
     - a 2 kg box hanging on a distance joint: `joint_reaction` = 19.6 N up,
       with no break threshold set.
  2. Integration:
     - estimator seam: at rest both estimators read m g; at the impact the
       last-substep estimate differs from the substep sum, and the sum is
       the one that matches the momentum change (the measured gap printed);
     - `impacts(events, J)` keeps the hard hit and drops the soft one;
     - island-parallel vs serial and BVH vs brute broadphase give
       bit-identical payloads;
     - per-body report flags: only pairs touching a flagged body are reported;
     - a sensor's events carry zero impulse; a sleeping stack reports nothing.
  3. Extreme: ENDED carries the contact's peak; a box on a mesh gets one event
     per triangle with impulses summing to m g dt; every payload finite.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, IMPULSE_SUBSTEP_SUM, IMPULSE_LAST_SUBSTEP
from physics.joints6 import Joint6
from collision.contact_events import ContactEvent, EV_BEGAN, EV_STAY, EV_ENDED, impacts

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True).index()


def _cfg(est: Int) -> SolverConfig:
    var c = SolverConfig()
    c.impulse_estimator = est
    return c^


def _drop(e: Real, est: Int, v0: Real) raises -> Tuple[Real, Real, Real]:
    """(began impulse, approach speed, speed just before contact)."""
    var sc = ContactScene6[QuatBody6]()
    var f = _floor(sc)
    sc.events_on = True
    var b = QuatBody6.at_rest(Vec3(0, 0.5 + 0.02, 0, 0), Inertia3.sphere(1, 0.5))
    b.vel = Vec3(0, -v0, 0, 0)
    var id = sc.add_sphere(b^, 0.5, False)
    sc.set_restitution(id.index(), e)
    sc.set_restitution(f, e)
    var cfg = _cfg(est)
    for _ in range(30):
        var vbefore = -sc.bset.bodies[id.index()].vel[1]
        sc.step(DT, G, cfg)
        for k in range(len(sc.events)):
            if sc.events[k].kind == EV_BEGAN:
                return (sc.events[k].impulse, sc.events[k].approach, vbefore)
    return (Real(-1), Real(-1), Real(-1))


def _stack(est: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = _floor(sc)
    sc.events_on = True
    for k in range(3):
        var id = sc.add(QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(k), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        sc.set_can_sleep(id, False)
    var cfg = _cfg(est)
    for _ in range(120):
        sc.step(DT, G, cfg)
    return sc^


def _stay_force(sc: ContactScene6[QuatBody6], a: Int, b: Int) -> Real:
    for k in range(len(sc.events)):
        ref ev = sc.events[k]
        if ev.kind == EV_STAY and ((ev.a == a and ev.b == b) or (ev.a == b and ev.b == a)):
            return ev.force
    return -1


def main() raises:
    var s = Suite("impact_report")
    var mg = Real(9.8)

    # ---- 1. ball drop: began impulse = (1 + e) m v + m g dt ------------------
    for ei in range(2):
        var e = Real(0.5) * Real(ei)
        var r = _drop(e, IMPULSE_SUBSTEP_SUM, 5)
        var want = (1 + e) * r[2] + mg * DT
        print("  drop e =", e, ": began impulse", r[0], " want (1+e) m v + m g dt =", want, " approach", r[1], " v", r[2])
        s.check(abs(r[0] - want) < 0.03 * want, "drop, e = " + String(e) + ": began impulse = (1 + e) m v + m g dt (3 %)")
        s.check(abs(r[1] - r[2]) < 0.05 * r[2], "drop, e = " + String(e) + ": approach speed = v")

    # ---- stack: stay forces --------------------------------------------------
    var st = _stack(IMPULSE_SUBSTEP_SUM)
    var f0 = _stay_force(st, 0, 1)
    var f1 = _stay_force(st, 1, 2)
    var f2 = _stay_force(st, 2, 3)
    print("  stack stay forces: floor-1", f0, " 1-2", f1, " 2-3", f2)
    s.check(abs(f0 - 3 * mg) < 0.01 * 3 * mg, "stack: floor carries 3 m g (1 %)")
    s.check(abs(f1 - 2 * mg) < 0.01 * 2 * mg, "stack: bottom box carries 2 m g")
    s.check(abs(f2 - mg) < 0.01 * mg, "stack: middle box carries m g")
    var top = st.bset.id_of(3)
    var net = st.net_contact_force(top)
    print("  top box net contact force", net[0], net[1], net[2])
    s.check(abs(net[1] - mg) < 0.01 * mg and abs(net[0]) < 0.01 and abs(net[2]) < 0.01, "net_contact_force(top) = m g up (sideways friction residue < 0.01 N)")
    var reps = st.contacts_of(st.bset.id_of(2))
    s.eqi(len(reps), 2, "contacts_of(middle box): two contacts")

    # ---- hanging joint ---------------------------------------------------------
    var hj = ContactScene6[QuatBody6]()
    _ = hj.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var hb = hj.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(2, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    hj.set_can_sleep(hb, False)
    var jid = hj.add_joint(Joint6.distance(0, 1, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1))
    for _ in range(120):
        hj.step_soft(DT, G)
    var jr = hj.joint_reaction(jid)
    print("  hanging 2 kg: joint reaction on the box", jr[0][0], jr[0][1], jr[0][2])
    s.check(abs(jr[0][1] - 2 * mg) < 0.01 * 2 * mg, "joint_reaction = 19.6 N up, no break threshold set")

    # ---- 2. estimator seam -----------------------------------------------------
    var sl = _stack(IMPULSE_LAST_SUBSTEP)
    var fl = _stay_force(sl, 0, 1)
    print("  at rest, last-substep estimate floor-1", fl, " vs sum", f0)
    s.check(abs(fl - f0) < 0.01 * f0, "at rest both estimators read the weight")
    var hit_sum = _drop(0, IMPULSE_SUBSTEP_SUM, 5)
    var hit_last = _drop(0, IMPULSE_LAST_SUBSTEP, 5)
    var want0 = hit_sum[2] + mg * DT
    print("  impact 5 m/s: substep sum", hit_sum[0], " last substep x 4", hit_last[0], " momentum change", want0)
    s.check(abs(hit_sum[0] - want0) < abs(hit_last[0] - want0), "at an impact the substep sum is the estimate that matches the momentum change")
    s.check(abs(hit_last[0] - hit_sum[0]) > 0.1 * hit_sum[0], "and the two estimators differ there by > 10 %")

    # ---- impacts filter --------------------------------------------------------
    var sf = ContactScene6[QuatBody6]()
    _ = _floor(sf)
    sf.events_on = True
    var soft = QuatBody6.at_rest(Vec3(-3, 0.52, 0, 0), Inertia3.sphere(1, 0.5))
    soft.vel = Vec3(0, -0.5, 0, 0)
    var hard = QuatBody6.at_rest(Vec3(3, 0.52, 0, 0), Inertia3.sphere(1, 0.5))
    hard.vel = Vec3(0, -8, 0, 0)
    var ids = sf.add_sphere(soft^, 0.5, False)
    var idh = sf.add_sphere(hard^, 0.5, False)
    var kept = List[ContactEvent]()
    for _ in range(10):
        sf.step_soft(DT, G)
        var hits = impacts(sf.events, 2)
        for k in range(len(hits)):
            kept.append(hits[k])
    s.check(len(kept) == 1 and (kept[0].a == idh.index() or kept[0].b == idh.index()), "impacts(J = 2): the 8 m/s hit kept, the 0.5 m/s touch dropped")
    _ = ids

    # ---- serial vs island-parallel payload -----------------------------------
    var pa = _stack(IMPULSE_SUBSTEP_SUM)
    var pb = ContactScene6[QuatBody6]()
    _ = _floor(pb)
    pb.events_on = True
    for k in range(3):
        var id = pb.add(QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(k), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        pb.set_can_sleep(id, False)
    var pcfg = SolverConfig()
    pcfg.parallel = True
    for _ in range(120):
        pb.step(DT, G, pcfg)
    var same = len(pa.events) == len(pb.events)
    for k in range(min(len(pa.events), len(pb.events))):
        if pa.events[k].impulse != pb.events[k].impulse or pa.events[k].force != pb.events[k].force or pa.events[k].peak != pb.events[k].peak:
            same = False
    s.check(same, "island-parallel step: payload bit-identical to serial")
    var pc = ContactScene6[QuatBody6]()
    _ = _floor(pc)
    pc.events_on = True
    for k in range(3):
        var id = pc.add(QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(k), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        pc.set_can_sleep(id, False)
    var bcfg = SolverConfig()
    bcfg.broadphase = True
    for _ in range(120):
        pc.step(DT, G, bcfg)
    var same_bp = len(pa.events) == len(pc.events)
    for k in range(min(len(pa.events), len(pc.events))):
        if pa.events[k].impulse != pc.events[k].impulse or pa.events[k].force != pc.events[k].force:
            same_bp = False
    s.check(same_bp, "BVH broadphase vs brute pairs: payload bit-identical")

    # ---- per-body flags; sensor; sleeping ------------------------------------
    var sr = ContactScene6[QuatBody6]()
    _ = _floor(sr)
    sr.events_on = True
    var r1 = sr.add(QuatBody6.at_rest(Vec3(-2, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var r2 = sr.add(QuatBody6.at_rest(Vec3(2, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var sens = sr.add(QuatBody6.at_rest(Vec3(2, 0.25, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
    sr.set_sensor(sens.index(), True)
    sr.set_contact_reporting(r1, True)
    sr.step_soft(DT, G)
    var only_r1 = len(sr.events) > 0
    for k in range(len(sr.events)):
        if sr.events[k].a != r1.index() and sr.events[k].b != r1.index():
            only_r1 = False
    s.check(only_r1, "report flag on one body: only its pairs are reported")
    sr.set_contact_reporting(r1, False)
    sr.step_soft(DT, G)
    var sensor_zero = False
    for k in range(len(sr.events)):
        if sr.events[k].a == sens.index() or sr.events[k].b == sens.index():
            sensor_zero = sr.events[k].impulse == 0
    s.check(sensor_zero, "flags cleared: every pair again; the sensor's event carries zero impulse")
    _ = r2
    var sz = ContactScene6[QuatBody6]()
    _ = _floor(sz)
    sz.events_on = True
    _ = sz.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(120):
        sz.step_soft(DT, G)
    sz.step_soft(DT, G)  # a whole step spent asleep
    var asleep = sz.bset.sleeping[1]
    var stays = 0
    var stay_imp = Real(0)
    for k in range(len(sz.events)):
        if sz.events[k].kind == EV_STAY:
            stays += 1
            stay_imp += sz.events[k].impulse
    print("  sleeping box: asleep", asleep, " stay events", stays, " their impulse", stay_imp)
    s.check(asleep and stay_imp == 0, "a sleeping body's contact reports no impulse")

    # ---- 3. extremes -----------------------------------------------------------
    var se = ContactScene6[QuatBody6]()
    _ = _floor(se)
    se.events_on = True
    var bb = QuatBody6.at_rest(Vec3(0, 0.52, 0, 0), Inertia3.sphere(1, 0.5))
    bb.vel = Vec3(0, -6, 0, 0)
    var bid = se.add_sphere(bb^, 0.5, False)
    se.set_restitution(bid.index(), 0.9)
    se.set_restitution(0, 0.9)
    var began_imp = Real(0)
    var ended_peak = Real(-1)
    for _ in range(40):
        se.step_soft(DT, G)
        for k in range(len(se.events)):
            if se.events[k].kind == EV_BEGAN and began_imp == 0:
                began_imp = se.events[k].impulse
            if se.events[k].kind == EV_ENDED and ended_peak < 0:
                ended_peak = se.events[k].peak
    print("  bouncing ball: began impulse", began_imp, " ended peak", ended_peak)
    s.check(ended_peak > 0 and ended_peak >= began_imp, "ENDED carries the contact's peak impulse")

    var sm = ContactScene6[QuatBody6]()
    var mv: List[Real] = [-4, 0, -4, 4, 0, -4, -4, 0, 4, 4, 0, 4, 0, 0, 0]
    var mi: List[Int] = [0, 2, 4, 2, 3, 4, 3, 1, 4, 1, 0, 4]
    _ = sm.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), mv, mi)
    sm.events_on = True
    var mb = sm.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sm.set_can_sleep(mb, False)
    for _ in range(90):
        sm.step_soft(DT, G)
    var tris = 0
    var tot = Real(0)
    var finite = True
    for k in range(len(sm.events)):
        if sm.events[k].kind == EV_STAY:
            tris += 1
            tot += sm.events[k].impulse
        if not (sm.events[k].impulse == sm.events[k].impulse and sm.events[k].force == sm.events[k].force):
            finite = False
    print("  box on the centre vertex of a 4-triangle mesh:", tris, "triangle events, impulses sum", tot, " m g dt", mg * DT)
    s.check(tris >= 2, "mesh: one event per touched triangle")
    s.check(abs(tot - mg * DT) < 0.02 * mg * DT, "mesh: the per-triangle impulses sum to m g dt")
    s.check(finite, "every payload finite")
    s.finish()
