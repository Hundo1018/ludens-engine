"""Collision filtering, sensors and contact events (architecture law v3).

Filtering and events are one feature in two halves: a sensor is a body that is
filtered out of the SOLVE but not out of DETECTION, and the only way to observe
that it was detected is the event stream. So they are gated together.

ORDINARY    a layer matrix — bodies collide exactly when each one's category is
            in the other's mask; a sensor is passed through instead of pushed;
            a body entering, staying in and leaving a region produces began,
            stay and ended in that order.
INTEGRATION filtering applied through the broadphase seam gives bit-identical
            results to the brute seam, and so does the event stream; filters
            and sensor flags survive a serialize round trip; events work with
            static mesh contact, where one body pair carries several
            independent contacts keyed by triangle.
EXTREME     an all-zero mask (collides with nothing), a self-excluding category
            (the "players do not hit players" case), two sensors overlapping
            each other, a body that teleports so its contact set changes
            completely in one step, and a scene with no contacts at all.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, ContactEvent
from physics.serialize import scene_to_string, scene_from_string

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime NO_G = Vec3(0, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30), True,
    )


def _crate(x: Real, y: Real) -> QuatBody6:
    return QuatBody6.at_rest(Vec3(x, y, 0), Inertia3.box(2, 0.25, 0.25, 0.25))


def _count(sc: ContactScene6[QuatBody6], kind: Int) -> Int:
    var n = 0
    for e in range(len(sc.events)):
        if sc.events[e].kind == kind:
            n += 1
    return n


# ---------------------------------------------------------------- ORDINARY
def case_layers(cat_a: UInt32, mask_a: UInt32, cat_b: UInt32, mask_b: UInt32) -> Real:
    """Two crates side by side, overlapping. Returns their final separation:
    if they collide they push apart, if they are filtered they do not move."""
    var sc = ContactScene6[QuatBody6]()
    var a = sc.add(_crate(-0.2, 0), Vec3(0.25, 0.25, 0.25), False)
    var b = sc.add(_crate(0.2, 0), Vec3(0.25, 0.25, 0.25), False)
    sc.set_filter(a, cat_a, mask_a)
    sc.set_filter(b, cat_b, mask_b)
    for _ in range(60):
        sc.step_soft(DT, NO_G)
    return abs(sc.bodies[a].position()[0] - sc.bodies[b].position()[0])


def case_sensor() -> List[Real]:
    """A crate falls through a sensor volume onto the floor. It must pass
    STRAIGHT through — the sensor may not slow it — while the events record
    that it was there. Returns [y after 30 steps, sensor's own y, began, ended]."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = _floor(sc)
    var trig = sc.add(_crate(0, 1.0), Vec3(0.5, 0.5, 0.5), True)
    sc.set_sensor(trig, True)
    var b = sc.add(_crate(0, 3.0), Vec3(0.25, 0.25, 0.25), False)

    var began = 0
    var ended = 0
    var y30 = Real(0)
    for k in range(120):
        sc.step_soft(DT, G)
        began += _count(sc, 0)
        ended += _count(sc, 2)
        if k == 29:
            y30 = sc.bodies[b].position()[1]
    var out = List[Real](capacity=4)
    out.append(y30)
    out.append(sc.bodies[trig].position()[1])
    out.append(Real(began))
    out.append(Real(ended))
    return out^


def case_free_fall(steps: Int) -> Real:
    """The same fall with no sensor at all — the reference `case_sensor` must
    match, which is what proves the sensor applied no force."""
    var sc = ContactScene6[QuatBody6]()
    _ = _floor(sc)
    var b = sc.add(_crate(0, 3.0), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(steps):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_event_order() -> List[Real]:
    """A crate dropped on the floor: the first contact step must report exactly
    one began and no stay; the next, one stay and no began. Returns
    [began1, stay1, began2, stay2, ended_after_removal]."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = _floor(sc)
    var b = sc.add(_crate(0, 0.3), Vec3(0.25, 0.25, 0.25), False)
    var b1 = 0
    var s1 = 0
    var b2 = 0
    var s2 = 0
    var first = True
    for _ in range(40):
        sc.step_soft(DT, G)
        if len(sc.events) > 0 and first:
            b1 = _count(sc, 0)
            s1 = _count(sc, 1)
            first = False
        elif not first and b2 == 0 and s2 == 0:
            b2 = _count(sc, 0)
            s2 = _count(sc, 1)
    # teleport the crate far away: the contact must END
    sc.bodies[b].pos = Vec3(0, 40, 0)
    sc.sleeping[b] = False
    sc.step_soft(DT, G)
    var ended = _count(sc, 2)
    var out = List[Real](capacity=5)
    out.append(Real(b1))
    out.append(Real(s1))
    out.append(Real(b2))
    out.append(Real(s2))
    out.append(Real(ended))
    return out^


# ------------------------------------------------------------- INTEGRATION
def case_seam(use_bp: Bool) -> List[Real]:
    """A filtered, sensored, event-emitting scene run through both collision
    seams. Everything observable must match bit for bit."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = _floor(sc)
    var t = sc.add(_crate(0.6, 0.8), Vec3(0.4, 0.4, 0.4), True)
    sc.set_sensor(t, True)
    var p1 = sc.add(_crate(-0.6, 0.6), Vec3(0.25, 0.25, 0.25), False)
    var p2 = sc.add(_crate(-0.2, 0.6), Vec3(0.25, 0.25, 0.25), False)
    var q = sc.add(_crate(0.6, 2.0), Vec3(0.25, 0.25, 0.25), False)
    # players (bit 1) ignore each other but hit the world (bit 0)
    sc.set_filter(p1, 2, 0xFFFFFFFD)
    sc.set_filter(p2, 2, 0xFFFFFFFD)
    var total_events = 0
    for _ in range(180):
        sc.step_soft(DT, G, broadphase=use_bp)
        total_events += len(sc.events)
    var out = List[Real](capacity=4)
    out.append(sc.bodies[p1].position()[0])
    out.append(sc.bodies[p2].position()[0])
    out.append(sc.bodies[q].position()[1])
    out.append(Real(total_events))
    return out^


def case_roundtrip() raises -> List[Real]:
    """Filters and sensor flags are scene state, so a snapshot that dropped
    them would reload into a scene that collides differently. Returns
    [original x gap, reloaded x gap, reloaded sensor flag]."""
    var sc = ContactScene6[QuatBody6]()
    var a = sc.add(_crate(-0.2, 0), Vec3(0.25, 0.25, 0.25), False)
    var b = sc.add(_crate(0.2, 0), Vec3(0.25, 0.25, 0.25), False)
    var t = sc.add(_crate(5, 0), Vec3(0.25, 0.25, 0.25), True)
    sc.set_filter(a, 2, 0xFFFFFFFD)  # same layer, mutually excluded
    sc.set_filter(b, 2, 0xFFFFFFFD)
    sc.set_sensor(t, True)
    var sc2 = scene_from_string(scene_to_string(sc))
    for _ in range(60):
        sc.step_soft(DT, NO_G)
        sc2.step_soft(DT, NO_G)
    var out = List[Real](capacity=3)
    out.append(abs(sc.bodies[a].position()[0] - sc.bodies[b].position()[0]))
    out.append(abs(sc2.bodies[a].position()[0] - sc2.bodies[b].position()[0]))
    out.append(Real(1) if sc2.sensor[t] else Real(0))
    return out^


def case_mesh_events() -> List[Real]:
    """Events over static mesh contact, where ONE body pair carries several
    contacts told apart only by triangle index. Returns [distinct contacts in
    the last step, began over the run]."""
    var v = List[Real](capacity=12)
    v.append(-30.0); v.append(0.0); v.append(-30.0)
    v.append(-30.0); v.append(0.0); v.append(30.0)
    v.append(30.0); v.append(0.0); v.append(30.0)
    v.append(30.0); v.append(0.0); v.append(-30.0)
    var idx = List[Int](capacity=6)
    idx.append(0); idx.append(1); idx.append(2)
    idx.append(0); idx.append(2); idx.append(3)
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 30, 1, 30)), v^, idx^
    )
    # straddling the diagonal seam, so it touches both triangles
    _ = sc.add(_crate(0.0, 0.6), Vec3(0.25, 0.25, 0.25), False)
    var began = 0
    for _ in range(180):
        sc.step_soft(DT, G)
        began += _count(sc, 0)
    var out = List[Real](capacity=2)
    out.append(Real(len(sc.events)))
    out.append(Real(began))
    return out^


