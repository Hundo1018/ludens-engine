"""Single-track balance (ROADMAP 17.74): lean recovery vs speed and gains."""

from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.bike import Bike, BikeBalance, lean_angle

comptime DT: Real = 1.0 / 60.0
comptime G: Vec3 = Vec3(0, -9.8, 0, 0)


def run(speed: Real, lean0: Real, kp: Real, kd: Real, steps: Int) raises -> Tuple[Real, Real, Real]:
    var cfg = SolverConfig()
    var sc = ContactScene6[QuatBody6]()
    var bike = Bike.standard(1.1, 0.5, 200.0)
    # centre 0.5 + 0.05 above the ground; a tiny box so nothing collides
    var rot = Quat.from_axis_angle(Vec3(0, 0, 1, 0), -lean0)
    var id = sc.add(QuatBody6.at_rest(Vec3(0, 0.55, 0, 0), Inertia3.box(200, 0.15, 0.45, 0.9)), Vec3(0.02, 0.02, 0.02, 0), False)
    sc.set_friction(id.index(), 0)
    sc.bset.bodies[id.index()].set_pose(Pose6(Vec3(0, 0.55, 0, 0), rot))
    sc.bset.bodies[id.index()].set_velocity(Vec3(0, 0, speed, 0), Vec3(0, 0, 0, 0))
    var ctl = BikeBalance(kp, kd, 0.5)
    bike.drive_speed = speed
    var worst = Real(0)
    for _ in range(steps):
        bike.steer = ctl.command(sc, id)
        _ = bike.apply(sc, id, 0)
        sc.step(DT, G, cfg)
        worst = max(worst, abs(lean_angle(sc, id)))
    return (lean_angle(sc, id), worst, sc.velocity(id)[2])


def main() raises:
    print("| speed m/s | kp | kd | lean after 6 s (rad) | worst lean | vz |")
    print("|---:|---:|---:|---:|---:|---:|")
    for sp in [Real(0.0), Real(4.0), Real(5.0), Real(6.0), Real(7.0), Real(8.0), Real(10.0), Real(12.0)]:
        for kp in [Real(0.0), Real(0.6), Real(1.0), Real(1.5)]:
            var r = run(sp, 0.1, kp, kp * 0.3, 360)
            print("|", sp, "|", kp, "|", kp * 0.3, "|", r[0], "|", r[1], "|", r[2], "|")
