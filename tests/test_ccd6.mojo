from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def main() raises:
    var s = Suite("ccd6")

    # 1. Bullet vs thin wall: 50 m/s covers 0.83 m per frame — far more than
    #    the 0.15 m combined thickness. Speculative margin must stop it AT the
    #    surface instead of tunnelling (no gravity, isolate the mechanism).
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 0.05, 2, 2)),
        Vec3(0.05, 2, 2),
        True,
    )
    var bullet = QuatBody6.at_rest(
        Vec3(-2.5, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)
    )
    bullet.vel = Vec3(50, 0, 0)
    _ = sc.add(bullet, Vec3(0.1, 0.1, 0.1), False)
    var max_x = Float64(-1e30)
    for _ in range(60):
        sc.step_soft(DT, Vec3(0, 0, 0))
        var x = Float64(sc.bodies[1].position()[0])
        if x > max_x:
            max_x = x
    var final_x = Float64(sc.bodies[1].position()[0])
    print(
        "  bullet: max x =", max_x, "final x =", final_x,
        "final vx =", sc.bodies[1].vel[0],
    )
    # Speculative-margin guarantees (Box2D-grade first-stage CCD): the bullet
    # may transiently overlap the wall band but must never tunnel through the
    # midplane, and must end up expelled to the surface with bounded speed.
    # (A true swept/TOI pass — Jolt LinearCast — is the follow-up refinement.)
    s.check(max_x < 0.0, "bullet never crosses the wall midplane")
    s.check(final_x < -0.14, "bullet ends outside the wall")
    s.check(
        abs(Float64(sc.bodies[1].vel[0])) < 5.0,
        "bullet speed collapsed (50 -> <5 m/s, e=0 grade)",
    )

    # 2. Same bullet WITHOUT stepping soft margin would tunnel — sanity-check
    #    the test itself: one 0.83 m step jumps clean over the 0.15 m band.
    s.check(50.0 * Float64(DT) > 0.3, "test premise: per-frame travel >> wall")

    # 3. Non-regression: the speculative margin must not levitate a resting
    #    box or change its rest height.
    var one = ContactScene6[QuatBody6]()
    _ = one.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = one.add(
        QuatBody6.at_rest(Vec3(0, 0.3, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    for _ in range(300):
        one.step_soft(DT, Vec3(0, -9.8, 0))
    var y = Float64(one.bodies[1].position()[1])
    print("  rest height with speculative margin:", y)
    s.check(abs(y - 0.25) < 0.005, "rest height unchanged by margin")
    s.check(_len(one.bodies[1].vel) < 1e-3, "resting box still rests")

    # 4. A moderately fast drop lands without deep penetration or bounce:
    #    speculative contact catches it at the surface.
    var drop = ContactScene6[QuatBody6]()
    _ = drop.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var fast = QuatBody6.at_rest(
        Vec3(0, 3, 0), Inertia3.box(2, 0.25, 0.25, 0.25)
    )
    fast.vel = Vec3(0, -20, 0)  # 0.33 m per frame
    _ = drop.add(fast, Vec3(0.25, 0.25, 0.25), False)
    var min_y = Float64(1e30)
    for _ in range(120):
        drop.step_soft(DT, Vec3(0, -9.8, 0))
        var yy = Float64(drop.bodies[1].position()[1])
        if yy < min_y:
            min_y = yy
    print("  fast drop: min y =", min_y)
    s.check(min_y > 0.2, "fast drop never sinks deep")
    s.check(
        abs(Float64(drop.bodies[1].position()[1]) - 0.25) < 0.01,
        "fast drop settles at the surface",
    )

    s.finish()
