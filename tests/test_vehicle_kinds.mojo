# tier: integration
"""Quadrotor, tracked vehicle, trailer hitch (ROADMAP 17.74,
`gameplay.vehicle_kinds`).

  1. Mixer: pure collective splits equally; a roll command gives torque
     about body z equal to the command and no net change in total thrust;
     the yaw command's reaction torque equals the command.
  2. Hover: a 1 kg quad (arm 0.2 m) starting at y 1 holds y 2 within 2 cm
     and level (up.y > 0.999) after 4 s; with a yaw target of 1 rad its
     heading is within 0.02 rad.
  3. Tracks: a 2 t box on the ground; both tracks at 2 m/s drive it
     straight at 2 m/s (5 %); opposite speeds (+-1 m/s) turn it on the spot
     (centre moves < 5 cm; yaw rate 0.23 rad/s against the no-slip 1.11:
     the track ends slide sideways, skid steering). Hull and ground have
     friction 0 -- the tracks carry the traction.
  4. Hitch: a kinematic tractor moved forward 4 m drags a hitched trailer; the two
     anchor points stay together (< 1 cm) and the trailer moves > 3 m.
"""

from std.math import atan2, atan, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.vehicle_kinds import QuadRotor, QuadController, TrackDrive, hitch

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def ramp_run(slope: Real, drive: Real, steps: Int, on_ramp: Bool) raises -> Tuple[Real, Real]:
    """A 2000 kg hull on TrackDrive over a ramp rising `slope` per metre from z 0
    (the ramp emerges from the ground 5 cm down, so there is no vertical seam).
    Returns (z, vz) after `steps`. `on_ramp` starts the hull at rest on it, 3 m up."""
    var cfg = SolverConfig()
    var sc = ContactScene6[QuatBody6]()
    var ang = atan(slope)
    var g0 = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    sc.set_friction(g0.index(), 0)
    var rot = Quat.from_axis_angle(Vec3(1, 0, 0, 0), -ang)
    var sink = Real(0.05)
    var c = rot.rotate(Vec3(0, -0.5, 10, 0)) + Vec3(0, -sink, 0, 0)
    var ramp = sc.add(QuatBody6.at_rest(c, Inertia3.box(1, 50, 0.5, 10)), Vec3(50, 0.5, 10, 0), True)
    sc.set_friction(ramp.index(), 0)
    sc.bset.bodies[ramp.index()].set_pose(Pose6(c, rot))
    var tank = sc.add(QuatBody6.at_rest(Vec3(0, 0.4, -6, 0), Inertia3.box(2000, 1, 0.4, 2)), Vec3(1, 0.4, 2, 0), False)
    sc.set_friction(tank.index(), 0)
    if on_ramp:
        var pos = Vec3(0, slope * 3.0 - sink, 3.0, 0) + rot.rotate(Vec3(0, 0.4, 0, 0))
        sc.bset.bodies[tank.index()].set_pose(Pose6(pos, rot))
    var tr = TrackDrive(0.9, 3.6, 6, -0.4, 0.0, 2000.0, 9.8, 2000.0, 4000.0, 0.8)
    tr.set_ramp(sink / slope, slope)
    tr.speed_left = drive
    tr.speed_right = drive
    for _ in range(steps):
        _ = tr.apply(sc, tank, 0)
        sc.step(DT, G, cfg)
    return (sc.pose(tank).pos[2], sc.velocity(tank)[2])


