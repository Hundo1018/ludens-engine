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
from physics.body_set import BodyId

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> BodyId:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 20, 1, 20)),
        Vec3(20, 1, 20, 0),
        True,
    )


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

    s.finish()
