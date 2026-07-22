from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _drop_scene(alpha: Real) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = sc.add_soft(
        SoftBody.box_lattice(Vec3(0, 1.0, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, alpha)
    )
    return sc^


def main() raises:
    var s = Suite("softbody")

    # 1. Soft cube dropped on the ground: settles, stays above the floor,
    #    keeps a sane height, and repeats bit-identically.
    var sc = _drop_scene(1e-6)
    for _ in range(300):
        sc.step_soft(DT, G)
    var bot = Float64(sc.softs[0].bottom_y())
    var top = Float64(sc.softs[0].top_y())
    var spd = Float64(sc.softs[0].max_speed())
    print("  drop: bottom", bot, "top", top, "height", top - bot, "speed", spd)
    s.check(bot > -0.01, "no particle sinks through the floor")
    s.check(spd < 0.1, "cube settles")
    var h0 = 0.6
    s.check(top - bot > 0.45 * h0 and top - bot < 1.2 * h0, "height sane")

    var sc2 = _drop_scene(1e-6)
    for _ in range(300):
        sc2.step_soft(DT, G)
    s.check(
        Float64(sc2.softs[0].pts[13].x[1]) == Float64(sc.softs[0].pts[13].x[1]),
        "repeat run bit-identical",
    )

    # 2. Stiffness ordering: harder lattice settles taller than a soft one.
    #    (XPBD scale note: alpha/h^2 must rival the inverse-mass sum ~64 to
    #    soften — alpha >= 1e-2 is the visibly-squashy regime here.)
    var soft = _drop_scene(3e-2)
    for _ in range(300):
        soft.step_soft(DT, G)
    var h_stiff = Float64(sc.softs[0].top_y() - sc.softs[0].bottom_y())
    var h_soft = Float64(soft.softs[0].top_y() - soft.softs[0].bottom_y())
    print("  stiffness: stiff height", h_stiff, "soft height", h_soft)
    s.check(h_stiff > h_soft + 0.01, "stiffer cube stands taller")

    # 3. Two-way coupling, zero gravity: a moving soft cube hits a free box;
    #    the box picks up momentum and the total is conserved (within the
    #    solver's damping).
    var zg = ContactScene6[QuatBody6]()
    var box = zg.add(
        QuatBody6.at_rest(Vec3(1.0, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    var cube = SoftBody.box_lattice(Vec3(-0.6, 0, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-6)
    cube.damp = 1.0  # lossless material: isolates the coupling's conservation
    for i in range(len(cube.pts)):
        cube.pts[i].v = Vec3(2, 0, 0)
    _ = zg.add_soft(cube^)
    var p_before = Float64(zg.softs[0].momentum()[0])  # box at rest
    for _ in range(120):
        zg.step_soft(DT, Vec3(0, 0, 0))
    var box_p = Float64(zg.bodies[box].vel[0]) * 2.0
    var soft_p = Float64(zg.softs[0].momentum()[0])
    print("  coupling: before", p_before, "after soft", soft_p, "+ box", box_p)
    s.check(box_p > 0.3, "free box picks up momentum from the soft cube")
    s.check(
        abs((soft_p + box_p) - p_before) / p_before < 0.1,
        "momentum conserved through coupling (10%)",
    )

    # 4. Rigid box placed onto a SETTLED soft cube: rests ON it, compressing
    #    it. (Settle first, then a gentle 5 cm drop — with ccd=False,
    #    per-frame travel must stay under the particle contact radius;
    #    fast impacts are covered by ccd=True, see test_softccd.mojo.)
    var rs = _drop_scene(1e-3)
    for _ in range(240):
        rs.step_soft(DT, G)
    var top_before = Float64(rs.softs[0].top_y())
    var rider = rs.add(
        QuatBody6.at_rest(
            Vec3(0, Real(top_before) + 0.25, 0), Inertia3.box(1.0, 0.2, 0.2, 0.2)
        ),
        Vec3(0.2, 0.2, 0.2),
        False,
    )
    for _ in range(360):
        rs.step_soft(DT, G)
    var cube_top = Float64(rs.softs[0].top_y())
    var box_bot = Float64(rs.bodies[rider].position()[1]) - 0.2
    print(
        "  rider: top before", top_before, "after", cube_top,
        "box bottom", box_bot,
    )
    s.check(abs(box_bot - cube_top) < 0.08, "rigid box rests on the soft cube")
    # compression shows as the rider sinking below the undeformed rest plane
    # (top_before + particle radius); top_y() alone reports unloaded corner
    # columns, so measure the load path directly.
    var sink = (top_before + 0.05) - box_bot
    print("  rider sink below rest plane:", sink)
    s.check(sink > 0.003, "cube compressed under the rider (sink > 3mm)")
    s.check(cube_top > 0.2, "cube not squashed flat")
    s.check(_len(rs.bodies[rider].vel) < 0.2, "rider settled")

    s.finish()
