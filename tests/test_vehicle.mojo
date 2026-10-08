# tier: integration
"""ROADMAP 17.4: raycast vehicles driving on a real ContactScene6.

Ordinary: a parked car settles to a ride height whose four wheel loads sum to
its weight; flat-road acceleration (gears change, stays straight and level);
braking distance close to v^2 / (2 mu g) and ABS beats locked wheels; a
steady turn follows the bicycle-model radius; reverse; the handbrake.
Integration: holds a 15-degree slope on the brake and rolls off it without,
climbs 20 degrees under throttle; drops from 2 m and lands without the chassis
touching the road; drives off a ramp (airborne frames) and lands upright; rear-
ends another car (momentum shared) and shoves a crate; four cars stepped as a
set; crosses a bumpy heightfield; limited-slip beats open on a split-mu road.
Extreme: rollover at very high grip; a car on its roof (no wheel contact, no
tire force); all wheels airborne (no horizontal force, wheels wind down / rev
bounded); mu = 0 (throttle spins the wheels, brakes do nothing); very high mu;
teleport mid-drive; non-finite chassis state (counted, nothing applied); bad
configs raise."""

from harness.runner import Suite
from std.math import tan, cos, sin, sqrt, atan2
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6, Pose6
from physics.solver6 import ContactScene6
from diag.counters import VEHICLE_FORCE_DROPPED
from gameplay.vehicle import (
    Vehicle,
    VehicleSet,
    VehicleConfig,
    VehicleInput,
    Aero,
    WheelConfig,
    spawn_chassis,
)
from gameplay.vehicle_wheel import RayWheel, SphereWheel, CapsuleWheel
from gameplay.vehicle_drive import DIFF_OPEN, DIFF_LSD

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime REST_Y: Real = 0.72  # approx. chassis height on a flat road


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


def _brake_distance(abs_on: Bool, mu: Real, speed: Real) raises -> Tuple[Real, Real, Real]:
    """(distance, steps taken, peak deceleration in g) of a full-brake stop."""
    var sc = _road(mu)
    var cfg = VehicleConfig()
    cfg.abs_on = abs_on
    var v = _car(sc, cfg, Vec3(0, REST_Y, 0, 0))
    _settle(v, sc)
    _launch(v, sc, speed)
    var x0 = _pos(v, sc)[0]
    var prev = speed
    var peak = Real(0)
    var steps = 0
    for k in range(900):
        v.update(sc, VehicleInput(0, 1, 0, 0), DT)
        sc.step_soft(DT, G)
        var sp = v.forward_speed(sc)
        peak = max(peak, (prev - sp) / DT / 9.8)
        prev = sp
        steps = k
        if sp < 0.1:
            break
    return (_pos(v, sc)[0] - x0, Real(steps), peak)


