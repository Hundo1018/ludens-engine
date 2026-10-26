# tier: integration
"""A default car (1200 kg, rear-drive, 0.33 m wheels) starts 60 m up a
35-degree ramp, throttle open, and runs 3 s. Surface friction mu sets the
peak friction of the ramp: the tire's effective peak is `tire.mu * mu / 0.5`
(`gameplay/vehicle.mojo` `_REF_MU`), so mu 0.5 is the reference surface.

Prediction, written before the run. Only the two rear wheels drive. The climb
needs the drive force to beat the slope component W sin 35 = 6.75 kN. Traction
control caps the drive torque at 0.9 times the wheel's grip. With rear normal
load N_r near 6.0 kN and effective peak 2 mu, the cap is 0.9 * 2 mu * N_r:

  mu 0.45: cap 4.9 kN < 6.75 kN, the car rolls back.
  mu 0.75: cap 8.2 kN > 6.75 kN, the car climbs.

The predicted threshold is mu 6.75 / (1.8 * 6.0) = 0.63. Probe, before this
test: mu 0.45 moved -5.9 m, mu 0.9 moved +7.3 m in 3 s.

Checks: the car rolls back (x falls by over 3 m) at mu 0.45; it climbs
(x rises by over 3 m) at mu 0.75 and at mu 0.9.
"""

from harness.runner import Suite
from std.math import tan, cos, sin
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import (
    Vehicle,
    VehicleConfig,
    VehicleInput,
    spawn_chassis,
)
from gameplay.vehicle_wheel import RayWheel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _road(mu: Real = 0.5) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(_st(Vec3(0, -1, 0, 0)), Vec3(3000, 1, 3000, 0), True)
    sc.set_friction(f.index(), mu)
    return sc^


def _car(
    mut sc: ContactScene6[QuatBody6], cfg: VehicleConfig, pos: Vec3, rot: Quat = Quat.identity()
) raises -> Vehicle[RayWheel]:
    var id = spawn_chassis(sc, cfg, pos, rot)
    return Vehicle[RayWheel].attach(sc, id, cfg.copy(), RayWheel())


def _run(mut v: Vehicle[RayWheel], mut sc: ContactScene6[QuatBody6], inp: VehicleInput, steps: Int):
    for _ in range(steps):
        v.update(sc, inp, DT)
        sc.step_soft(DT, G)


def _pos(v: Vehicle[RayWheel], sc: ContactScene6[QuatBody6]) -> Vec3:
    return sc.bset.bodies[v.chassis.index()].pos


def _launch(mut v: Vehicle[RayWheel], mut sc: ContactScene6[QuatBody6], speed: Real) raises:
    sc.set_velocity(v.chassis, Vec3(speed, 0, 0, 0), ZERO)
    v.sync_wheels(speed)


def _settle(mut v: Vehicle[RayWheel], mut sc: ContactScene6[QuatBody6]):
    _run(v, sc, VehicleInput.idle(), 120)


def _total_load(v: Vehicle[RayWheel]) -> Real:
    var t = Real(0)
    for w in range(len(v.wheels)):
        t += v.wheels[w].fz
    return t


def _wedge(x0: Real, length_x: Real, rise: Real) -> List[Real]:
    var v = List[Real]()
    for z in range(2):
        var zz = Real(z * 40 - 20)
        for p in [(x0, Real(0)), (x0 + length_x, Real(0)), (x0 + length_x, rise)]:
            v.append(p[0])
            v.append(p[1])
            v.append(zz)
    return v^


def _climb(mu: Real, ang: Real) raises -> Tuple[Real, Real]:
    """Returns (height gained, forward speed) after the throttle run."""
    var sc = _road(mu)
    _ = sc.add_hull(_st(ZERO), _wedge(0, 200, 200 * tan(ang)), True)
    var cs = Vec3(5, 5 * tan(ang), 0, 0) + Vec3(-sin(ang), cos(ang), 0, 0) * 0.74
    var v = _car(sc, VehicleConfig(), cs, Quat.from_axis_angle(Vec3(0, 0, 1, 0), ang))
    _run(v, sc, VehicleInput(0, 1, 0, 0), 60)
    _run(v, sc, VehicleInput(1, 0, 0, 0), 300)
    return (_pos(v, sc)[1] - cs[1], v.forward_speed(sc))



def _slide(mu: Real, ang: Real, steps: Int) raises -> Real:
    """Change in x of the chassis after `steps` of full throttle from rest."""
    var sc = _road(mu)
    var hb = sc.add_hull(_st(ZERO), _wedge(0, 200, 200 * tan(ang)), True)
    sc.set_friction(hb.index(), mu)
    var cs = Vec3(60, 60 * tan(ang), 0, 0) + Vec3(-sin(ang), cos(ang), 0, 0) * 0.74
    var v = _car(sc, VehicleConfig(), cs, Quat.from_axis_angle(Vec3(0, 0, 1, 0), ang))
    var x0 = _pos(v, sc)[0]
    _run(v, sc, VehicleInput(1, 0, 0, 0), steps)
    return _pos(v, sc)[0] - x0


def main() raises:
    var s = Suite("vehicle_slope")
    var ang = Real(35) * Real(3.14159265358979) / Real(180)
    var back = _slide(Real(0.45), ang, 180)
    var up = _slide(Real(0.75), ang, 180)
    var grip = _slide(Real(0.9), ang, 180)
    print("  3 s on 35 deg: dx at mu 0.45", back, " mu 0.75", up, " mu 0.9", grip)
    s.check(back < -3, "mu 0.45: the car rolls back down the ramp")
    s.check(up > 3, "mu 0.75: the car climbs")
    s.check(grip > 3, "mu 0.9: the car climbs")
    s.finish()
