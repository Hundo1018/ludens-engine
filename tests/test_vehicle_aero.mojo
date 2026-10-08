# tier: integration
"""ROADMAP 17.4: aerodynamic drag on the car, with the drag coefficient measured
by the engine's own LBM wind tunnel (ROADMAP 14.4) -- the LBM <-> rigid-body
coupling.

Ordinary: F = 1/2 rho Cd A v^2 opposite the air-relative velocity; a coasting car
decelerates as the analytic aero + rolling-resistance law says; downforce adds
to the wheel loads by 1/2 rho Cl A v^2.
Integration: constant-thrust top speed follows Cd (v_top solves thrust =
1/2 rho Cd A v^2 + rolling) for three coefficients; a boxy and a streamlined
voxel car are run through `fluid.lbm`, the streamlined one measures lower Cd at
equal frontal area, and that measured number (calibrated to a road-car
reference) gives it the higher top speed in the vehicle.
Extreme: Cd = 0 (no drag), absurd Cd (stops, never reverses), headwind and a
tailwind equal to the speed, zero frontal area."""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleConfig, VehicleInput, Aero, spawn_chassis
from gameplay.vehicle_wheel import RayWheel
from gameplay.vehicle_drive import TorqueCurve
from gameplay.vehicle_tunnel import car_cd, CarShape, scaled_cd

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime REST_Y: Real = 0.72
comptime THRUST: Real = 1800.0  # N at the contact patches
comptime AREA: Real = 2.2
comptime CRR: Real = 0.012


def _road() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)),
        Vec3(30000, 1, 3000, 0),
        True,
    )
    return sc^


def _thrust_car(aero: Aero) -> VehicleConfig:
    """AWD, one gear, constant torque: a fixed thrust, so the top speed is set
    by drag alone."""
    var cfg = VehicleConfig()
    cfg.set_drive_layout(True, True)
    cfg.traction_control = False
    cfg.drive.torque = TorqueCurve.constant(220)
    cfg.drive.gears = [Real(1.0)]
    cfg.drive.final_drive = 3.0
    cfg.drive.up_rpm = 1.0e9
    cfg.drive.down_rpm = 0
    cfg.drive.redline_rpm = 1.0e9
    cfg.drive.engine_brake = 0
    cfg.drive.shift_time = 0
    cfg.aero = aero
    return cfg^


def _top_speed(aero: Aero, v0: Real, seconds: Int) raises -> Real:
    var sc = _road()
    var cfg = _thrust_car(aero)
    var id = spawn_chassis(sc, cfg, Vec3(0, REST_Y, 0, 0))
    var v = Vehicle[RayWheel].attach(sc, id, cfg^, RayWheel())
    for _ in range(90):
        v.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
    sc.set_velocity(id, Vec3(v0, 0, 0, 0), ZERO)
    v.sync_wheels(v0)
    var avg = Real(0)
    var n = 0
    for k in range(seconds * 60):
        v.update(sc, VehicleInput(1, 0, 0, 0), DT)
        sc.step_soft(DT, G)
        if k >= seconds * 60 - 120:
            avg += v.forward_speed(sc)
            n += 1
    return avg / Real(n)


def _predicted(cd: Real) -> Real:
    var thrust_net = THRUST - CRR * 1200.0 * 9.8
    return sqrt(thrust_net / (Real(0.5) * 1.225 * cd * AREA))


