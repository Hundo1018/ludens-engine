from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _bounce_apex(e: Real) -> Float64:
    """Drop a box (bottom 1 m above ground) with restitution `e`; return the
    height of the bottom face at the FIRST bounce apex."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var b = sc.add(
        QuatBody6.at_rest(Vec3(0, 1.25, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    sc.set_restitution(b, e)
    var falling = True
    var apex = Float64(0)
    for _ in range(300):
        sc.step_soft(DT, G)
        var y = Float64(sc.bodies[b].position()[1])
        var vy = Float64(sc.bodies[b].vel[1])
        if falling and vy > 0.1:
            falling = False  # first impact happened, now rising
        if not falling:
            if y - 0.25 > apex:
                apex = y - 0.25
            if vy < -0.1 and apex > 0:
                break  # falling again: first apex recorded
    return apex


def main() raises:
    var s = Suite("restitution")

    # 1. e = 0.8: first apex near e^2 of the 1 m drop height.
    var a8 = _bounce_apex(0.8)
    print("  e=0.8 first apex:", a8, "(analytic 0.64)")
    s.check(abs(a8 - 0.64) < 0.10, "e=0.8 apex ~ e^2 * h")

    # 2. e = 0.4: much lower bounce.
    var a4 = _bounce_apex(0.4)
    print("  e=0.4 first apex:", a4, "(analytic 0.16)")
    s.check(abs(a4 - 0.16) < 0.07, "e=0.4 apex ~ e^2 * h")

    # 3. Ordering + dead drop: e=0 does not bounce at all.
    var a0 = _bounce_apex(0.0)
    print("  e=0.0 first apex:", a0)
    s.check(a0 < 0.02, "e=0 lands dead (regression guard)")
    s.check(a8 > a4 and a4 > a0, "apex ordering follows e")

    # 4. Successive apexes decay by ~e^2 (energy bookkeeping sane).
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var b = sc.add(
        QuatBody6.at_rest(Vec3(0, 1.25, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    sc.set_restitution(b, 0.8)
    var apexes = List[Float64]()
    var rising = False
    var cur = Float64(0)
    for _ in range(900):
        sc.step_soft(DT, G)
        var y = Float64(sc.bodies[b].position()[1]) - 0.25
        var vy = Float64(sc.bodies[b].vel[1])
        if vy > 0.1:
            rising = True
            if y > cur:
                cur = y
        elif rising and vy < -0.1:
            apexes.append(cur)
            cur = 0
            rising = False
        if len(apexes) >= 3:
            break
    s.check(len(apexes) >= 2, "multiple bounces recorded")
    if len(apexes) >= 2:
        var ratio = apexes[1] / apexes[0]
        print("  apex ratio 2/1:", ratio, "(analytic 0.64)")
        s.check(ratio > 0.4 and ratio < 0.85, "successive decay ~ e^2")

    # 5. Determinism.
    var r1 = _bounce_apex(0.6)
    var r2 = _bounce_apex(0.6)
    s.check(r1 == r2, "bounce runs bit-identical")

    s.finish()
