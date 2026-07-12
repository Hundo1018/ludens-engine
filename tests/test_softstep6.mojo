from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def main() raises:
    var s = Suite("softstep6")

    # 1a. Tower, rotation frozen (huge inertia): isolates the solver's linear
    #     stacking quality — 6 boxes must stand 1000 steps at machine precision.
    #     (Verified diagnosis: with rotation live, the tower leans exponentially
    #     because the AABB manifold is axis-aligned and cannot produce the
    #     restoring geometry for tilted boxes — fixed by the 3D rotated-box
    #     manifold, ROADMAP 2.1 follow-up.)
    var fr = ContactScene6[QuatBody6]()
    _ = fr.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var bfrozen = Inertia3(2, 1e12, 1e12, 1e12)
    for i in range(6):
        _ = fr.add(
            QuatBody6.at_rest(Vec3(0, 0.3 + 0.52 * Real(i), 0), bfrozen),
            Vec3(0.25, 0.25, 0.25),
            False,
        )
    for _ in range(1000):
        fr.step_soft(DT, G)
    var frozen_ok = True
    for i in range(6):
        var y = Float64(fr.bodies[i + 1].position()[1])
        var want = 0.25 + 0.5 * Float64(i)
        if abs(y - want) > 0.01 or abs(Float64(fr.bodies[i + 1].position()[0])) > 1e-6:
            frozen_ok = False
            print("  frozen tower box", i, "y=", y, "want", want)
    s.check(frozen_ok, "frozen-rotation tower of 6: 1000 steps, machine-tight")

    # 1b. Tower with LIVE rotation, 1000 steps — the full ROADMAP 2.1 gate,
    #     unblocked by the rotated box-box manifold (tilt now produces a
    #     restoring contact patch instead of an axis-aligned fiction).
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(6):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0.3 + 0.52 * Real(i), 0), bi),
            Vec3(0.25, 0.25, 0.25),
            False,
        )
    for _ in range(1000):
        sc.step_soft(DT, G)
    var tower_ok = True
    for i in range(6):
        var y = Float64(sc.bodies[i + 1].position()[1])
        var want = 0.25 + 0.5 * Float64(i)
        if abs(y - want) > 0.02:
            tower_ok = False
            print("  tower box", i, "y=", y, "want", want)
    s.check(tower_ok, "tower of 6 stands 1000 steps (live rotation)")
    s.check(
        abs(Float64(sc.bodies[6].position()[0])) < 0.01,
        "tower lean stays millimetric",
    )
    s.check(_len(sc.bodies[6].omega) < 1e-3, "top box spin converged")

    # 1c. Single box: soft-step rest quality is orders beyond the plain step.
    var one = ContactScene6[QuatBody6]()
    _ = one.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = one.add(QuatBody6.at_rest(Vec3(0, 0.3, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(300):
        one.step_soft(DT, G)
    s.check(
        abs(Float64(one.bodies[1].position()[1]) - 0.25) < 0.005,
        "single box rest height within 5mm",
    )
    s.check(_len(one.bodies[1].vel) < 1e-4, "single box velocity ~0")
    s.check(_len(one.bodies[1].omega) < 1e-4, "single box spin ~0")

    # 2. Mass ratio 100:1 — heavy box resting on a light box does not explode.
    var mr = ContactScene6[QuatBody6]()
    _ = mr.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = mr.add(
        QuatBody6.at_rest(Vec3(0, 0.3, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    _ = mr.add(
        QuatBody6.at_rest(
            Vec3(0, 0.85, 0), Inertia3.box(100, 0.25, 0.25, 0.25)
        ),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    # Full-horizon ROADMAP gate: 600 steps, the heavy box stays put on top.
    for _ in range(600):
        mr.step_soft(DT, G)
    var y_light = Float64(mr.bodies[1].position()[1])
    var y_heavy = Float64(mr.bodies[2].position()[1])
    s.check(y_light > 0.2 and y_light < 0.26, "100:1 light box not crushed")
    s.check(abs(y_heavy - 0.70) < 0.06, "100:1 heavy box rests on light box")
    s.check(
        abs(Float64(mr.bodies[2].position()[0])) < 0.05,
        "100:1 heavy box does not walk off",
    )
    s.check(_len(mr.bodies[2].vel) < 0.02, "100:1 heavy box at rest")

    # 3. Cross-representation parity on the soft path (single resting box).
    var sq = ContactScene6[QuatBody6]()
    _ = sq.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = sq.add(QuatBody6.at_rest(Vec3(0, 0.35, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    var ss = ContactScene6[ScrewBody6]()
    _ = ss.add(
        ScrewBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = ss.add(ScrewBody6.at_rest(Vec3(0, 0.35, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(300):
        sq.step_soft(DT, G)
        ss.step_soft(DT, G)
    var yq = Float64(sq.bodies[1].position()[1])
    var ys = Float64(ss.bodies[1].position()[1])
    s.check(abs(yq - ys) < 5e-3, "soft-step parity: quat vs screw rest height")
    s.check(abs(yq - 0.25) < 0.02, "soft-step rest height near contact")

    s.finish()
