from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _scene() -> ContactScene6[QuatBody6]:
    """4 separated 3-box towers + a ball-joint pendulum + a bouncy sphere:
    six independent islands exercising contacts, joints, restitution and
    every shape path."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for t in range(4):
        var x = Real(t) * 4 - 6
        for i in range(3):
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    var anchor = sc.add(
        QuatBody6.at_rest(Vec3(10, 2, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05),
        True,
    )
    var bob = sc.add(
        QuatBody6.at_rest(Vec3(10, 1, 0), Inertia3.box(1, 0.15, 0.15, 0.15)),
        Vec3(0.15, 0.15, 0.15),
        False,
    )
    _ = sc.add_joint(Joint6.ball(anchor, bob, Vec3(0, 0, 0), Vec3(0, 1, 0)))
    sc.bodies[bob].vel = Vec3(0.3, 0, 0)
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(-10, 1.3, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    sc.set_restitution(ball, 0.7)
    return sc^


def main() raises:
    var s = Suite("islands_par")

    var ser = _scene()
    var par = _scene()
    for _ in range(400):
        ser.step_soft(DT, G)
        par.step_soft(DT, G, parallel=True)

    # 1. Bit-identical states across every body (the whole point: islands
    #    share nothing, so threading must not change a single bit).
    var same_pos = True
    var same_rot = True
    var same_sleep = True
    for i in range(len(ser.bodies)):
        var dp = ser.bodies[i].pos - par.bodies[i].pos
        if dp[0] != 0 or dp[1] != 0 or dp[2] != 0:
            same_pos = False
            print("  pos mismatch body", i)
        if (
            ser.bodies[i].q.x != par.bodies[i].q.x
            or ser.bodies[i].q.w != par.bodies[i].q.w
        ):
            same_rot = False
        if ser.sleeping[i] != par.sleeping[i]:
            same_sleep = False
    s.check(same_pos, "parallel == serial positions (bit-identical)")
    s.check(same_rot, "parallel == serial rotations")
    s.check(same_sleep, "parallel == serial sleep states")

    # 2. The scene really is multi-island (the parallelism is real).
    print("  islands:", par.island_count())
    s.check(par.island_count() >= 5, "scene splits into many islands")

    # 3. Physics sanity on the parallel path: towers stand, sphere bounced.
    var ok = True
    for t in range(4):
        for i in range(3):
            var idx = 1 + t * 3 + i
            var y = Float64(par.bodies[idx].position()[1])
            if abs(y - (0.25 + 0.5 * Float64(i))) > 0.02:
                ok = False
    s.check(ok, "all four towers stand under the parallel solver")

    s.finish()
