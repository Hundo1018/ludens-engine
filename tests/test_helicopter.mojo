# tier: integration
"""Single-rotor helicopter (ROADMAP 17.74, `gameplay.helicopter`).

A 5 kg body (0.3 x 0.3 x 0.8 m box), rotor hub 0.5 m above the centre,
tail rotor 1.5 m behind, main-rotor reaction 0.1 N m per newton of thrust.

  1. Without a tail rotor the fuselage spins against the main rotor
     (yaw rate grows past 1 rad/s in 2 s while hovering).
  2. With `HeliController`: holds y 3 within 2 cm, level (up.y > 0.999),
     heading 0.5 rad within 0.02 after 5 s; the steady tail thrust equals
     the reaction torque / arm (0.1 x 49 / 1.5 = 3.27 N, 5 %).
  3. Cyclic tilts the thrust: 0.1 rad of cyclic pitch turns the thrust
     direction 0.1 rad about body x.
"""

from std.math import atan2, acos
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.helicopter import Helicopter, HeliController

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def heli() raises -> Helicopter:
    return Helicopter(Vec3(0, 0.5, 0, 0), Vec3(0, 0, -1.5, 0), 100.0, 0.3, 30.0, 0.1)


def main() raises:
    var s = Suite("helicopter")
    var cfg = SolverConfig()

    # 1. no tail rotor
    var sc = ContactScene6[QuatBody6]()
    var b = sc.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(5, 0.15, 0.15, 0.4)), Vec3(0.15, 0.15, 0.4, 0), False)
    var h = heli()
    var ctl = HeliController(5.0, 6.0, 4.0, 0.5, 0.2, 5.0, 3.0)
    for _ in range(120):
        ctl.command(h, sc, b, 3.0, 0.0, 9.8, DT)
        h.tail_thrust = 0
        _ = h.apply(sc, b, 0)
        sc.step(DT, G, cfg)
    var spin = sc.angular_velocity(b)[1]
    print("no tail rotor, 2 s: yaw rate", spin)
    s.check(spin < -1.0, "without the tail rotor the fuselage spins against the rotor")

    # 2. controlled hover with heading
    var sc2 = ContactScene6[QuatBody6]()
    var b2 = sc2.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(5, 0.15, 0.15, 0.4)), Vec3(0.15, 0.15, 0.4, 0), False)
    var h2 = heli()
    var ctl2 = HeliController(5.0, 6.0, 4.0, 0.5, 0.2, 5.0, 3.0)
    for _ in range(300):
        ctl2.command(h2, sc2, b2, 3.0, 0.5, 9.8, DT)
        _ = h2.apply(sc2, b2, 0)
        sc2.step(DT, G, cfg)
    var pose = sc2.pose(b2)
    var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
    var fwd = pose.rot.rotate(Vec3(0, 0, 1, 0))
    var heading = atan2(fwd[0], fwd[2])
    var want_tail = Real(0.1 * 5.0 * 9.8 / 1.5)
    print("hover 5 s: y", pose.pos[1], " up.y", up[1], " heading", heading, " tail thrust", h2.tail_thrust, "(", want_tail, ")")
    s.check(abs(pose.pos[1] - 3) < 0.02 and up[1] > 0.999, "holds y 3 level")
    s.check(abs(heading - 0.5) < 0.02, "holds the 0.5 rad heading")
    s.check(abs(abs(h2.tail_thrust) / want_tail - 1) < 0.05, "steady tail thrust cancels the rotor reaction (magnitude; the rotor sits at -z)")

    # 3. cyclic
    var h3 = heli()
    h3.cyclic_pitch = 0.1
    var d = h3.thrust_dir_local()
    var ang = acos(dot(d, Vec3(0, 1, 0, 0)))
    s.check(abs(ang - 0.1) < 1e-5 and abs(d[0]) < 1e-7 and d[2] > 0, "cyclic pitch tilts the thrust about body x")
    s.finish()