# ---------------------------------------------------------------- EXTREME
def case_zero_mask() -> Real:
    """A mask of zero collides with nothing at all — including the floor."""
    var sc = ContactScene6[QuatBody6]()
    _ = _floor(sc)
    var b = sc.add(_crate(0, 0.6), Vec3(0.25, 0.25, 0.25), False)
    sc.set_filter(b, 1, 0)
    for _ in range(120):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_two_sensors() -> Real:
    """Two overlapping sensors. Neither may push the other, and neither is
    dynamic, so nothing at all should move. Returns their separation."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    var a = sc.add(_crate(-0.1, 0), Vec3(0.25, 0.25, 0.25), False)
    var b = sc.add(_crate(0.1, 0), Vec3(0.25, 0.25, 0.25), False)
    sc.set_sensor(a, True)
    sc.set_sensor(b, True)
    for _ in range(60):
        sc.step_soft(DT, NO_G)
    return abs(sc.bodies[a].position()[0] - sc.bodies[b].position()[0])


def case_empty_scene() -> Real:
    """No bodies: the event diff must handle both lists being empty."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    for _ in range(5):
        sc.step_soft(DT, G)
    return Real(len(sc.events))


def main() raises:
    var s = Suite("filter_events")

    # ---- ORDINARY ----
    var open_gap = case_layers(1, 0xFFFFFFFF, 1, 0xFFFFFFFF)
    var blocked = case_layers(2, 0xFFFFFFFD, 2, 0xFFFFFFFD)
    var one_way = case_layers(2, 0xFFFFFFFF, 1, 0xFFFFFFFD)
    print("  gap — unfiltered", open_gap, " same-layer excluded", blocked,
          " one-sided mask", one_way)
    s.check(Float64(open_gap) > 0.45, "unfiltered crates push apart")
    s.check(Float64(blocked) < 0.41, "a layer excluded from its own mask does not collide")
    s.check(
        Float64(one_way) < 0.41,
        "one side refusing is enough: the test is symmetric",
    )

    var sn = case_sensor()
    var ff = case_free_fall(30)
    print("  sensor: crate y at step 30", sn[0], " free-fall reference", ff)
    s.check(sn[0] == ff, "a sensor applies NO impulse: the fall is unchanged")
    s.check(abs(Float64(sn[1]) - 1.0) < 1e-6, "the sensor itself does not move")
    s.check(Float64(sn[2]) >= 2, "entering the sensor and the floor both began")
    s.check(Float64(sn[3]) >= 1, "leaving the sensor ended")

    var eo = case_event_order()
    print("  first contact step: began", eo[0], " stay", eo[1],
          "| next step: began", eo[2], " stay", eo[3], "| after teleport: ended", eo[4])
    s.check(eo[0] == 1, "the first touching step reports exactly one began")
    s.check(eo[1] == 0, "and no stay")
    s.check(eo[2] == 0, "the next step reports no began")
    s.check(eo[3] == 1, "and one stay")
    s.check(eo[4] >= 1, "teleporting away ends the contact")

    # ---- INTEGRATION ----
    var brute = case_seam(False)
    var bp = case_seam(True)
    print("  seam — brute p1.x", brute[0], " events", brute[3],
          "| broadphase p1.x", bp[0], " events", bp[3])
    var same = True
    for k in range(4):
        if brute[k] != bp[k]:
            same = False
    s.check(same, "filtering, sensors and events are bit-identical on both seams")
    s.check(Float64(brute[3]) > 0, "the scene actually produced events")

    var rt = case_roundtrip()
    print("  round trip — original gap", rt[0], " reloaded gap", rt[1])
    s.check(rt[0] == rt[1], "filters survive a serialize round trip")
    s.check(rt[2] == 1, "so does the sensor flag")

    var me = case_mesh_events()
    print("  mesh events — contacts in the last step", me[0], " began total", me[1])
    s.check(me[0] >= 2, "a crate on a seam holds contacts with BOTH triangles")
    s.check(Float64(me[1]) >= 2, "each triangle began its own contact")

    # ---- EXTREME ----
    var zm = case_zero_mask()
    print("  zero mask, crate after 2s:", zm)
    s.check(Float64(zm) < -10.0, "a zero mask passes through the floor")

    var ts = case_two_sensors()
    s.check(abs(Float64(ts) - 0.2) < 1e-6, "two sensors do not push each other")

    s.check(case_empty_scene() == 0, "an empty scene emits no events")

    s.finish()
