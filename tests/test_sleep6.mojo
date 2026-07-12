from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _ground(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 20, 1, 20)),
        Vec3(20, 1, 20),
        True,
    )


def main() raises:
    var s = Suite("sleep6")
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)

    # 1. Islands: two separated 2-box stacks -> exactly 2 dynamic islands.
    var sc = ContactScene6[QuatBody6]()
    _ground(sc)
    _ = sc.add(QuatBody6.at_rest(Vec3(-3, 0.3, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(-3, 0.85, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(3, 0.3, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(3, 0.85, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(30):
        sc.step_soft(DT, G)
    s.check(sc.island_count() == 2, "two separated stacks -> 2 islands")
    s.check(sc.island[1] == sc.island[2], "stack members share an island")
    s.check(sc.island[1] != sc.island[3], "separate stacks differ")
    s.check(sc.island[0] == -1, "static ground is no island")

    # 2. Sleeping: a settled box falls asleep and freezes bit-exact.
    var one = ContactScene6[QuatBody6]()
    _ground(one)
    _ = one.add(QuatBody6.at_rest(Vec3(0, 0.3, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    var asleep_at = -1
    for t in range(180):
        one.step_soft(DT, G)
        if asleep_at < 0 and one.sleeping[1]:
            asleep_at = t
    print("  fell asleep at frame", asleep_at)
    s.check(asleep_at > 0, "settled box falls asleep")
    s.check(asleep_at < 150, "asleep within 2.5 s")
    s.check(_len(one.bodies[1].vel) == 0, "sleeping velocity exactly zero")
    var y_frozen = Float64(one.bodies[1].pos[1])
    for _ in range(100):
        one.step_soft(DT, G)
    s.check(
        Float64(one.bodies[1].pos[1]) == y_frozen, "sleeping pose bit-frozen"
    )
    s.check(one.sleeping[1], "still asleep with no disturbance")

    # 3. Wake on impact: drop a box onto the sleeper; both settle and sleep.
    var b2 = QuatBody6.at_rest(Vec3(0, 1.4, 0), bi)
    _ = one.add(b2, Vec3(0.25, 0.25, 0.25), False)
    var woke = False
    var both_asleep = False
    for _ in range(300):
        one.step_soft(DT, G)
        if not one.sleeping[1]:
            woke = True
        if one.sleeping[1] and one.sleeping[2]:
            both_asleep = True
    s.check(woke, "impact wakes the sleeping box")
    s.check(both_asleep, "the whole stack sleeps again")
    s.check(
        abs(Float64(one.bodies[2].pos[1]) - 0.75) < 0.03,
        "dropped box rests on the sleeper",
    )

    # 4. Determinism: two identical runs end bit-identical.
    var ra = ContactScene6[QuatBody6]()
    _ground(ra)
    _ = ra.add(QuatBody6.at_rest(Vec3(0, 0.5, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    var rb = ContactScene6[QuatBody6]()
    _ground(rb)
    _ = rb.add(QuatBody6.at_rest(Vec3(0, 0.5, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(200):
        ra.step_soft(DT, G)
        rb.step_soft(DT, G)
    s.check(
        Float64(ra.bodies[1].pos[1]) == Float64(rb.bodies[1].pos[1]),
        "identical runs are bit-identical",
    )

    s.finish()
