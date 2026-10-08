"""Example 25 -- a car whose drag comes from the engine's own wind tunnel.

Two voxel cars (a brick and one with a sloped hood and a boat tail, same frontal
area) go through the D3Q19 lattice-Boltzmann tunnel (`fluid.lbm`, momentum-
exchange force, ROADMAP 14.4). The measured drag coefficients are calibrated to
a road-car reference and handed to `Aero`; each car is then driven flat out on a
real `ContactScene6` road with a raycast-suspension `Vehicle` (ROADMAP 17.4), a
constant-thrust engine so only drag limits the speed. Prints the measured Cds,
the predicted and simulated top speeds, and a short lap of steering input.

Run:

    pixi run mojo run -I build examples/25_vehicle_wind_tunnel.mojo
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleConfig, VehicleInput, Aero, spawn_chassis
from gameplay.vehicle_wheel import SphereWheel
from gameplay.vehicle_drive import TorqueCurve
from gameplay.vehicle_tunnel import car_cd, CarShape, scaled_cd

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime AREA: Real = 2.2


def _config(cd: Real) -> VehicleConfig:
    var cfg = VehicleConfig()
    cfg.set_drive_layout(True, True)
    cfg.drive.torque = TorqueCurve.constant(220)
    cfg.drive.gears = [Real(1.0)]
    cfg.drive.final_drive = 3.0
    cfg.drive.up_rpm = 1.0e9
    cfg.drive.down_rpm = 0
    cfg.drive.redline_rpm = 1.0e9
    cfg.aero = Aero.from_cd(cd, AREA)
    return cfg^


def _top_speed(cd: Real) raises -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(30000, 1, 3000, 0), True)
    var cfg = _config(cd)
    var id = spawn_chassis(sc, cfg, Vec3(0, 0.72, 0, 0))
    var car = Vehicle[SphereWheel].attach(sc, id, cfg^, SphereWheel())
    for _ in range(60):
        car.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
    sc.set_velocity(id, Vec3(30, 0, 0, 0), Vec3(0, 0, 0, 0))  # start in the last stretch of the run-up
    car.sync_wheels(30)
    for _ in range(80 * 60):
        car.update(sc, VehicleInput(1, 0, 0, 0), DT)
        sc.step_soft(DT, G)
    return car.forward_speed(sc)


def main() raises:
    print("Voxel cars in the LBM wind tunnel (lattice units, Re ~ 35):")
    var boxy = car_cd(CarShape.boxy())
    var sleek = car_cd(CarShape.streamlined())
    print("  brick        Cd(lattice) =", boxy.cd, " frontal cells =", boxy.area)
    print("  streamlined  Cd(lattice) =", sleek.cd, " frontal cells =", sleek.area)
    var cd_boxy = Real(0.45)
    var cd_sleek = scaled_cd(sleek.cd, boxy.cd, cd_boxy)
    print("Calibrated to the brick = 0.45: streamlined Cd =", cd_sleek)

    var thrust = Real(1800)
    for pair in [("brick", cd_boxy), ("streamlined", cd_sleek)]:
        var cd = pair[1]
        var pred = sqrt((thrust - 0.012 * 1200 * 9.8) / (0.5 * 1.225 * cd * AREA))
        print(" ", pair[0], "-> predicted top speed", pred, "m/s, simulated after 80 s", _top_speed(cd), "m/s")
