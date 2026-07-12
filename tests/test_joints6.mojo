from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6, Body6
from physics.solver6 import ContactScene6, Joint6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _pendulum_period_frames[B: Body6](
    var sc: ContactScene6[B], frames: Int
) -> Tuple[Float64, Float64]:
    """Run and return (period in frames from vx zero-crossings, final |gap|)."""
    var flips = List[Int]()
    var prev_vx = Float64(0)
    for t in range(frames):
        sc.step_soft(DT, G)
        var vx = Float64(sc.bodies[1].velocity_at(sc.bodies[1].position())[0])
        if t > 0 and vx * prev_vx < 0:
            flips.append(t)
        prev_vx = vx
    var period = Float64(0)
    if len(flips) >= 3:
        period = Float64(flips[2] - flips[0])
    var gap = _len(
        sc.bodies[1].act(Vec3(0, 1, 0)) - sc.bodies[0].position()
    )
    return (period, gap)


def main() raises:
    var s = Suite("joints6")
    # Point-mass analytic period: T = 2*pi*sqrt(l/g), l=1, g=9.8.
    var want_frames = 2.0071 * 60.0  # ~120.4 frames
    # Ball-joint bob is a PHYSICAL pendulum (the ball joint leaves spin free,
    # the bob rotates rigidly about the pivot): T *= sqrt(1 + I_com/(m l^2)).
    # half=0.15 box: I_com/(m l^2) = (2/3)(0.0225+0.0225) = 0.03.
    var want_ball = want_frames * sqrt(Float64(1.03))  # ~122.2 frames

    # 1. Ball-joint pendulum (quat representation).
    var sc = ContactScene6[QuatBody6]()
    var anchor_i = Inertia3.box(1, 0.05, 0.05, 0.05)
    var bob_i = Inertia3.box(1, 0.15, 0.15, 0.15)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 2, 0), anchor_i), Vec3(0.05, 0.05, 0.05), True)
    var bob = QuatBody6.at_rest(Vec3(0, 1, 0), bob_i)
    bob.vel = Vec3(0.313, 0, 0)  # theta0 ~ 0.1 rad amplitude
    _ = sc.add(bob, Vec3(0.15, 0.15, 0.15), False)
    _ = sc.add_joint(Joint6.ball(0, 1, Vec3(0, 0, 0), Vec3(0, 1, 0)))
    var r1 = _pendulum_period_frames(sc^, 400)
    print("  ball pendulum: period frames =", r1[0], "gap =", r1[1])
    s.check(r1[0] > 0, "ball pendulum oscillates")
    s.check(
        abs(r1[0] - want_ball) / want_ball < 0.02,
        "ball pendulum period within 2% of analytic",
    )
    s.check(r1[1] < 0.002, "ball joint drift < 2mm")

    # 2. Same pendulum on the screw/GA representation: period parity.
    var ss = ContactScene6[ScrewBody6]()
    _ = ss.add(ScrewBody6.at_rest(Vec3(0, 2, 0), anchor_i), Vec3(0.05, 0.05, 0.05), True)
    var sbob = ScrewBody6.at_rest(Vec3(0, 1, 0), bob_i)
    sbob.apply_impulse(Vec3(0.313, 0, 0), Vec3(0, 1, 0))  # m=1 -> v=0.313
    _ = ss.add(sbob, Vec3(0.15, 0.15, 0.15), False)
    _ = ss.add_joint(Joint6.ball(0, 1, Vec3(0, 0, 0), Vec3(0, 1, 0)))
    var r2 = _pendulum_period_frames(ss^, 400)
    print("  screw pendulum: period frames =", r2[0])
    s.check(abs(r2[0] - r1[0]) <= 2, "pendulum period parity quat vs screw")

    # 3. Distance-joint pendulum: same analytic period.
    var sd = ContactScene6[QuatBody6]()
    _ = sd.add(QuatBody6.at_rest(Vec3(0, 2, 0), anchor_i), Vec3(0.05, 0.05, 0.05), True)
    var dbob = QuatBody6.at_rest(Vec3(0, 1, 0), Inertia3.box(1, 0.05, 0.05, 0.05))
    dbob.vel = Vec3(0.313, 0, 0)
    _ = sd.add(dbob, Vec3(0.05, 0.05, 0.05), False)
    _ = sd.add_joint(Joint6.distance(0, 1, Vec3(0, 0, 0), Vec3(0, 0, 0), 1))
    var r3 = _pendulum_period_frames(sd^, 400)
    print("  distance pendulum: period frames =", r3[0])
    s.check(
        abs(r3[0] - want_frames) / want_frames < 0.02,
        "distance pendulum period within 2%",
    )

    # 4. Hinge (axis z): an out-of-plane kick must be suppressed while the
    #    in-plane swing continues.
    var sh = ContactScene6[QuatBody6]()
    _ = sh.add(QuatBody6.at_rest(Vec3(0, 2, 0), anchor_i), Vec3(0.05, 0.05, 0.05), True)
    var hbob = QuatBody6.at_rest(Vec3(0, 1, 0), bob_i)
    hbob.vel = Vec3(0.313, 0, 0.3)  # in-plane swing + out-of-plane kick
    _ = sh.add(hbob, Vec3(0.15, 0.15, 0.15), False)
    _ = sh.add_joint(Joint6.hinge(0, 1, Vec3(0, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)))
    var max_z_transient = Float64(0)
    var max_z_settled = Float64(0)
    var max_x = Float64(0)
    for t in range(300):
        sh.step_soft(DT, G)
        var p = sh.bodies[1].position()
        var az = abs(Float64(p[2]))
        if t < 100:
            if az > max_z_transient:
                max_z_transient = az
        else:
            if az > max_z_settled:
                max_z_settled = az
        if abs(Float64(p[0])) > max_x:
            max_x = abs(Float64(p[0]))
    print(
        "  hinge: z transient =", max_z_transient,
        "z settled =", max_z_settled, "max |x| =", max_x,
    )
    s.check(max_x > 0.05, "hinge: in-plane swing alive")
    s.check(max_z_transient < 0.06, "hinge: kick absorbed softly")
    s.check(max_z_settled < 0.01, "hinge: out-of-plane suppressed after transient")

    s.finish()