def main() raises:
    var s = Suite("vehicle")

    # ================= ORDINARY =================
    # ---- parked: ride height and load ----
    var sc0 = _road()
    var cfg0 = VehicleConfig()
    var v0 = _car(sc0, cfg0, Vec3(0, 0.9, 0, 0))
    _settle(v0, sc0)
    var p0 = _pos(v0, sc0)
    s.check(v0.grounded_count() == 4, "parked: four wheels on the road")
    s.check(p0[1] > 0.6 and p0[1] < 0.85, "parked: sensible ride height (" + String(p0[1]) + ")")
    s.almost(Float64(_total_load(v0)), 1200.0 * 9.8, "parked: wheel loads sum to the weight", 120.0)
    s.almost(Float64(v0.wheels[0].fz), Float64(v0.wheels[2].fz), "parked: symmetric car, equal front and rear load", 150.0)
    s.almost(Float64(v0.wheels[0].fz), Float64(v0.wheels[1].fz), "parked: left and right wheels carry the same load", 30.0)
    _run(v0, sc0, VehicleInput.idle(), 300)
    s.almost(Float64(_pos(v0, sc0)[0]), Float64(p0[0]), "parked: does not creep in 5 s", 0.02)

    # ---- accelerate ----
    var sc1 = _road()
    var v1 = _car(sc1, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(v1, sc1)
    var max_tilt = Real(0)
    var gear_max = 1
    for _ in range(360):
        v1.update(sc1, VehicleInput(1, 0, 0, 0), DT)
        sc1.step_soft(DT, G)
        max_tilt = max(max_tilt, 1 - v1.up_dot(sc1))
        gear_max = max(gear_max, v1.gear)
    var p1 = _pos(v1, sc1)
    s.check(v1.forward_speed(sc1) > 22.0, "accelerate: >22 m/s after 6 s (" + String(v1.forward_speed(sc1)) + ")")
    s.check(p1[0] > 60.0, "accelerate: covered ground (" + String(p1[0]) + " m)")
    s.check(abs(p1[2]) < 0.3, "accelerate: stays straight (z = " + String(p1[2]) + ")")
    s.check(max_tilt < 0.02, "accelerate: stays level")
    s.check(gear_max >= 2, "accelerate: the gearbox shifts up (gear " + String(gear_max) + ")")
    s.check(v1.rpm < 7000, "accelerate: rpm bounded by the redline logic")
    s.check(v1.wheels[2].omega * 0.33 > 0, "accelerate: driven wheels spin forward")

    # ---- braking distance ----
    var b_abs = _brake_distance(True, 0.5, 20)
    var b_lock = _brake_distance(False, 0.5, 20)
    var ideal = 20.0 * 20.0 / (2.0 * 1.0 * 9.8)  # tire mu 1 on the reference road
    s.check(Float64(b_abs[0]) > ideal * 0.95 and Float64(b_abs[0]) < ideal * 1.35, "brake: stopping distance near v^2/(2 mu g) = " + String(ideal) + " (got " + String(b_abs[0]) + ")")
    s.check(b_abs[0] < b_lock[0], "brake: ABS stops shorter than locked wheels (" + String(b_abs[0]) + " vs " + String(b_lock[0]) + ")")
    s.check(b_abs[2] < 1.3, "brake: deceleration bounded by grip (peak " + String(b_abs[2]) + " g)")
    var b_half = _brake_distance(True, 0.5, 10)
    s.check(b_half[0] < b_abs[0] * 0.4, "brake: distance scales with v^2 (" + String(b_half[0]) + " at 10 m/s)")

    # ---- steady turn: bicycle-model radius ----
    var sc2 = _road()
    var v2 = _car(sc2, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(v2, sc2)
    _launch(v2, sc2, 10)
    _run(v2, sc2, VehicleInput(0.1, 0, 0.5, 0), 120)  # settle the turn
    var pa = _pos(v2, sc2)
    var qa = sc2.bset.bodies[v2.chassis.index()].q
    var ha = qa.rotate(Vec3(1, 0, 0, 0))
    _run(v2, sc2, VehicleInput(0.1, 0, 0.5, 0), 60)
    var pb = _pos(v2, sc2)
    var hb = sc2.bset.bodies[v2.chassis.index()].q.rotate(Vec3(1, 0, 0, 0))
    var dyaw = abs(atan2(hb[2] * ha[0] - hb[0] * ha[2], hb[0] * ha[0] + hb[2] * ha[2]))  # heading change over 1 s
    var radius = v2.speed(sc2) * 1.0 / (dyaw + 1e-6)
    var delta = Real(0.275) / Real(1 + (10.0 / 30.0) * (10.0 / 30.0))
    var r_bike = Real(2.7) / tan(delta)
    s.check(radius > r_bike * 0.8 and radius < r_bike * 2.2, "turn: radius " + String(radius) + " m vs bicycle model " + String(r_bike) + " m (understeer allowed)")
    s.check(pb[2] != pa[2], "turn: the car actually leaves the straight line")
    s.check(v2.up_dot(sc2) > 0.97, "turn: low-speed turn stays level")

    # ---- reverse ----
    var sc3 = _road()
    var v3 = _car(sc3, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(v3, sc3)
    _run(v3, sc3, VehicleInput(-1, 0, 0, 0), 180)
    s.check(_pos(v3, sc3)[0] < -3.0, "reverse: throttle back from a standstill drives backwards (" + String(_pos(v3, sc3)[0]) + " m)")
    s.check(v3.gear < 0, "reverse: reverse gear selected")
    _run(v3, sc3, VehicleInput(1, 0, 0, 0), 240)
    s.check(v3.forward_speed(sc3) > 0.5, "reverse: throttle forward brakes then drives forward again")
    s.check(v3.gear > 0, "reverse: forward gear re-selected")

    # ---- handbrake ----
    var sc4 = _road()
    var v4 = _car(sc4, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(v4, sc4)
    _launch(v4, sc4, 15)
    _run(v4, sc4, VehicleInput(0, 0, 0, 1), 60)
    s.check(v4.forward_speed(sc4) < 15.0 - 3.0, "handbrake: rear wheels braking slows the car (" + String(v4.forward_speed(sc4)) + ")")

    # ================= INTEGRATION =================
    # ---- 15 degree slope: hold on the brake, roll without ----
    var ang = Real(0.261799)
    var hold_start = Vec3(10, 10 * tan(ang), 0, 0) + Vec3(-sin(ang), cos(ang), 0, 0) * 0.74
    var hold_rot = Quat.from_axis_angle(Vec3(0, 0, 1, 0), ang)
    var scs = _road()
    _ = scs.add_hull(_st(ZERO), _wedge(0, 60, 60 * tan(ang)), True)
    var vh = _car(scs, VehicleConfig(), hold_start, hold_rot)
    _run(vh, scs, VehicleInput(0, 1, 0, 0), 60)  # settle with the brake on
    var ph = _pos(vh, scs)
    _run(vh, scs, VehicleInput(0, 1, 0, 0), 240)
    s.check(vh.grounded_count() == 4, "slope hold: four wheels on the ramp")
    s.check(length(_pos(vh, scs) - ph) < 0.15, "slope hold: brakes hold a 15-degree slope for 4 s (moved " + String(length(_pos(vh, scs) - ph)) + " m)")
    var scr = _road()
    _ = scr.add_hull(_st(ZERO), _wedge(0, 60, 60 * tan(ang)), True)
    var vr = _car(scr, VehicleConfig(), hold_start, hold_rot)
    _run(vr, scr, VehicleInput(0, 0, 0, 0), 60)
    var pr = _pos(vr, scr)
    _run(vr, scr, VehicleInput(0, 0, 0, 0), 180)
    s.check(vr.forward_speed(scr) < -2.0, "slope: without brakes it rolls back down (" + String(vr.forward_speed(scr)) + ")")
    s.check(_pos(vr, scr)[0] < pr[0] - 3.0, "slope: and travels down the slope")

    # ---- climb 20 degrees ----
    var ang2 = Real(0.349066)
    var scc = _road()
    _ = scc.add_hull(_st(ZERO), _wedge(0, 200, 200 * tan(ang2)), True)
    var cs = Vec3(5, 5 * tan(ang2), 0, 0) + Vec3(-sin(ang2), cos(ang2), 0, 0) * 0.74
    var vc = _car(scc, VehicleConfig(), cs, Quat.from_axis_angle(Vec3(0, 0, 1, 0), ang2))
    _run(vc, scc, VehicleInput(0, 1, 0, 0), 60)
    _run(vc, scc, VehicleInput(1, 0, 0, 0), 300)
    s.check(_pos(vc, scc)[1] > cs[1] + 4.0, "climb: gains height on a 20-degree slope (" + String(_pos(vc, scc)[1] - cs[1]) + " m)")
    s.check(vc.forward_speed(scc) > 3.0 and vc.grounded_count() >= 3, "climb: still driving up")

    # ---- drop from 2 m ----
    var scd = _road()
    var vd = _car(scd, VehicleConfig(), Vec3(0, 2.7, 0, 0))
    var min_y = Real(10)
    var air_frames = 0
    for _ in range(240):
        vd.update(scd, VehicleInput.idle(), DT)
        scd.step_soft(DT, G)
        min_y = min(min_y, _pos(vd, scd)[1])
        if vd.grounded_count() == 0:
            air_frames += 1
    s.check(air_frames > 20, "drop: airborne for the fall (" + String(air_frames) + " frames)")
    s.check(min_y > 0.42, "drop: the suspension absorbs it, chassis never reaches the road (min y " + String(min_y) + ")")
    s.check(vd.grounded_count() == 4 and vd.speed(scd) < 0.1, "drop: settles on four wheels")
    s.almost(Float64(_pos(vd, scd)[1]), Float64(p0[1]), "drop: same ride height as the parked car", 0.02)
    s.almost(Float64(vd.up_dot(scd)), 1.0, "drop: lands level", 5e-3)

    # ---- jump off a ramp ----
    var scj = _road()
    var ang3 = Real(0.2618)
    _ = scj.add_hull(_st(ZERO), _wedge(20, 20, 20 * tan(ang3)), True)  # ramp x in [20, 40], then the road
    var vj = _car(scj, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vj, scj)
    _launch(vj, scj, 18)
    var air = 0
    var peak_y = Real(0)
    for _ in range(420):
        vj.update(scj, VehicleInput(0.5, 0, 0, 0), DT)
        scj.step_soft(DT, G)
        if vj.grounded_count() == 0:
            air += 1
        peak_y = max(peak_y, _pos(vj, scj)[1])
    s.check(air > 15, "jump: airborne after the ramp (" + String(air) + " frames)")
    s.check(peak_y > 2.0, "jump: gains height (" + String(peak_y) + " m)")
    s.check(vj.up_dot(scj) > 0.95 and vj.grounded_count() == 4, "jump: lands upright on four wheels")
    s.check(_pos(vj, scj)[0] > 40.0, "jump: keeps going past the ramp")

    # ---- rear-end collision: momentum is shared ----
    var scm = _road()
    var cm = VehicleConfig()
    var va = _car(scm, cm, Vec3(-12, REST_Y, 0, 0))
    var vb = _car(scm, cm, Vec3(0, REST_Y, 0, 0))
    _settle(va, scm)
    _settle(vb, scm)
    _launch(va, scm, 14)
    var mom0 = Real(1200) * 14
    for _ in range(240):
        va.update(scm, VehicleInput.idle(), DT)
        vb.update(scm, VehicleInput.idle(), DT)
        scm.step_soft(DT, G)
    var vxa = va.forward_speed(scm)
    var vxb = vb.forward_speed(scm)
    s.check(vxb > 3.0, "collision: the struck car is shoved forward (" + String(vxb) + " m/s)")
    s.check(vxa < 14.0 and vxa < vxb + 6.0, "collision: the striking car slows (" + String(vxa) + " m/s)")
    s.check((vxa + vxb) * 1200.0 > mom0 * 0.5 and (vxa + vxb) * 1200.0 < mom0 * 1.2, "collision: momentum roughly shared (" + String((vxa + vxb) * 1200.0 / mom0) + " of initial; rolling losses + drag)")
    s.check(va.up_dot(scm) > 0.9 and vb.up_dot(scm) > 0.9, "collision: both stay upright")

    # ---- push a crate ----
    var scp = _road()
    var vp = _car(scp, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vp, scp)
    var crate = scp.add(QuatBody6.at_rest(Vec3(8, 0.4, 0, 0), Inertia3.box(60, 0.4, 0.4, 0.4)), Vec3(0.4, 0.4, 0.4, 0), False)
    _launch(vp, scp, 8)
    _run(vp, scp, VehicleInput(0.3, 0, 0, 0), 150)
    s.check(scp.bset.bodies[crate.index()].pos[0] > 9.5, "crate: shoved ahead of the car (" + String(scp.bset.bodies[crate.index()].pos[0]) + ")")
    s.check(scp.bset.bodies[crate.index()].vel[0] > 2.0, "crate: moving")

    # ---- driving over a dynamic plank: Newton's third law at the wheels ----
    var scl = _road()
    var plank = scl.add(QuatBody6.at_rest(Vec3(0, 0.1, 0, 0), Inertia3.box(40, 3, 0.1, 3)), Vec3(3, 0.1, 3, 0), False)
    var vl = _car(scl, VehicleConfig(), Vec3(0, 0.2 + 0.74, 0, 0))
    _run(vl, scl, VehicleInput.idle(), 120)
    s.check(vl.grounded_count() == 4 and vl.wheels[0].ground == plank.index(), "plank: wheels report the plank as ground")
    s.check(scl.bset.bodies[plank.index()].pos[1] > 0.07, "plank: the car's weight is carried by the road under it, not sunk through (y = " + String(scl.bset.bodies[plank.index()].pos[1]) + ")")

    # ---- a set of four cars, one shared pose list ----
    var scf = _road()
    var fleet = VehicleSet[RayWheel]()
    var ins = List[VehicleInput]()
    for k in range(4):
        var cfgk = VehicleConfig()
        var idk = spawn_chassis(scf, cfgk, Vec3(0, REST_Y, Real(k) * 6, 0))
        _ = fleet.add(Vehicle[RayWheel].attach(scf, idk, cfgk^, RayWheel()))
        ins.append(VehicleInput(Real(0.3) + Real(k) * 0.2, 0, 0, 0))
    for _ in range(300):
        fleet.update(scf, ins, DT)
        scf.step_soft(DT, G)
    var speeds_ok = True
    for k in range(3):
        if fleet.items[k + 1].forward_speed(scf) <= fleet.items[k].forward_speed(scf):
            speeds_ok = False
    s.check(speeds_ok, "set: more throttle, more speed, across four cars")
    s.check(fleet.items[3].forward_speed(scf) > 10.0 and fleet.items[0].up_dot(scf) > 0.99, "set: all driving, level")

    # ---- heightfield terrain ----
    var sct = ContactScene6[QuatBody6]()
    var hts = List[Real]()
    var nxh = 81
    for iz in range(nxh):
        for ix in range(nxh):
            var wx = Real(ix) * 2.0
            hts.append(0.25 * sin(wx * 0.5) + 0.15 * sin(Real(iz) * 0.9))
    _ = sct.add_heightfield(_st(ZERO), hts, nxh, nxh, 2.0, -40.0, -40.0)
    var vt = _car(sct, VehicleConfig(), Vec3(-30, 1.2, 0, 0))
    _run(vt, sct, VehicleInput.idle(), 120)
    var x_start = _pos(vt, sct)[0]
    var tilt_t = Real(0)
    for _ in range(420):
        vt.update(sct, VehicleInput(0.6, 0, 0, 0), DT)
        sct.step_soft(DT, G)
        tilt_t = max(tilt_t, 1 - vt.up_dot(sct))
    s.check(_pos(vt, sct)[0] - x_start > 25.0, "terrain: drives across the bumpy field (" + String(_pos(vt, sct)[0] - x_start) + " m)")
    s.check(tilt_t < 0.15 and vt.grounded_count() >= 1, "terrain: stays on its wheels")

    # ---- split-mu road: limited slip beats open ----
    var dist_open = Real(0)
    var dist_lsd = Real(0)
    for kind in [DIFF_OPEN, DIFF_LSD]:
        var scx = ContactScene6[QuatBody6]()
        var fl = scx.add(_st(Vec3(0, -1, -10, 0)), Vec3(500, 1, 10, 0), True)  # z in [-20, 0]: the left lane, tarmac
        var fr = scx.add(_st(Vec3(0, -1, 10, 0)), Vec3(500, 1, 10, 0), True)  # z in [0, 20]: the right lane, ice-like
        scx.set_friction(fl.index(), 0.9)
        scx.set_friction(fr.index(), 0.08)
        var cfgx = VehicleConfig()
        cfgx.traction_control = False
        cfgx.drive.diff_kind = kind
        cfgx.drive.diff_preload = 400
        cfgx.drive.diff_lock = 200
        cfgx.drive.diff_max = 4000
        var vx = _car(scx, cfgx, Vec3(0, REST_Y, 0, 0))
        _run(vx, scx, VehicleInput.idle(), 120)
        _run(vx, scx, VehicleInput(0.8, 0, 0, 0), 240)
        if kind == DIFF_OPEN:
            dist_open = _pos(vx, scx)[0]
        else:
            dist_lsd = _pos(vx, scx)[0]
    s.check(dist_lsd > dist_open * 1.05, "diff: limited slip covers more ground than open on a split-mu road (" + String(dist_lsd) + " vs " + String(dist_open) + " m)")

    # ---- seam at vehicle level: the same drive with each wheel cast ----
    var xs = List[Real]()
    for variant in range(3):
        var scw = _road()
        var cfgw = VehicleConfig()
        var idw = spawn_chassis(scw, cfgw, Vec3(0, REST_Y, 0, 0))
        if variant == 0:
            var vw = Vehicle[RayWheel].attach(scw, idw, cfgw^, RayWheel())
            _run(vw, scw, VehicleInput.idle(), 90)
            _run(vw, scw, VehicleInput(0.7, 0, 0.3, 0), 240)
            xs.append(scw.bset.bodies[idw.index()].pos[0])
            xs.append(scw.bset.bodies[idw.index()].pos[2])
        elif variant == 1:
            var vw = Vehicle[SphereWheel].attach(scw, idw, cfgw^, SphereWheel())
            for kk in range(330):
                vw.update(scw, VehicleInput.idle() if kk < 90 else VehicleInput(0.7, 0, 0.3, 0), DT)
                scw.step_soft(DT, G)
            xs.append(scw.bset.bodies[idw.index()].pos[0])
            xs.append(scw.bset.bodies[idw.index()].pos[2])
        else:
            var vw = Vehicle[CapsuleWheel].attach(scw, idw, cfgw^, CapsuleWheel())
            for kk in range(330):
                vw.update(scw, VehicleInput.idle() if kk < 90 else VehicleInput(0.7, 0, 0.3, 0), DT)
                scw.step_soft(DT, G)
            xs.append(scw.bset.bodies[idw.index()].pos[0])
            xs.append(scw.bset.bodies[idw.index()].pos[2])
    s.almost(Float64(xs[2]), Float64(xs[0]), "wheel-cast seam: sphere sweep drives the same path as the ray (x)", Float64(xs[0]) * 0.01)
    s.almost(Float64(xs[4]), Float64(xs[0]), "wheel-cast seam: capsule sweep drives the same path as the ray (x)", Float64(xs[0]) * 0.01)
    s.almost(Float64(xs[3]), Float64(xs[1]), "wheel-cast seam: sphere sweep, lateral", 0.05 + Float64(abs(xs[1])) * 0.01)
    s.almost(Float64(xs[5]), Float64(xs[1]), "wheel-cast seam: capsule sweep, lateral", 0.05 + Float64(abs(xs[1])) * 0.01)

    # ---- over a kerb the sweeps and the ray genuinely differ (documented) ----
    var sck = _road()
    _ = sck.add(_st(Vec3(30, 0.06, 0, 0)), Vec3(30, 0.06, 20, 0), True)  # a 12 cm raised road from x = 0
    var cfgk = VehicleConfig()
    var idk2 = spawn_chassis(sck, cfgk, Vec3(-6, REST_Y, 0, 0))
    var vk = Vehicle[SphereWheel].attach(sck, idk2, cfgk^, SphereWheel())
    sck.set_velocity(idk2, Vec3(6, 0, 0, 0), ZERO)
    vk.sync_wheels(6)
    var k_up = False
    for _ in range(240):
        vk.update(sck, VehicleInput(0.5, 0, 0, 0), DT)
        sck.step_soft(DT, G)
        if sck.bset.bodies[idk2.index()].pos[1] > REST_Y + 0.07:
            k_up = True
    s.check(k_up and vk.up_dot(sck) > 0.97 and sck.bset.bodies[idk2.index()].pos[0] > 10.0, "kerb: the sphere-cast car climbs a 12 cm kerb and keeps going")

    # ================= EXTREME =================
    # ---- rollover at very high grip ----
    var scv = _road(5.0)
    var vv = _car(scv, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vv, scv)
    _launch(vv, scv, 25)
    var min_up = Real(1)
    for k in range(360):
        vv.update(scv, VehicleInput(0.3, 0, Real(1.0) if k > 10 else Real(0.0), 0), DT)
        scv.step_soft(DT, G)
        min_up = min(min_up, vv.up_dot(scv))
    s.check(min_up < 0.3, "rollover: hard turn at mu_eff = 10 trips the car over (min up " + String(min_up) + ")")
    var pv = _pos(vv, scv)
    s.check(pv[0] == pv[0] and abs(pv[1]) < 50 and length(sc_vel(vv, scv)) < 60, "rollover: state stays finite and bounded")
    s.check(vv.is_flipped(scv) == (vv.up_dot(scv) < 0.3), "rollover: is_flipped agrees with the up vector")
    _run(vv, scv, VehicleInput.idle(), 600)
    s.check(vv.speed(scv) < 0.5, "rollover: wreck comes to rest (" + String(vv.speed(scv)) + " m/s)")

    # ---- upside down: no wheel contact, no tire force ----
    var sci = _road()
    var vi = _car(sci, VehicleConfig(), Vec3(0, 2.0, 0, 0), Quat.from_axis_angle(Vec3(1, 0, 0, 0), 3.14159265))
    var tire_max = Real(0)
    for _ in range(300):
        vi.update(sci, VehicleInput(1, 0, 0.5, 0), DT)
        sci.step_soft(DT, G)
        for w in range(4):
            tire_max = max(tire_max, abs(vi.wheels[w].fx) + abs(vi.wheels[w].fy))
    s.check(vi.is_flipped(sci), "roof down: reported flipped")
    s.check(vi.grounded_count() == 0 and tire_max == 0, "roof down: wheels in the air make no tire force")
    s.check(_pos(vi, sci)[1] > 0.2 and _pos(vi, sci)[1] < 1.2, "roof down: rests on its roof, not through the road (y = " + String(_pos(vi, sci)[1]) + ")")

    # ---- all wheels airborne ----
    var sca = _road()
    var cfga = VehicleConfig()
    cfga.aero = Aero.none()
    var va2 = _car(sca, cfga, Vec3(0, 40, 0, 0))
    sca.set_velocity(va2.chassis, Vec3(10, 0, 0, 0), ZERO)
    var om_max = Real(0)
    for _ in range(90):
        va2.update(sca, VehicleInput(1, 0, 0.5, 0), DT)
        sca.step_soft(DT, G)
        om_max = max(om_max, va2.wheels[2].omega)
    s.check(va2.grounded_count() == 0, "airborne: no wheel contact")
    s.almost(Float64(sca.bset.bodies[va2.chassis.index()].vel[0]), 10.0, "airborne: no horizontal force without drag", 0.01)
    s.almost(Float64(sca.bset.bodies[va2.chassis.index()].vel[1]), -9.8 * 1.5, "airborne: pure free fall", 0.3)
    s.check(om_max > 20 and om_max < 400, "airborne: driven wheels rev up but stay bounded by the rev limiter (" + String(om_max) + " rad/s)")
    var vb2 = _car(sca, cfga, Vec3(100, 40, 0, 0))
    vb2.sync_wheels(30)
    _run(vb2, sca, VehicleInput.idle(), 600)
    s.check(vb2.wheels[0].omega < 30.0 / 0.33 * 0.7, "airborne: undriven wheels wind down through bearing friction")

    # ---- mu = 0 ----
    var sc0m = _road(0.0)
    var cfgi = VehicleConfig()
    cfgi.traction_control = False
    var vi0 = _car(sc0m, cfgi, Vec3(0, REST_Y, 0, 0))
    _settle(vi0, sc0m)
    _run(vi0, sc0m, VehicleInput(1, 0, 0, 0), 180)
    s.check(vi0.speed(sc0m) < 0.5, "mu = 0: throttle gets nowhere (" + String(vi0.speed(sc0m)) + " m/s)")
    s.check(vi0.wheels[2].omega * 0.33 > 3.0, "mu = 0: the driven wheels spin (rim speed " + String(vi0.wheels[2].omega * 0.33) + " m/s)")
    var sc0t = _road(0.0)
    var vit = _car(sc0t, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vit, sc0t)
    _run(vit, sc0t, VehicleInput(1, 0, 0, 0), 120)
    s.check(vit.wheels[2].omega * 0.33 < 0.5, "mu = 0: traction control sees no grip and cuts the torque instead of spinning")
    var sc0b = _road(0.0)
    var vi1 = _car(sc0b, cfgi, Vec3(0, REST_Y, 0, 0))
    _settle(vi1, sc0b)
    _launch(vi1, sc0b, 15)
    _run(vi1, sc0b, VehicleInput(0, 1, 0.8, 0), 120)
    s.check(vi1.forward_speed(sc0b) > 13.0, "mu = 0: brakes and steering do nothing on ice (" + String(vi1.forward_speed(sc0b)) + " m/s)")
    s.check(vi1.up_dot(sc0b) > 0.99, "mu = 0: stays level")

    # ---- very high mu ----
    var hi = _brake_distance(True, 50.0, 20)
    s.check(hi[0] < b_abs[0] * 0.9 and hi[0] > 8.0, "mu = 100: shorter stop, limited by brake torque (" + String(hi[0]) + " m)")
    s.check(hi[2] > 1.5 and hi[2] < 4.0, "mu = 100: deceleration set by the brakes (" + String(hi[2]) + " g)")
    var sch = _road(50.0)
    var vh2 = _car(sch, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vh2, sch)
    _run(vh2, sch, VehicleInput(1, 0, 0, 0), 240)
    s.check(vh2.forward_speed(sch) > 20.0 and vh2.up_dot(sch) > 0.99, "mu = 100: accelerates hard, stays level")

    # ---- teleport mid-drive ----
    var sct2 = _road()
    var vt2 = _car(sct2, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vt2, sct2)
    _run(vt2, sct2, VehicleInput(1, 0, 0, 0), 180)
    var sp_before = vt2.speed(sct2)
    sct2.teleport(vt2.chassis, Pose6(Vec3(500, REST_Y + 0.5, 300, 0), Quat.identity()))
    var worst_speed = Real(0)
    for _ in range(240):
        vt2.update(sct2, VehicleInput.idle(), DT)
        sct2.step_soft(DT, G)
        worst_speed = max(worst_speed, vt2.speed(sct2))
    s.check(worst_speed < sp_before * 1.05 + 0.5, "teleport: no velocity spike (" + String(worst_speed) + " vs " + String(sp_before) + ")")
    s.check(vt2.grounded_count() == 4 and vt2.up_dot(sct2) > 0.99, "teleport: lands on its wheels at the new place")
    s.check(sct2.counters.get(VEHICLE_FORCE_DROPPED) == 0, "teleport: nothing had to be dropped")
    sct2.set_velocity(vt2.chassis, ZERO, ZERO)
    vt2.sync_wheels(0)
    sct2.teleport(vt2.chassis, Pose6(Vec3(500, 0.15, 300, 0), Quat.identity()))  # chassis box inside the road
    _run(vt2, sct2, VehicleInput.idle(), 600)
    var py = sct2.bset.bodies[vt2.chassis.index()].pos[1]
    s.check(py > 0.5 and py < 1.0 and vt2.speed(sct2) < 1.0, "teleport: into the road, pushed out and settles (y = " + String(py) + ")")

    # ---- non-finite chassis state ----
    var scn = _road()
    var vn = _car(scn, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    _settle(vn, scn)
    var nanv = Vec3(0, 0, 0, 0)
    nanv[0] = Real(1e30) * Real(1e30)  # +inf
    scn.bset.bodies[vn.chassis.index()].vel = nanv
    vn.update(scn, VehicleInput(1, 0, 0, 0), DT)
    s.check(scn.counters.get(VEHICLE_FORCE_DROPPED) >= 1, "non-finite state: counted, no force applied, no crash")

    # ---- chassis removed under the controller ----
    var scg = _road()
    var vg = _car(scg, VehicleConfig(), Vec3(0, REST_Y, 0, 0))
    scg.remove_body(vg.chassis)
    var dropped0 = scg.counters.get(VEHICLE_FORCE_DROPPED)
    vg.update(scg, VehicleInput(1, 0, 0, 0), DT)
    s.check(scg.counters.get(VEHICLE_FORCE_DROPPED) == dropped0 + 1, "removed chassis: counted, no crash")

    # ---- configuration errors ----
    var bad = VehicleConfig()
    bad.mass = 0
    var raised = False
    var scb = _road()
    try:
        _ = spawn_chassis(scb, bad, ZERO)
    except:
        raised = True
    s.check(raised, "config: zero mass raises")
    raised = False
    var bad2 = VehicleConfig()
    bad2.wheels = List[WheelConfig]()
    try:
        bad2.validate()
    except:
        raised = True
    s.check(raised, "config: no wheels raises")
    raised = False
    var bad3 = VehicleConfig()
    bad3.susp.stiffness = 0
    try:
        bad3.validate()
    except:
        raised = True
    s.check(raised, "config: zero stiffness raises")
    raised = False
    var st = scb.add(_st(ZERO), Vec3(1, 1, 1, 0), True)
    try:
        _ = Vehicle[RayWheel].attach(scb, st, VehicleConfig(), RayWheel())
    except:
        raised = True
    s.check(raised, "attach: a static body is not a chassis")

    s.finish()


def sc_vel(v: Vehicle[RayWheel], sc: ContactScene6[QuatBody6]) -> Vec3:
    return sc.bset.bodies[v.chassis.index()].vel
