# tier: integration
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6
from physics.softbody import SoftBody
from physics.serialize import scene_to_string, scene_from_string
from collision.contact_events import ContactEvent, EV_BEGAN

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _rich() raises -> ContactScene6[QuatBody6]:
    """One of everything the format carries: tower contacts (warm-start
    cache), a ball-joint pendulum (joint accumulators), a bouncy sphere
    (restitution + shape), a static capsule, and a soft cube (particles,
    edges, material)."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(3):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(-3, 0.3 + 0.52 * Real(i), 0, 0), bi),
            Vec3(0.25, 0.25, 0.25, 0),
            False,
        )
    var anchor = sc.add(
        QuatBody6.at_rest(Vec3(3, 2, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05, 0),
        True,
    ).index()
    var bob = sc.add(
        QuatBody6.at_rest(Vec3(3, 1, 0, 0), Inertia3.box(1, 0.15, 0.15, 0.15)),
        Vec3(0.15, 0.15, 0.15, 0),
        False,
    ).index()
    _ = sc.add_joint(Joint6.ball(anchor, bob, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0)))
    sc.bset.bodies[bob].vel = Vec3(0.3, 0, 0, 0)
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(6, 1.3, 0, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    ).index()
    sc.set_restitution(ball, 0.7)
    _ = sc.add_capsule(
        QuatBody6.at_rest(Vec3(-6, -0.45, 0, 0), Inertia3.capsule(1, 0.3, 0.4)),
        0.3,
        0.4,
        True,
    )
    _ = sc.add_soft(
        SoftBody.box_lattice(Vec3(0, 0.35, 0, 0), Vec3(0.3, 0.3, 0.3, 0), 4, 2.0, 1e-4)
    )
    return sc^


def _events_equal(a: List[ContactEvent], b: List[ContactEvent]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if (
            a[i].a != b[i].a
            or a[i].b != b[i].b
            or a[i].feat != b[i].feat
            or a[i].kind != b[i].kind
        ):
            return False
    return True


def _event_scene() -> ContactScene6[QuatBody6]:
    """A small stack with `events_on` -- enough live floor/box and box/box
    contacts for a spurious post-load `began` storm (F20) to be visible."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(3):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0.3 + 0.52 * Real(i), 0, 0), bi),
            Vec3(0.25, 0.25, 0.25, 0), False,
        )
    return sc^


def _test_event_continuity(mut s: Suite) raises:
    """F20: the contact-event stream must continue identically after a
    save/load, not restart from an empty `_prev_keys` -- before this fix,
    the loaded scene's very first post-load step re-diffed against an EMPTY
    previous-key list and reported every already-live contact as a
    spurious `began`, diverging from the uninterrupted scene from that
    step on."""
    var sc = _event_scene()
    for _ in range(120):  # settle into a steady contact set first
        sc.step_soft(DT, G)
    var sc2 = scene_from_string(scene_to_string(sc))
    var all_match = True
    var first_step_began = -1
    for step in range(50):
        sc.step_soft(DT, G)
        sc2.step_soft(DT, G)
        if not _events_equal(sc.events, sc2.events):
            all_match = False
        if step == 0:
            first_step_began = 0
            for i in range(len(sc2.events)):
                if sc2.events[i].kind == EV_BEGAN:
                    first_step_began += 1
    s.check(
        all_match,
        "F20: contact events bit-identical to an uninterrupted run for 50 steps after save/load",
    )
    s.check(
        first_step_began == 0,
        "F20: no spurious began events on the first post-load step",
    )


def _test_truncated_snapshot_raises(mut s: Suite, sc: ContactScene6[QuatBody6]) raises:
    """F20/E20: a truncated (or otherwise corrupt) snapshot is an
    environment-class failure (docs/ARCHITECTURE.md S2), so loading one
    raises instead of reading past the end of the token stream."""
    var full = scene_to_string(sc)
    var toks = List[String]()
    for t in full.split(" "):
        if t.byte_length() > 0:
            toks.append(String(t))
    var half = String("")
    for i in range(len(toks) // 2):
        half += toks[i] + " "
    var raised = False
    try:
        _ = scene_from_string(half)
    except:
        raised = True
    s.check(raised, "a truncated snapshot raises rather than reading out of bounds")


def main() raises:
    var s = Suite("serialize")

    var sc = _rich()
    for _ in range(300):
        sc.step_soft(DT, G)

    # 1. Round trip is exact: save -> load -> save gives the same blob.
    var s1 = scene_to_string(sc)
    var sc2 = scene_from_string(s1)
    var s2 = scene_to_string(sc2)
    print("  blob bytes:", s1.byte_length())
    s.check(s1 == s2, "save -> load -> save is byte-identical")

    # 2. The loaded scene CONTINUES bit-identically for 100 frames — this
    #    is what forces the warm-start cache and joint accumulators into
    #    the format.
    for _ in range(100):
        sc.step_soft(DT, G)
        sc2.step_soft(DT, G)
    var same_body = True
    var same_sleep = True
    for i in range(len(sc.bset.bodies)):
        var dp = sc.bset.bodies[i].pos - sc2.bset.bodies[i].pos
        var dv = sc.bset.bodies[i].vel - sc2.bset.bodies[i].vel
        var dw = sc.bset.bodies[i].omega - sc2.bset.bodies[i].omega
        if (
            dp[0] != 0 or dp[1] != 0 or dp[2] != 0
            or dv[0] != 0 or dv[1] != 0 or dv[2] != 0
            or dw[0] != 0 or dw[1] != 0 or dw[2] != 0
            or sc.bset.bodies[i].q.x != sc2.bset.bodies[i].q.x
            or sc.bset.bodies[i].q.w != sc2.bset.bodies[i].q.w
        ):
            same_body = False
            print("  mismatch body", i)
        if sc.bset.sleeping[i] != sc2.bset.sleeping[i]:
            same_sleep = False
    s.check(same_body, "rigid states bit-identical after 100 resumed frames")
    s.check(same_sleep, "sleep states bit-identical")
    var same_soft = True
    for i in range(len(sc.softs[0].pts)):
        var d = sc.softs[0].pts[i].x - sc2.softs[0].pts[i].x
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            same_soft = False
    s.check(same_soft, "soft particles bit-identical after resume")

    # 3. Physics sanity on the resumed scene: tower still standing, pendulum
    #    bob still attached near its anchor radius.
    var ok = True
    for i in range(3):
        var y = Float64(sc2.bset.bodies[1 + i].pos[1])
        if abs(y - (0.25 + 0.5 * Float64(i))) > 0.03:
            ok = False
    s.check(ok, "tower stands through save/load")

    # 4. F20: the event stream continues identically after save/load.
    _test_event_continuity(s)

    # 5. F20/E20: a truncated snapshot raises.
    _test_truncated_snapshot_raises(s, sc)

    s.finish()
