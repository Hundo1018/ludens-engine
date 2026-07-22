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
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )


def main() raises:
    var s = Suite("shapes6")

    # 1. Sphere drop: rests with centre at its radius, and sleeps.
    var sd = ContactScene6[QuatBody6]()
    _ground(sd)
    var ball = sd.add_sphere(
        QuatBody6.at_rest(Vec3(0, 1, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    for _ in range(240):
        sd.step_soft(DT, G)
    var by = Float64(sd.bodies[ball].position()[1])
    print("  sphere rest y:", by, "(radius 0.3)")
    s.check(abs(by - 0.3) < 0.01, "sphere rests at its radius")
    s.check(sd.sleeping[ball], "sphere sleeps at rest")

    # 2. Sphere bounce: restitution machinery works on the new shape.
    var sb = ContactScene6[QuatBody6]()
    _ground(sb)
    var b2 = sb.add_sphere(
        QuatBody6.at_rest(Vec3(0, 1.3, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    sb.set_restitution(b2, 0.8)
    var falling = True
    var apex = Float64(0)
    for _ in range(300):
        sb.step_soft(DT, G)
        var y = Float64(sb.bodies[b2].position()[1])
        var vy = Float64(sb.bodies[b2].vel[1])
        if falling and vy > 0.1:
            falling = False
        if not falling:
            if y - 0.3 > apex:
                apex = y - 0.3
            if vy < -0.1 and apex > 0:
                break
    print("  sphere e=0.8 apex:", apex, "(analytic 0.64)")
    s.check(abs(apex - 0.64) < 0.10, "sphere bounce apex ~ e^2")

    # 3. Sphere-sphere head-on, zero G: momentum transfers to the resting one.
    var zz = ContactScene6[QuatBody6]()
    var m1 = QuatBody6.at_rest(Vec3(-1, 0, 0), Inertia3.sphere(2, 0.25))
    m1.vel = Vec3(3, 0, 0)
    var s1 = zz.add_sphere(m1, 0.25, False)
    var s2i = zz.add_sphere(
        QuatBody6.at_rest(Vec3(1, 0, 0), Inertia3.sphere(2, 0.25)), 0.25, False
    )
    for _ in range(120):
        zz.step_soft(DT, Vec3(0, 0, 0))
    var v1 = Float64(zz.bodies[s1].vel[0])
    var v2 = Float64(zz.bodies[s2i].vel[0])
    print("  sphere-sphere: v1", v1, "v2", v2, "sum", v1 + v2)
    s.check(v2 > 1.0, "momentum transferred to the resting sphere")
    s.check(abs((v1 + v2) - 3.0) < 0.15, "momentum conserved (equal masses)")

    # 4. Tilted capsule falls over and rests LYING: centre at its radius.
    var cd = ContactScene6[QuatBody6]()
    _ground(cd)
    var tilted = QuatBody6.at_rest(Vec3(0, 0.9, 0), Inertia3.capsule(2, 0.2, 0.4))
    tilted.omega = Vec3(0, 0, 1.2)  # knock it over
    var cap = cd.add_capsule(tilted, 0.2, 0.4, False)
    for _ in range(600):
        cd.step_soft(DT, G)
    var cy = Float64(cd.bodies[cap].position()[1])
    var up = cd.bodies[cap].q.rotate(Vec3(0, 1, 0))
    print("  capsule rest y:", cy, "axis up-component:", up[1])
    s.check(abs(cy - 0.2) < 0.03, "capsule rests lying at its radius")
    s.check(abs(Float64(up[1])) < 0.25, "capsule axis ended horizontal")

    # 5. Sphere rests on a box top without sliding off (friction holds).
    var st = ContactScene6[QuatBody6]()
    _ground(st)
    _ = st.add(
        QuatBody6.at_rest(Vec3(0, 0.3, 0), Inertia3.box(4, 0.3, 0.3, 0.3)),
        Vec3(0.3, 0.3, 0.3),
        False,
    )
    var topball = st.add_sphere(
        QuatBody6.at_rest(Vec3(0, 0.95, 0), Inertia3.sphere(1, 0.2)), 0.2, False
    )
    for _ in range(300):
        st.step_soft(DT, G)
    var ty = Float64(st.bodies[topball].position()[1])
    var tx = Float64(st.bodies[topball].position()[0])
    print("  sphere-on-box: y", ty, "x", tx)
    s.check(abs(ty - 0.8) < 0.02, "sphere rests on the box top")
    s.check(abs(tx) < 0.05, "sphere does not wander off")

    # 6. Determinism across the new shape paths.
    var r1 = ContactScene6[QuatBody6]()
    _ground(r1)
    _ = r1.add_sphere(
        QuatBody6.at_rest(Vec3(0.1, 1, 0.05), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    var r2 = ContactScene6[QuatBody6]()
    _ground(r2)
    _ = r2.add_sphere(
        QuatBody6.at_rest(Vec3(0.1, 1, 0.05), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    for _ in range(200):
        r1.step_soft(DT, G)
        r2.step_soft(DT, G)
    s.check(
        Float64(r1.bodies[1].position()[1]) == Float64(r2.bodies[1].position()[1]),
        "shape runs bit-identical",
    )

    s.finish()