def main() raises:
    var s = Suite("vehicle_kinds")
    var cfg = SolverConfig()

    # 1. mixer
    var q = QuadRotor(0.2, 20.0, 0.02)
    q.mix(8.0, 0, 0, 0)
    var eq = q.thrust[0] == 2 and q.thrust[1] == 2 and q.thrust[2] == 2 and q.thrust[3] == 2
    q.mix(8.0, 0.4, 0, 0)
    var tz = Real(0)
    var tsum = Real(0)
    for i in range(4):
        tz += QuadRotor.rotor_pos(i, 0.2)[0] * q.thrust[i]
        tsum += q.thrust[i]
    q.mix(8.0, 0, 0, 0.05)
    var spin: List[Real] = [1, -1, 1, -1]
    var ty = Real(0)
    for i in range(4):
        ty += spin[i] * 0.02 * q.thrust[i]
    print("mixer: roll torque", tz, "(0.4)  total", tsum, "  yaw reaction", ty, "(0.05)")
    s.check(eq, "collective splits equally")
    s.check(abs(tz - 0.4) < 1e-5 and abs(tsum - 8) < 1e-5, "roll command = torque about z, total thrust unchanged")
    s.check(abs(ty - 0.05) < 1e-6, "yaw command = rotor reaction torque")

    # 2. hover with yaw
    var sc = ContactScene6[QuatBody6]()
    var body = sc.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1.0, 0.2, 0.05, 0.2)), Vec3(0.2, 0.05, 0.2, 0), False)
    var ctl = QuadController(1.0, 8.0, 5.0, 2.0, 0.6)
    var quad = QuadRotor(0.2, 10.0, 0.02)
    for _ in range(240):
        var cmd = ctl.command(sc, body, 2.0, 1.0, 9.8, DT)
        quad.mix(cmd[0], cmd[1], cmd[2], cmd[3])
        _ = quad.apply(sc, body, 0)
        sc.step(DT, G, cfg)
    var pose = sc.pose(body)
    var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
    var fwd = pose.rot.rotate(Vec3(0, 0, 1, 0))
    var heading = atan2(fwd[0], fwd[2])
    print("hover after 4 s: y", pose.pos[1], " up.y", up[1], " heading", heading)
    s.check(abs(pose.pos[1] - 2) < 0.02 and up[1] > 0.999, "quad holds y 2 level")
    s.check(abs(heading - 1) < 0.02, "quad turns to the yaw target")

    # 3. tracks
    var ts = ContactScene6[QuatBody6]()
    var g1 = ts.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    ts.set_friction(g1.index(), 0)
    var tank = ts.add(QuatBody6.at_rest(Vec3(0, 0.4, 0, 0), Inertia3.box(2000, 1, 0.4, 2)), Vec3(1, 0.4, 2, 0), False)
    ts.set_friction(tank.index(), 0)
    var tr = TrackDrive(0.9, 3.6, 6, -0.4, 0.0, 2000.0, 9.8, 2000.0, 4000.0, 0.8)
    tr.speed_left = 2
    tr.speed_right = 2
    for _ in range(180):
        _ = tr.apply(ts, tank, 0)
        ts.step(DT, G, cfg)
    var v = ts.velocity(tank)
    var w = ts.angular_velocity(tank)
    print("tracks 2 / 2 m/s, 3 s: forward speed", v[2], " yaw rate", w[1])
    s.check(abs(v[2] - 2) < 0.1 and abs(w[1]) < 0.01, "equal track speeds drive straight at the track speed")
    tr.speed_left = 1
    tr.speed_right = -1
    # the spot turn is measured from rest, on a fresh tank
    var ts2 = ContactScene6[QuatBody6]()
    var g2 = ts2.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    ts2.set_friction(g2.index(), 0)
    var tank2 = ts2.add(QuatBody6.at_rest(Vec3(0, 0.4, 0, 0), Inertia3.box(2000, 1, 0.4, 2)), Vec3(1, 0.4, 2, 0), False)
    ts2.set_friction(tank2.index(), 0)
    var c0 = ts2.pose(tank2).pos
    for _ in range(180):
        _ = tr.apply(ts2, tank2, 0)
        ts2.step(DT, G, cfg)
    var c1 = ts2.pose(tank2).pos
    var wy = ts2.angular_velocity(tank2)[1]
    print("tracks +1 / -1 m/s from rest, 3 s: centre moved", length(c1 - c0), " yaw rate", wy, " (no-slip", 2.0 / 1.8, ")")
    # skid steering: the ends of each track slide sideways as the hull turns,
    # so the lateral resistance holds the rate below the no-slip 2 v / width
    s.check(length(c1 - c0) < 0.05 and abs(wy) > 0.1 and abs(wy) < 2.0 / 1.8, "opposite track speeds turn on the spot, slower than no-slip")

    # 3b. ramp: the tracks climb 0.2 / 0.4 slopes; with the tracks stopped the
    # hull creeps down at the viscous rate W sin(a) / (n k), it is not braked
    var r1 = ramp_run(0.2, 2.0, 600, False)
    var r2 = ramp_run(0.4, 2.0, 600, False)
    print("ramp climb, tracks 2 m/s, 10 s: slope 0.2 z", r1[0], " vz", r1[1], "; slope 0.4 z", r2[0], " vz", r2[1])
    s.check(r1[0] > 10 and r1[1] > 1.5 and r2[0] > 8 and r2[1] > 1.3, "tracks drive the hull up 0.2 and 0.4 slopes")
    var hold = ramp_run(0.15, 0.0, 300, True)
    var a = atan(Real(0.15))
    var creep = 2000.0 * 9.8 * sin(a) / (12.0 * 2000.0)
    print("ramp hold, tracks stopped, slope 0.15: vz", hold[1], " viscous creep W sin(a) / (n k)", -creep)
    s.check(abs(hold[1] + creep) < 0.1 * creep, "a stopped track set creeps down at W sin(a) / (n k)")

    # 4. hitch
    var hs = ContactScene6[QuatBody6]()
    _ = hs.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    var tractor = hs.add(QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.box(1000, 0.8, 0.5, 1.5)), Vec3(0.8, 0.5, 1.5, 0), False)
    var trailer = hs.add(QuatBody6.at_rest(Vec3(0, 0.5, -3.5, 0), Inertia3.box(500, 0.8, 0.5, 1.5)), Vec3(0.8, 0.5, 1.5, 0), False)
    hs.set_kinematic(tractor)
    var j = hitch(hs, tractor, trailer, Vec3(0, 0.5, -1.75, 0))
    var t0 = hs.pose(trailer).pos
    var worst = Real(0)
    for k in range(240):
        var target = Vec3(0, 0.5, Real(k + 1) * (4.0 / 240.0), 0)
        hs.move_to(tractor, Pose6(target, Quat(0, 0, 0, 1)), DT)
        hs.step(DT, G, cfg)
        var pa = hs.pose(tractor).pos + Vec3(0, 0, -1.75, 0)
        var pb = hs.pose(trailer).pos + hs.pose(trailer).rot.rotate(Vec3(0, 0, 1.75, 0))
        worst = max(worst, length(pa - pb))
    var moved = hs.pose(trailer).pos[2] - t0[2]
    print("hitch: trailer moved", moved, "m, worst anchor gap", worst)
    s.check(worst < 0.01 and moved > 3.0, "the hitched trailer follows, anchors together")
    _ = j
    s.finish()
