# tier: integration
"""ROADMAP 17.25 (public sleep/wake lifecycle API): `is_sleeping`, `wake`,
`set_can_sleep`, `teleport`. Ordinary: manual wake of a sleeping stack.
Integration: `can_sleep=False` stays awake for 1000 steps, `teleport`
wakes + clears warm-start. Extreme: wake of a static/removed id (no-op vs.
raise per docs/ARCHITECTURE.md S2), repeated wake is idempotent, wake/
teleport of an invalid or removed id raises."""
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.body_set import BodyId

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> BodyId:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 20, 1, 20)),
        Vec3(20, 1, 20, 0),
        True,
    )


def _floor_load(sc: ContactScene6[QuatBody6], id: BodyId) raises -> Real:
    """Upward force on body `id` from the static ground (other == 0), this
    step's report."""
    var f = Real(0)
    for r in sc.contacts_of(id):
        if r.other == 0:
            f += r.force[1]
    return f


def main() raises:
    var s = Suite("sleep_api")
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)

    # 1. Ordinary: manual wake of a sleeping stack -- `is_sleeping` false
    #    before settling, true once asleep, false again immediately after
    #    `wake`, and the WHOLE island (both boxes) wakes together.
    var sc1 = ContactScene6[QuatBody6]()
    _ = _ground(sc1)
    var a1 = sc1.add(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    var b1 = sc1.add(QuatBody6.at_rest(Vec3(0, 0.85, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    s.check(not sc1.is_sleeping(a1), "freshly added body is not sleeping")
    var went_asleep = False
    for _ in range(200):
        sc1.step_soft(DT, G)
        if sc1.is_sleeping(a1) and sc1.is_sleeping(b1):
            went_asleep = True
            break
    s.check(went_asleep, "the stack settles and both boxes sleep")
    sc1.wake(a1)
    s.check(not sc1.is_sleeping(a1), "wake(a) wakes a immediately")
    s.check(not sc1.is_sleeping(b1), "wake(a) wakes its whole island, including b")

    # 2. Integration: `set_can_sleep(id, False)` keeps a body (and therefore
    #    its island) awake for 1000 steps even though it has settled.
    var sc2 = ContactScene6[QuatBody6]()
    _ = _ground(sc2)
    var v = sc2.add(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    sc2.set_can_sleep(v, False)
    var ever_slept = False
    for _ in range(1000):
        sc2.step_soft(DT, G)
        if sc2.is_sleeping(v):
            ever_slept = True
    s.check(not ever_slept, "can_sleep=False stays awake for 1000 steps despite settling")
    sc2.set_can_sleep(v, True)
    var slept_after = False
    for _ in range(200):
        sc2.step_soft(DT, G)
        if sc2.is_sleeping(v):
            slept_after = True
    s.check(slept_after, "re-enabling can_sleep lets it fall asleep normally")

    # Integration: `teleport` wakes a sleeping body and clears its
    # warm-start cache entries (so the next step doesn't re-apply a stale
    # impulse anchored to the old position).
    var sc3 = ContactScene6[QuatBody6]()
    _ = _ground(sc3)
    var t3 = sc3.add(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(200):
        sc3.step_soft(DT, G)
    s.check(sc3.is_sleeping(t3), "settles asleep before teleport")
    var had_cache_entry = False
    for c in range(len(sc3.cache)):
        if sc3.cache[c].a == t3.index() or sc3.cache[c].b == t3.index():
            had_cache_entry = True
    s.check(had_cache_entry, "a resting body has a warm-start cache entry before teleport")
    sc3.teleport(t3, Pose6(Vec3(10, 5, 0, 0), Quat.identity()))
    s.check(not sc3.is_sleeping(t3), "teleport wakes the body")
    s.check(
        Float64(sc3.bset.bodies[t3.index()].pos[0]) == 10.0
        and Float64(sc3.bset.bodies[t3.index()].pos[1]) == 5.0,
        "teleport instantly moves the body to the target pose",
    )
    var stale_entry = False
    for c in range(len(sc3.cache)):
        if sc3.cache[c].a == t3.index() or sc3.cache[c].b == t3.index():
            stale_entry = True
    s.check(not stale_entry, "teleport clears warm-start cache entries referencing the body")

    # 3. Extreme: wake of a STATIC id is a no-op, not a raise (valid id,
    #    just nothing to wake -- docs/ARCHITECTURE.md S2 only mandates a
    #    raise for invalid/removed input).
    var sc4 = ContactScene6[QuatBody6]()
    var ground4 = _ground(sc4)
    var raised_static = False
    try:
        sc4.wake(ground4)
    except:
        raised_static = True
    s.check(not raised_static, "wake(static id) is a no-op, does not raise")
    s.check(not sc4.is_sleeping(ground4), "static body still reads not-sleeping after wake")

    # Extreme: wake/teleport/is_sleeping/set_can_sleep of an INVALID (never
    # issued) id raises.
    var bogus = BodyId(999, 0)
    var raised_wake = False
    try:
        sc4.wake(bogus)
    except:
        raised_wake = True
    s.check(raised_wake, "wake(invalid id) raises")
    var raised_teleport = False
    try:
        sc4.teleport(bogus, Pose6(Vec3(0, 0, 0, 0), Quat.identity()))
    except:
        raised_teleport = True
    s.check(raised_teleport, "teleport(invalid id) raises")
    var raised_is_sleeping = False
    try:
        _ = sc4.is_sleeping(bogus)
    except:
        raised_is_sleeping = True
    s.check(raised_is_sleeping, "is_sleeping(invalid id) raises")
    var raised_can_sleep = False
    try:
        sc4.set_can_sleep(bogus, False)
    except:
        raised_can_sleep = True
    s.check(raised_can_sleep, "set_can_sleep(invalid id) raises")

    # Extreme: wake/teleport of a REMOVED id raises (the id is valid at
    # issue, then `remove` tombstones the slot).
    var sc5 = ContactScene6[QuatBody6]()
    var doomed = sc5.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    sc5.bset.remove(doomed)
    var raised_wake_removed = False
    try:
        sc5.wake(doomed)
    except:
        raised_wake_removed = True
    s.check(raised_wake_removed, "wake(removed id) raises")
    var raised_teleport_removed = False
    try:
        sc5.teleport(doomed, Pose6(Vec3(0, 0, 0, 0), Quat.identity()))
    except:
        raised_teleport_removed = True
    s.check(raised_teleport_removed, "teleport(removed id) raises")

    # Extreme: repeated wake is idempotent -- calling it twice in a row on
    # an already-awake body changes nothing further and does not raise.
    var sc6 = ContactScene6[QuatBody6]()
    _ = _ground(sc6)
    var r6 = sc6.add(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    sc6.wake(r6)
    sc6.wake(r6)
    sc6.wake(r6)
    s.check(not sc6.is_sleeping(r6), "repeated wake stays not-sleeping, no error")

    # 17.19 (5): a sleeping stack keeps reporting its resting load. Two 1 kg
    #    boxes on a floor read 19.6 N there both awake and asleep; the floor
    #    report read 0 N once the stack slept, because a pair the solver skips
    #    adds no step impulse. Steps 0-9 are the drop transient, so they are not
    #    checked.
    var cfg7 = SolverConfig()
    var sc7 = ContactScene6[QuatBody6]()
    _ = _ground(sc7)
    var base7 = sc7.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc7.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var slept7 = False
    var worst7 = Real(0)
    var awake_last7 = Real(0)
    var held_vs_live7 = Real(0)
    for step7 in range(120):
        sc7.step(DT, G, cfg7)
        if step7 < 10:
            continue
        var f7 = _floor_load(sc7, base7)
        if sc7.is_sleeping(base7):
            if not slept7:
                # the step before sleep was solved live; the first asleep
                # report must match it (the held snapshot is that step's load)
                held_vs_live7 = abs(f7 - awake_last7) / Real(19.6)
            slept7 = True
        worst7 = max(worst7, abs(f7 - Real(19.6)) / Real(19.6))
        awake_last7 = f7
    s.check(slept7, "the 2 kg stack falls asleep within 120 steps")
    s.check(worst7 < 0.01, "floor report within 1% of 19.6 N, awake and asleep (17.19 (5))")
    s.check(held_vs_live7 < 0.01, "first asleep report equals the last live report (held snapshot)")

    # 17.19 (5): waking the stack resumes the live path -- the next report is
    #    the awake one again, with no stale hold left over.
    sc7.wake(base7)
    sc7.step(DT, G, cfg7)
    var woke7 = _floor_load(sc7, base7)
    s.check(not sc7.is_sleeping(base7), "wake resumes the live solve")
    s.check(abs(woke7 - Real(19.6)) / Real(19.6) < 0.01, "after wake the floor report is the live 19.6 N")

    # 17.19 (5), excess path: a heavy body on a light one under the default
    #    `max_mass_ratio` carries a scaled excess in its report. The held
    #    report of the sleeping stack must equal its last live report, so the
    #    excess snapshot (`hold_excess`) is carried, not dropped.
    var sc8 = ContactScene6[QuatBody6]()
    _ = _ground(sc8)
    var light8 = sc8.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc8.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(30, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var slept8 = False
    var held_excess8 = Real(0)
    var last_live8 = Real(0)
    for _ in range(200):
        sc8.step(DT, G, cfg7)
        var f8 = _floor_load(sc8, light8)
        if sc8.is_sleeping(light8):
            if not slept8:
                held_excess8 = abs(f8 - last_live8) / max(last_live8, Real(1))
            slept8 = True
        else:
            last_live8 = f8
    s.check(slept8, "the heavy-on-light stack falls asleep within 200 steps")
    s.check(held_excess8 < 0.01, "held excess-path report equals the last live report (17.19 (5) A2)")

    s.finish()
