from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6
from physics.solver6 import ContactScene6


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _run_quat_stack(steps: Int) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var ground_i = Inertia3.box(1, 10, 1, 10)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0), ground_i), Vec3(10, 1, 10), True)
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.35, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.95, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(steps):
        sc.step(DT, G)
    return sc^


def _run_screw_stack(steps: Int) -> ContactScene6[ScrewBody6]:
    var sc = ContactScene6[ScrewBody6]()
    var ground_i = Inertia3.box(1, 10, 1, 10)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, -1, 0), ground_i), Vec3(10, 1, 10), True)
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, 0.35, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, 0.95, 0), bi), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(steps):
        sc.step(DT, G)
    return sc^


def main() raises:
    var s = Suite("solver6")

    # Representation parity of the effective-mass term (frame conversion).
    var q = Quat.from_axis_angle(Vec3(0, 1, 0), 0.7)
    var ib = Inertia3.box(2, 0.2, 0.3, 0.5)
    var qb = QuatBody6(Vec3(1, 2, 3), q, Vec3(0, 0, 0), Vec3(0, 0, 0), ib)
    var sb = ScrewBody6(
        Motor3.from_quat_translation(q, Vec3(1, 2, 3)),
        ScrewBody6.at_rest(Vec3(0, 0, 0), ib).vel,
        ib,
    )
    var r = Vec3(0.3, 0.1, -0.2)
    var n = Vec3(0.6, 0.8, 0)
    s.almost(
        Float64(qb.angular_factor(r, n)),
        Float64(sb.angular_factor(r, n)),
        "angular factor parity",
        1e-5,
    )

    # Box stack dropping on static ground (quat representation):
    # settles with box centres near 0.25 / 0.75 and stays put.
    var sq240 = _run_quat_stack(240)
    var sq300 = _run_quat_stack(300)
    var y1_240 = Float64(sq240.bodies[1].position()[1])
    var y1_300 = Float64(sq300.bodies[1].position()[1])
    var y2_300 = Float64(sq300.bodies[2].position()[1])
    s.check(abs(y1_300 - y1_240) < 5e-3, "quat: bottom box settled")
    s.check(y1_300 > 0.22 and y1_300 < 0.26, "quat: bottom box rest height")
    s.check(y2_300 > 0.70 and y2_300 < 0.78, "quat: top box rest height")
    s.check(_len(sq300.bodies[1].vel) < 0.25, "quat: bounded rest velocity")

    # Same scene on the screw/GA representation.
    var ss240 = _run_screw_stack(240)
    var ss300 = _run_screw_stack(300)
    var z1_240 = Float64(ss240.bodies[1].position()[1])
    var z1_300 = Float64(ss300.bodies[1].position()[1])
    var z2_300 = Float64(ss300.bodies[2].position()[1])
    s.check(abs(z1_300 - z1_240) < 5e-3, "screw: bottom box settled")
    s.check(z1_300 > 0.22 and z1_300 < 0.26, "screw: bottom box rest height")
    s.check(z2_300 > 0.70 and z2_300 < 0.78, "screw: top box rest height")

    # Cross-representation parity: same rest heights (compare by action).
    s.check(abs(y1_300 - z1_300) < 5e-3, "stack parity: bottom box")
    s.check(abs(y2_300 - z2_300) < 5e-3, "stack parity: top box")

    # Known limitation: sequential per-point impulses inject a small rocking
    # omega at impact that rest contacts cannot remove (a solver null mode;
    # fixed by block solve / warm starting / sleeping — ROADMAP Phase 2).
    # Gate: the residual is BOUNDED (no growth) and the tilt stays tiny.
    var probe = Vec3(0.25, 0.25, 0.25)
    var tilt_q = sq300.bodies[1].q.rotate(probe) - probe
    s.check(_len(tilt_q) < 0.02, "quat: bounded resting tilt")
    # (step_soft supersedes this path; see test_softstep6 for the tight
    # rest-quality gates. Here the residual omega only needs to stay bounded.)
    var w300 = _len(sq300.bodies[1].omega)
    s.check(w300 < 0.01, "quat: resting omega bounded")

    s.finish()