def main() raises:
    var s = Suite("vehicle_aero")

    # ---- the force law ----
    var a = Aero.from_cd(0.3, 2.0)
    var f = a.drag_force(Vec3(20, 0, 0, 0))
    s.almost(Float64(f[0]), -0.5 * 1.225 * 0.3 * 2.0 * 400.0, "drag = 1/2 rho Cd A v^2, opposing the velocity", 0.05)
    s.almost(Float64(f[1]) + Float64(f[2]), 0.0, "no sideways component for a straight-on flow", 1e-6)
    var f2 = a.drag_force(Vec3(40, 0, 0, 0))
    s.almost(Float64(f2[0] / f[0]), 4.0, "doubling speed quadruples drag", 1e-3)
    var diag = a.drag_force(Vec3(3, 0, 4, 0))
    s.almost(Float64(diag[0] / diag[2]), 3.0 / 4.0, "drag is anti-parallel to the relative velocity", 1e-4)
    var windy = Aero(1.225, 0.3, 2.0, 0, Vec3(-20, 0, 0, 0))  # a 20 m/s headwind
    s.almost(Float64(windy.drag_force(Vec3(0, 0, 0, 0))[0]), -0.5 * 1.225 * 0.3 * 2.0 * 400.0, "a headwind pushes a parked car back", 0.05)
    var tail = Aero(1.225, 0.3, 2.0, 0, Vec3(20, 0, 0, 0))
    s.almost(Float64(length(tail.drag_force(Vec3(20, 0, 0, 0)))), 0.0, "a tailwind at the car's speed: no drag", 1e-6)
    s.almost(Float64(length(Aero.none().drag_force(Vec3(50, 0, 0, 0)))), 0.0, "no aero, no drag", 1e-9)
    s.almost(Float64(length(Aero.from_cd(0.3, 0).drag_force(Vec3(50, 0, 0, 0)))), 0.0, "zero frontal area, no drag", 1e-9)

    # ---- coast-down against the analytic law ----
    var scc = _road()
    var cfgc = VehicleConfig()
    cfgc.drive.engine_brake = 0
    cfgc.aero = Aero.from_cd(0.5, 2.2)
    var idc = spawn_chassis(scc, cfgc, Vec3(0, REST_Y, 0, 0))
    var vc = Vehicle[RayWheel].attach(scc, idc, cfgc^, RayWheel())
    for _ in range(90):
        vc.update(scc, VehicleInput.idle(), DT)
        scc.step_soft(DT, G)
    scc.set_velocity(idc, Vec3(40, 0, 0, 0), ZERO)
    vc.sync_wheels(40)
    for _ in range(60):
        vc.update(scc, VehicleInput.idle(), DT)
        scc.step_soft(DT, G)
    var v_after = vc.forward_speed(scc)
    # integrate m dv/dt = -(1/2 rho Cd A v^2 + Crr m g) with small steps
    var vp = Real(40)
    for _ in range(10000):
        var dec = (Real(0.5) * 1.225 * 0.5 * 2.2 * vp * vp + CRR * 1200.0 * 9.8) / 1200.0
        vp -= dec * 0.0001 * 1.0
    s.almost(Float64(v_after), Float64(vp), "coast-down for 1 s matches the aero + rolling-resistance law", 0.35)

    # ---- downforce adds to the wheel loads ----
    var scd = _road()
    var cfgd = VehicleConfig()
    cfgd.aero = Aero(1.225, 0.3, 2.2, 1.0, ZERO)
    var idd = spawn_chassis(scd, cfgd, Vec3(0, REST_Y, 0, 0))
    var vd = Vehicle[RayWheel].attach(scd, idd, cfgd^, RayWheel())
    for _ in range(90):
        vd.update(scd, VehicleInput.idle(), DT)
        scd.step_soft(DT, G)
    scd.set_velocity(idd, Vec3(40, 0, 0, 0), ZERO)
    vd.sync_wheels(40)
    for _ in range(40):
        vd.update(scd, VehicleInput.idle(), DT)
        scd.step_soft(DT, G)
    var load = Real(0)
    for w in range(4):
        load += vd.wheels[w].fz
    var want = 1200.0 * 9.8 + 0.5 * 1.225 * 1.0 * 2.2 * 40.0 * 40.0 * 0.97
    s.almost(Float64(load), want, "downforce 1/2 rho Cl A v^2 loads the wheels (N)", want * 0.06)

    # ---- top speed follows Cd ----
    var tops = List[Real]()
    for cd in [Real(0.2), Real(0.35), Real(0.7)]:
        var pred = _predicted(cd)
        var vtop = _top_speed(Aero.from_cd(cd, AREA), pred * 0.85, 40)
        tops.append(vtop)
        s.almost(Float64(vtop), Float64(pred), "top speed at Cd " + String(cd) + " matches thrust = drag + rolling (" + String(pred) + " m/s)", Float64(pred) * 0.06)
    s.check(tops[0] > tops[1] and tops[1] > tops[2], "lower Cd, higher top speed")
    s.almost(Float64(tops[0] / tops[2]), Float64(sqrt(Real(0.7) / Real(0.2))), "top speed ratio follows sqrt(Cd ratio)", 0.35)

    # ---- the wind tunnel: LBM Cd of two voxel cars ----
    var boxy = car_cd(CarShape.boxy())
    var sleek = car_cd(CarShape.streamlined())
    print("  LBM Cd: boxy", boxy.cd, " streamlined", sleek.cd, " frontal cells", boxy.area, sleek.area)
    s.eqi(boxy.area, sleek.area, "both shapes present the same frontal area")
    s.check(boxy.cd > 0 and sleek.cd > 0, "the tunnel measures a positive drag")
    s.check(sleek.cd < boxy.cd * 0.97, "the sloped car measures lower Cd than the brick (" + String(sleek.cd) + " vs " + String(boxy.cd) + ")")
    var cd_boxy = Real(0.45)  # calibrate the lattice number to a boxy road-car value
    var cd_sleek = scaled_cd(sleek.cd, boxy.cd, cd_boxy)
    s.check(cd_sleek < cd_boxy, "calibrated: the streamlined car keeps its advantage (" + String(cd_sleek) + " vs 0.45)")
    var v_boxy = _top_speed(Aero.from_cd(cd_boxy, AREA), _predicted(cd_boxy) * 0.85, 40)
    var v_sleek = _top_speed(Aero.from_cd(cd_sleek, AREA), _predicted(cd_sleek) * 0.85, 40)
    print("  top speed: boxy", v_boxy, " streamlined", v_sleek)
    s.check(v_sleek > v_boxy, "the car carrying the LBM-measured lower Cd reaches a higher top speed")
    s.almost(Float64(v_sleek / v_boxy), Float64(sqrt(cd_boxy / cd_sleek)), "and by the factor sqrt(Cd ratio)", 0.025)

    # ---- extremes ----
    var v_free = _top_speed(Aero.from_cd(0.0, AREA), 40, 20)
    var v_cd02 = _top_speed(Aero.from_cd(0.2, AREA), 40, 20)
    s.check(v_free > v_cd02, "Cd = 0: no drag, faster than with drag")
    var scx = _road()
    var cfgx = VehicleConfig()
    cfgx.aero = Aero.from_cd(1000.0, 2.2)
    cfgx.drive.engine_brake = 0
    var idx = spawn_chassis(scx, cfgx, Vec3(0, REST_Y, 0, 0))
    var vx = Vehicle[RayWheel].attach(scx, idx, cfgx^, RayWheel())
    for _ in range(90):
        vx.update(scx, VehicleInput.idle(), DT)
        scx.step_soft(DT, G)
    scx.set_velocity(idx, Vec3(30, 0, 0, 0), ZERO)
    vx.sync_wheels(30)
    var min_v = Real(30)
    for _ in range(180):
        vx.update(scx, VehicleInput.idle(), DT)
        scx.step_soft(DT, G)
        min_v = min(min_v, vx.forward_speed(scx))
    s.check(min_v > -0.5, "absurd Cd: the car stops but is never driven backwards by drag (min " + String(min_v) + " m/s)")
    s.check(vx.forward_speed(scx) < 3.0, "absurd Cd: and it does stop")
    s.check(vx.up_dot(scx) > 0.9, "absurd Cd: no flip")

    s.finish()
