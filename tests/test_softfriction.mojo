from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _mean(sc: ContactScene6[QuatBody6]) -> Vec3:
    var m = Vec3(0, 0, 0)
    for i in range(len(sc.softs[0].pts)):
        m = m + sc.softs[0].pts[i].x
    return m * (1 / Real(len(sc.softs[0].pts)))


def _len3(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _ramp_drift(angle: Real, mu: Real) raises -> Float64:
    """Soft cube on a static ramp tilted by `angle`: settle 120 frames, then
    measure how far the cube travels over the next 300. Static friction
    (tan(angle) < mu) should pin it; past the cone it slides."""
    var sc = ContactScene6[QuatBody6]()
    var ramp = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 4, 0.3, 2)),
        Vec3(4, 0.3, 2),
        True,
    )
    sc.bodies[ramp].q = Quat.from_axis_angle(Vec3(0, 0, 1), angle)
    var sb = SoftBody.box_lattice(
        Vec3(0, 0.75, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    sb.mu = mu
    _ = sc.add_soft(sb^)
    for _ in range(120):
        sc.step_soft(DT, G)
    var m0 = _mean(sc)
    for _ in range(300):
        sc.step_soft(DT, G)
    return _len3(_mean(sc) - m0)


def main() raises:
    var s = Suite("softfriction")

    # 1. Static friction: 15° ramp (tan 15° = 0.27 < mu 0.5) — the cube
    #    grips; the frictionless control slides away.
    var stick = _ramp_drift(0.2618, 0.5)
    var slide0 = _ramp_drift(0.2618, 0.0)
    print("  15° ramp: drift mu=0.5", stick, " mu=0", slide0)
    s.check(stick < 0.03, "cube grips a 15° ramp (static friction)")
    s.check(slide0 > 0.15, "frictionless control slides (test bites)")

    # 2. Coulomb cone: 35° ramp (tan 35° = 0.70 > mu 0.5) — sliding regime
    #    even with friction on.
    var steep = _ramp_drift(0.6109, 0.5)
    print("  35° ramp: drift mu=0.5", steep)
    s.check(steep > 0.1, "past the cone the cube slides (dynamic regime)")

    # 3. The 6.7 artifact, fixed: on the sphere bump the cube now stays
    #    centred instead of creeping to the rim.
    var bc = ContactScene6[QuatBody6]()
    _ = bc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = bc.add_sphere(
        QuatBody6.at_rest(Vec3(0, -0.22, 0), Inertia3.sphere(1, 0.3)), 0.3, True
    )
    _ = bc.add_soft(
        SoftBody.box_lattice(Vec3(0, 0.35, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4)
    )
    for _ in range(400):
        bc.step_soft(DT, G)
    var mx = Float64(_mean(bc)[0])
    print("  bump perch: mean x", mx, "(frictionless creep was 0.397)")
    s.check(abs(mx) < 0.1, "friction pins the cube on the dome")

    # 4. Oblique zero-g impact on a free sphere: tangential (friction)
    #    impulses are equal-and-opposite, so momentum stays conserved.
    var mz = ContactScene6[QuatBody6]()
    var ball = mz.add_sphere(
        QuatBody6.at_rest(Vec3(0.15, 0.25, 0), Inertia3.sphere(2, 0.3)),
        0.3,
        False,
    )
    var mb = SoftBody.box_lattice(
        Vec3(-0.85, 0, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    mb.damp = 1.0
    for i in range(len(mb.pts)):
        var p = mb.pts[i]
        p.v = Vec3(1, 0, 0)
        mb.pts[i] = p
    _ = mz.add_soft(mb^)
    for _ in range(300):
        mz.step_soft(DT, Vec3(0, 0, 0))
    var px = Float64(mz.bodies[ball].vel[0]) * 2.0
    var py = Float64(mz.bodies[ball].vel[1]) * 2.0
    for i in range(len(mz.softs[0].pts)):
        var p = mz.softs[0].pts[i]
        px += Float64(p.v[0]) / Float64(p.w)
        py += Float64(p.v[1]) / Float64(p.w)
    print("  oblique momentum: px", px, "py", py)
    s.check(abs(px - 2.0) < 0.02, "px conserved with tangential impulses")
    s.check(abs(py) < 0.02, "py stays zero (pairs cancel)")

    s.finish()
