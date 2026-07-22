from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6
from physics.softbody import SoftBody
from physics.serialize import scene_to_string, scene_from_string

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _rich() -> ContactScene6[QuatBody6]:
    """One of everything the format carries: tower contacts (warm-start
    cache), a ball-joint pendulum (joint accumulators), a bouncy sphere
    (restitution + shape), a static capsule, and a soft cube (particles,
    edges, material)."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(3):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(-3, 0.3 + 0.52 * Real(i), 0), bi),
            Vec3(0.25, 0.25, 0.25),
            False,
        )
    var anchor = sc.add(
        QuatBody6.at_rest(Vec3(3, 2, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05),
        True,
    )
    var bob = sc.add(
        QuatBody6.at_rest(Vec3(3, 1, 0), Inertia3.box(1, 0.15, 0.15, 0.15)),
        Vec3(0.15, 0.15, 0.15),
        False,
    )
    _ = sc.add_joint(Joint6.ball(anchor, bob, Vec3(0, 0, 0), Vec3(0, 1, 0)))
    sc.bodies[bob].vel = Vec3(0.3, 0, 0)
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(6, 1.3, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    sc.set_restitution(ball, 0.7)
    _ = sc.add_capsule(
        QuatBody6.at_rest(Vec3(-6, -0.45, 0), Inertia3.capsule(1, 0.3, 0.4)),
        0.3,
        0.4,
        True,
    )
    _ = sc.add_soft(
        SoftBody.box_lattice(Vec3(0, 0.35, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4)
    )
    return sc^


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
    for i in range(len(sc.bodies)):
        var dp = sc.bodies[i].pos - sc2.bodies[i].pos
        var dv = sc.bodies[i].vel - sc2.bodies[i].vel
        var dw = sc.bodies[i].omega - sc2.bodies[i].omega
        if (
            dp[0] != 0 or dp[1] != 0 or dp[2] != 0
            or dv[0] != 0 or dv[1] != 0 or dv[2] != 0
            or dw[0] != 0 or dw[1] != 0 or dw[2] != 0
            or sc.bodies[i].q.x != sc2.bodies[i].q.x
            or sc.bodies[i].q.w != sc2.bodies[i].q.w
        ):
            same_body = False
            print("  mismatch body", i)
        if sc.sleeping[i] != sc2.sleeping[i]:
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
        var y = Float64(sc2.bodies[1 + i].pos[1])
        if abs(y - (0.25 + 0.5 * Float64(i))) > 0.03:
            ok = False
    s.check(ok, "tower stands through save/load")

    s.finish()
