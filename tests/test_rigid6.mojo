from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from physics.screw import screw_velocity
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _pt_dist(a: Vec3, b: Vec3) -> Float64:
    return _len(a - b)


def main() raises:
    var s = Suite("rigid6")

    # 1. Ballistic parity (no rotation): both paths integrate gravity exactly
    #    the same way, positions must agree tightly.
    var ib = Inertia3.box(2, 0.3, 0.3, 0.3)
    var qb = QuatBody6(
        Vec3(0, 0, 0), Quat.identity(), Vec3(1, 2, 0), Vec3(0, 0, 0), ib
    )
    var sb = ScrewBody6(
        Motor3.from_translation(Vec3(0, 0, 0)),
        screw_velocity(Vec3(0, 0, 0), Vec3(1, 2, 0)),
        ib,
    )
    var grav = Vec3(0, -9.8, 0) * ib.mass
    for _ in range(100):
        qb.step(0.01, grav, Vec3(0, 0, 0))
        sb.step(0.01, grav, Vec3(0, 0, 0))
    s.check(
        _pt_dist(qb.act(Vec3(0, 0, 0)), sb.act(Vec3(0, 0, 0))) < 1e-4,
        "ballistic action parity",
    )
    s.almost(Float64(qb.pos[1]), Float64(sb.position()[1]), "ballistic height", 1e-4)

    # 2. Free spin, spherical inertia: omega constant on both paths, the pose
    #    action must match tightly (exact rotation exponentials on both sides).
    var isph = Inertia3.sphere(3, 0.5)
    var q2 = QuatBody6(
        Vec3(0, 0, 0), Quat.identity(), Vec3(0, 0, 0), Vec3(1, 2, 3), isph
    )
    var s2 = ScrewBody6(
        Motor3.identity(), screw_velocity(Vec3(1, 2, 3), Vec3(0, 0, 0)), isph
    )
    var l2_start = _len(s2.angular_momentum())
    for _ in range(1000):
        q2.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
        s2.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
    var probe = Vec3(0.3, -0.2, 0.5)
    s.check(
        _pt_dist(q2.act(probe), s2.act(probe)) < 1e-3, "sphere spin action parity"
    )
    s.almost(
        _len(s2.angular_momentum()) / l2_start, 1.0, "sphere |L| conserved", 1e-4
    )
    s.almost(
        _len(q2.angular_momentum()) / l2_start, 1.0, "sphere |L| baseline", 1e-4
    )

    # 3. Torque-free asymmetric box, spin near the max-inertia axis (stable):
    #    conservation gates on the screw path + loose cross-path parity.
    var ibox = Inertia3.box(2, 0.2, 0.3, 0.5)  # ix largest
    var q3 = QuatBody6(
        Vec3(0, 0, 0), Quat.identity(), Vec3(0, 0, 0), Vec3(3, 0.1, 0.05), ibox
    )
    var s3 = ScrewBody6(
        Motor3.identity(),
        screw_velocity(Vec3(3, 0.1, 0.05), Vec3(0, 0, 0)),
        ibox,
    )
    var l3_start = _len(s3.angular_momentum())
    var e3_start = Float64(s3.kinetic_energy())
    for _ in range(500):
        q3.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
        s3.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
    s.almost(
        _len(s3.angular_momentum()) / l3_start, 1.0, "box |L| conserved", 2e-2
    )
    s.almost(
        Float64(s3.kinetic_energy()) / e3_start, 1.0, "box energy conserved", 2e-2
    )
    s.check(
        _pt_dist(q3.act(probe), s3.act(probe)) < 2e-2, "box spin action parity"
    )

    # 4. Impulse at a point: same world impulse, same world point, both paths.
    var q4 = QuatBody6.at_rest(Vec3(0, 0, 0), ib)
    var s4 = ScrewBody6.at_rest(Vec3(0, 0, 0), ib)
    q4.apply_impulse(Vec3(0, 1.5, 0), Vec3(0.3, 0, 0))
    s4.apply_impulse(Vec3(0, 1.5, 0), Vec3(0.3, 0, 0))
    # Analytic: Δv = j/m = 0.75ŷ; Δω = I_z⁻¹ (r × j) = 0.45/0.12 ẑ = 3.75ẑ.
    s.almost(Float64(s4.vel_body()[1]), 0.75, "impulse linear (screw)", 1e-5)
    s.almost(Float64(s4.omega_body()[2]), 3.75, "impulse angular (screw)", 1e-4)
    s.almost(Float64(q4.omega[2]), 3.75, "impulse angular (quat)", 1e-4)
    for _ in range(200):
        q4.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
        s4.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0))
    s.check(
        _pt_dist(q4.act(probe), s4.act(probe)) < 5e-3, "impulse action parity"
    )

    # 5. Constant world torque on a sphere: linear omega growth, path parity.
    var q5 = QuatBody6.at_rest(Vec3(0, 0, 0), isph)
    var s5 = ScrewBody6.at_rest(Vec3(0, 0, 0), isph)
    for _ in range(300):
        q5.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0.6))
        s5.step(0.001, Vec3(0, 0, 0), Vec3(0, 0, 0.6))
    # ω_z(t) = τ t / I = 0.6*0.3/0.3 = 0.6
    s.almost(Float64(q5.omega[2]), 0.6, "torque ramp (quat)", 1e-3)
    var wz = s5._rotation().rotate(s5.omega_body())[2]
    s.almost(Float64(wz), 0.6, "torque ramp (screw)", 1e-3)
    s.check(
        _pt_dist(q5.act(probe), s5.act(probe)) < 5e-3, "torque action parity"
    )

    s.finish()
