# tier: integration
"""Single-track balance (ROADMAP 17.74): `Bike` + `BikeBalance`.

A 200 kg bike, wheelbase 1.1 m, contacts 0.5 m below the centre of mass,
released leaning 0.1 rad at 60 Hz for 6 s. Steering into the lean holds it
above a minimum speed; the same bike unsteered, or steered at rest, falls.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.bike import Bike, BikeBalance, lean_angle

comptime DT: Real = 1.0 / 60.0
comptime G: Vec3 = Vec3(0, -9.8, 0, 0)


def ride(speed: Real, lean0: Real, kp: Real, kd: Real) raises -> Tuple[Real, Real]:
    """Returns (worst |lean| over 6 s, forward speed at the end)."""
    var cfg = SolverConfig()
    var sc = ContactScene6[QuatBody6]()
    var bike = Bike.standard(1.1, 0.5, 200.0)
    var rot = Quat.from_axis_angle(Vec3(0, 0, 1, 0), -lean0)
    var id = sc.add(QuatBody6.at_rest(Vec3(0, 0.55, 0, 0), Inertia3.box(200, 0.15, 0.45, 0.9)), Vec3(0.02, 0.02, 0.02, 0), False)
    sc.set_friction(id.index(), 0)
    sc.bset.bodies[id.index()].set_pose(Pose6(Vec3(0, 0.55, 0, 0), rot))
    sc.bset.bodies[id.index()].set_velocity(Vec3(0, 0, speed, 0), Vec3(0, 0, 0, 0))
    var ctl = BikeBalance(kp, kd, 0.5)
    bike.drive_speed = speed
    var worst = Real(0)
    for _ in range(360):
        bike.steer = ctl.command(sc, id)
        _ = bike.apply(sc, id, 0)
        sc.step(DT, G, cfg)
        var l = lean_angle(sc, id)
        worst = max(worst, l if l > 0 else -l)
    return (worst, sc.velocity(id)[2])


def main() raises:
    var s = Suite("bike")
    var upright = ride(6, 0, 0, 0)
    s.check(upright[0] < 1e-4 and abs(upright[1] - 6) < 0.05, "an upright, unsteered bike rolls straight at the drive speed")
    var fall = ride(8, 0.1, 0, 0)
    var held = ride(8, 0.1, 1.0, 0.3)
    var rest = ride(0, 0.1, 1.0, 0.3)
    print("worst lean over 6 s from 0.1 rad: unsteered at 8 m/s", fall[0], " balanced at 8 m/s", held[0], " balanced at rest", rest[0])
    s.check(fall[0] > 1.5, "unsteered, the bike falls over")
    s.check(held[0] < 0.2, "steering into the lean holds it within 0.2 rad at 8 m/s")
    s.check(rest[0] > 1.5, "the same controller at rest cannot hold it")
    var slow = ride(2, 0.1, 1.0, 0.3)
    var ok = ride(6, 0.1, 1.0, 0.3)
    print("balanced at 2 m/s", slow[0], " at 6 m/s", ok[0])
    s.check(slow[0] > 1.5 and ok[0] < 0.2, "a minimum speed between 2 and 6 m/s")
    s.finish()
