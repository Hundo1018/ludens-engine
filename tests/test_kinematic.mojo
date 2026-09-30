# tier: integration
"""ROADMAP 17.24 (KINEMATIC motion type). Ordinary: a translating platform
carries a resting box by friction, an elevator lifts a box. Integration:
kinematic + islands + sleep + the broadphase seam, and a save/load that
resumes with a kinematic body. Extreme: the KEY PARITY TEST (a zero-velocity
kinematic body is bit-identical to a static one), a kinematic moving into a
static wall produces no contact and no NaN, `move_to` with a huge
displacement stays finite, and a kinematic squeezing a dynamic box against a
static wall stays finite."""
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6, Pose6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _finite(v: Real) -> Bool:
    return v == v and Float64(abs(v)) < 1e30


def _finite3(v: Vec3) -> Bool:
    return _finite(v[0]) and _finite(v[1]) and _finite(v[2])


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def main() raises:
    var s = Suite("kinematic")
    var box_i = Inertia3.box(2, 0.25, 0.25, 0.25)

    # 1. Ordinary: a horizontally translating platform carries a resting box
    #    along by friction (default friction is nonzero, so pure sliding
    #    is not what should happen -- the box should end up displaced by a
    #    sizeable fraction of the platform's own travel).
    var sc1 = ContactScene6[QuatBody6]()
    var plat1 = sc1.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i),
        Vec3(3, 0.5, 3, 0),
        False,
    )
    sc1.set_kinematic(plat1)
    sc1.set_velocity(plat1, Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0))
    var box1 = sc1.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), box_i),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    for _ in range(120):  # settle, then 2s of platform travel at 1 m/s
        sc1.step_soft(DT, G)
    var plat_x = Float64(sc1.bset.bodies[plat1.index()].pos[0])
    var box_x = Float64(sc1.bset.bodies[box1.index()].pos[0]) - 0.0
    s.check(plat_x > 1.5, "platform actually travelled")
    s.check(box_x > 0.3 * plat_x, "friction carries the box a good fraction of the platform's travel")
    s.check(
        abs(Float64(sc1.bset.bodies[box1.index()].pos[1]) - 0.25) < 0.05,
        "box stays resting on the platform (no fall-through, no launch)",
    )

    # 2. Ordinary: an elevator (kinematic, vertical velocity) lifts a box
    #    resting on it -- the box's height should track the platform's.
    var sc2 = ContactScene6[QuatBody6]()
    var plat2 = sc2.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i),
        Vec3(3, 0.5, 3, 0),
        False,
    )
    sc2.set_kinematic(plat2)
    var box2 = sc2.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), box_i),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    for _ in range(30):  # settle first
        sc2.step_soft(DT, G)
    sc2.set_velocity(plat2, Vec3(0, 0.5, 0, 0), Vec3(0, 0, 0, 0))
    var y0 = Float64(sc2.bset.bodies[box2.index()].pos[1])
    var plat_y0 = Float64(sc2.bset.bodies[plat2.index()].pos[1])
    for _ in range(90):  # 1.5 s @ 0.5 m/s = 0.75 m of lift
        sc2.step_soft(DT, G)
    var dy_box = Float64(sc2.bset.bodies[box2.index()].pos[1]) - y0
    var dy_plat = Float64(sc2.bset.bodies[plat2.index()].pos[1]) - plat_y0
    s.check(dy_plat > 0.7, "platform actually rose")
    s.check(abs(dy_box - dy_plat) < 0.05, "box rides the elevator up, tracking its travel")

    # 3. Integration: kinematic + islands + sleep + the broadphase seam. A
    #    STATIONARY kinematic platform (velocity never set -> zero) still
    #    lets a resting box fall asleep (kinematic bodies never sleep
    #    themselves, but must not prevent a dynamic body from doing so), and
    #    the broadphase-backed step must agree with the brute path on
    #    whether the box is resting (both must be stable, not falling
    #    through -- the broadphase pair set for a dynamic-kinematic pair
    #    must match the brute reference exactly, `test_solver_bp_seam.mojo`'s
    #    seam).
    var sc3 = ContactScene6[QuatBody6]()
    var plat3 = sc3.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i),
        Vec3(3, 0.5, 3, 0),
        False,
    )
    sc3.set_kinematic(plat3)
    var box3 = sc3.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), box_i),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    var asleep = False
    for _ in range(200):
        sc3.step_soft(DT, G)
        if sc3.bset.sleeping[box3.index()]:
            asleep = True
    s.check(asleep, "a box resting on a stationary kinematic platform can fall asleep")
    s.check(not sc3.bset.sleeping[plat3.index()], "kinematic bodies are never marked sleeping")
    s.check(sc3.bset.island[plat3.index()] != sc3.bset.island[box3.index()], "kinematic never shares the dynamic body's island")

    var sc3bp = ContactScene6[QuatBody6]()
    var plat3bp = sc3bp.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i), Vec3(3, 0.5, 3, 0), False,
    )
    sc3bp.set_kinematic(plat3bp)
    var box3bp = sc3bp.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), box_i), Vec3(0.25, 0.25, 0.25, 0), False,
    )
    for _ in range(60):
        sc3bp.step_soft(DT, G, broadphase=True)
    s.check(
        abs(Float64(sc3bp.bset.bodies[box3bp.index()].pos[1]) - 0.25) < 0.05,
        "broadphase-backed step also rests the box on the kinematic platform",
    )

    # Integration: a save/load resumes bit-identically with a kinematic
    # body in the scene (round-trip must carry motion + velocity through).
    var sc4 = ContactScene6[QuatBody6]()
    var plat4 = sc4.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i), Vec3(3, 0.5, 3, 0), False,
    )
    sc4.set_kinematic(plat4)
    sc4.set_velocity(plat4, Vec3(0.4, 0, 0, 0), Vec3(0, 0, 0, 0))
    var box4 = sc4.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), box_i), Vec3(0.25, 0.25, 0.25, 0), False,
    )
    for _ in range(30):
        sc4.step_soft(DT, G)
    var sc4b = scene_from_string(scene_to_string(sc4))
    for _ in range(100):
        sc4.step_soft(DT, G)
        sc4b.step_soft(DT, G)
    s.check(
        Float64(sc4.bset.bodies[plat4.index()].pos[0])
        == Float64(sc4b.bset.bodies[plat4.index()].pos[0]),
        "resumed scene's kinematic platform position is bit-identical",
    )
    s.check(
        Float64(sc4.bset.bodies[box4.index()].pos[1])
        == Float64(sc4b.bset.bodies[box4.index()].pos[1]),
        "resumed scene's carried box position is bit-identical",
    )

    # 4. Extreme -- KEY PARITY TEST: a kinematic body with ZERO velocity is
    #    bit-identical, every step, to a static body in the same scene, for
    #    200 steps. Two otherwise-identical scenes, a stack of boxes falling
    #    onto a platform that is STATIC in one and KINEMATIC-but-motionless
    #    in the other.
    var sc_static = ContactScene6[QuatBody6]()
    _ = sc_static.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i), Vec3(3, 0.5, 3, 0), True,
    )
    var sc_kine = ContactScene6[QuatBody6]()
    var plat_k = sc_kine.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), box_i), Vec3(3, 0.5, 3, 0), False,
    )
    sc_kine.set_kinematic(plat_k)  # velocity left at its default: zero
    var n_boxes = 3
    for i in range(n_boxes):
        var pos = Vec3(0, 0.3 + 0.52 * Real(i), 0, 0)
        _ = sc_static.add(QuatBody6.at_rest(pos, box_i), Vec3(0.25, 0.25, 0.25, 0), False)
        _ = sc_kine.add(QuatBody6.at_rest(pos, box_i), Vec3(0.25, 0.25, 0.25, 0), False)
    var parity = True
    for _ in range(200):
        sc_static.step_soft(DT, G)
        sc_kine.step_soft(DT, G)
        for i in range(n_boxes):
            var a = sc_static.bset.bodies[1 + i]
            var b = sc_kine.bset.bodies[1 + i]
            if (
                Float64(a.pos[0]) != Float64(b.pos[0])
                or Float64(a.pos[1]) != Float64(b.pos[1])
                or Float64(a.pos[2]) != Float64(b.pos[2])
                or Float64(a.vel[0]) != Float64(b.vel[0])
                or Float64(a.vel[1]) != Float64(b.vel[1])
                or Float64(a.vel[2]) != Float64(b.vel[2])
            ):
                parity = False
    s.check(parity, "KEY PARITY: zero-velocity kinematic == static, every body, all 200 steps")

    # 5. Extreme: a kinematic body driven INTO a static wall produces no
    #    contact (17.24: kinematic-static pairs never collide) and stays
    #    finite -- it should pass straight through rather than being
    #    stopped or blowing up.
    var sc5 = ContactScene6[QuatBody6]()
    var wall5 = sc5.add(
        QuatBody6.at_rest(Vec3(5, 0, 0, 0), box_i), Vec3(0.5, 5, 5, 0), True,
    )
    var plat5 = sc5.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), box_i), Vec3(1, 1, 1, 0), False,
    )
    sc5.set_kinematic(plat5)
    sc5.set_velocity(plat5, Vec3(5, 0, 0, 0), Vec3(0, 0, 0, 0))
    var ok5 = True
    for _ in range(120):  # 2s @ 5 m/s = well past the wall at x=5
        sc5.step_soft(DT, G)
        if not _finite3(sc5.bset.bodies[plat5.index()].pos):
            ok5 = False
    s.check(ok5, "kinematic driven through a static wall stays finite throughout")
    s.check(
        Float64(sc5.bset.bodies[plat5.index()].pos[0]) > 6.0,
        "no contact: the kinematic body passed straight through the wall",
    )
    _ = wall5

    # 6. Extreme: `move_to` with a huge displacement over one dt computes a
    #    huge but FINITE velocity -- never NaN/Inf.
    var sc6 = ContactScene6[QuatBody6]()
    var plat6 = sc6.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), box_i), Vec3(1, 1, 1, 0), False)
    sc6.set_kinematic(plat6)
    sc6.move_to(plat6, Pose6(Vec3(1.0e6, 0, 0, 0), Quat.identity()), DT)
    var v6 = sc6.bset.bodies[plat6.index()].vel
    s.check(_finite3(v6), "move_to with a huge displacement yields a finite velocity")
    s.check(_len(v6) > 1.0e7, "...and it really is huge, not silently clamped")
    sc6.step_soft(DT, G)
    s.check(_finite3(sc6.bset.bodies[plat6.index()].pos), "the resulting pose stays finite after stepping")

    # 7. Extreme: a kinematic platform squeezing a dynamic box against a
    #    static wall stays finite (no explosion) even though the box has
    #    nowhere to go.
    var sc7 = ContactScene6[QuatBody6]()
    _ = sc7.add(
        QuatBody6.at_rest(Vec3(2, 0, 0, 0), box_i), Vec3(0.5, 5, 5, 0), True,
    )
    var box7 = sc7.add(
        QuatBody6.at_rest(Vec3(1, 0, 0, 0), box_i), Vec3(0.25, 0.25, 0.25, 0), False,
    )
    var plat7 = sc7.add(
        QuatBody6.at_rest(Vec3(-1, 0, 0, 0), box_i), Vec3(0.5, 0.5, 0.5, 0), False,
    )
    sc7.set_kinematic(plat7)
    sc7.set_velocity(plat7, Vec3(2, 0, 0, 0), Vec3(0, 0, 0, 0))
    var ok7 = True
    for _ in range(180):
        sc7.step_soft(DT, G)
        if not _finite3(sc7.bset.bodies[box7.index()].pos) or not _finite3(
            sc7.bset.bodies[box7.index()].vel
        ):
            ok7 = False
    s.check(ok7, "a dynamic box squeezed between a kinematic platform and a static wall stays finite")

    s.finish()
