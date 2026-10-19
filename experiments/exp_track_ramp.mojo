"""Tracked vehicle on a ramp (ROADMAP 17.74): climb speed and hold vs grade.

A 2000 kg hull on `TrackDrive` (mu 0.8) meets a static ramp box tilted by
atan(slope). Tracks at 2 m/s: speed after 6 s on the ramp. Tracks stopped:
whether the hull holds or slides back (limit tan(angle) = mu, 38.7 degrees).
"""

from std.math import atan, sqrt
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.vehicle_kinds import TrackDrive

comptime DT: Real = 1.0 / 60.0
comptime G: Vec3 = Vec3(0, -9.8, 0, 0)


def run(slope: Real, drive: Real, steps: Int, on_ramp: Bool, park: Bool = False) raises -> Tuple[Real, Real, Real]:
    var cfg = SolverConfig()
    var sc = ContactScene6[QuatBody6]()
    var ang = atan(slope)
    # flat ground, then a ramp whose top surface passes through (y -sink, z 0)
    var g0 = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    sc.set_friction(g0.index(), 0)
    var rot = Quat.from_axis_angle(Vec3(1, 0, 0, 0), -ang)
    var sink = Real(0.05)  # the ramp emerges from the ground, no vertical seam
    var c = rot.rotate(Vec3(0, -0.5, 10, 0)) + Vec3(0, -sink, 0, 0)
    var ramp = sc.add(QuatBody6.at_rest(c, Inertia3.box(1, 50, 0.5, 10)), Vec3(50, 0.5, 10, 0), True)
    sc.set_friction(ramp.index(), 0)
    sc.bset.bodies[ramp.index()].set_pose(Pose6(c, rot))
    var z0 = Real(-6)
    var start = Vec3(0, 0.4, z0, 0)
    var tank = sc.add(QuatBody6.at_rest(start, Inertia3.box(2000, 1, 0.4, 2)), Vec3(1, 0.4, 2, 0), False)
    sc.set_friction(tank.index(), 0)
    if on_ramp:
        # at rest on the ramp, hull aligned with the surface, 3 m up
        var pos = Vec3(0, slope * 3.0 - sink, 3.0, 0) + rot.rotate(Vec3(0, 0.4, 0, 0))
        sc.bset.bodies[tank.index()].set_pose(Pose6(pos, rot))
    var tr = TrackDrive(0.9, 3.6, 6, -0.4, 0.0, 2000.0, 9.8, 2000.0, 4000.0, 0.8)
    if slope > 0:
        tr.set_ramp(sink / slope, slope)
    if park:
        tr.park(sc, tank)
    tr.speed_left = drive
    tr.speed_right = drive
    for _ in range(steps):
        _ = tr.apply(sc, tank, 0)
        sc.step(DT, G, cfg)
    var p = sc.pose(tank).pos
    var v = sc.velocity(tank)
    return (p[2], p[1], v[2])


def main() raises:
    print("climb: tracks 2 m/s from z -6, 10 s")
    print("| slope | angle deg | z after | y after | vz |")
    print("|---:|---:|---:|---:|---:|")
    for i in range(6):
        var sl = Real(i) * 0.2
        var r = run(sl, 2.0, 600, False)
        print("|", sl, "|", atan(sl) * 57.29578, "|", r[0], "|", r[1], "|", r[2], "|")
    print("hold: tracks stopped, hull on the ramp at z 3, 5 s")
    print("| slope | angle deg | z after | vz |")
    print("|---:|---:|---:|---:|")
    for i in range(1, 7):
        var sl = Real(i) * 0.15
        var r = run(sl, 0.0, 300, True)
        print("|", sl, "|", atan(sl) * 57.29578, "|", r[0], "|", r[2], "|")
    print("parked (static anchor): hull on the ramp at z 3, 5 s")
    print("| slope | angle deg | z after | vz |")
    print("|---:|---:|---:|---:|")
    for i in range(1, 7):
        var sl = Real(i) * 0.15
        var r = run(sl, 0.0, 300, True, True)
        print("|", sl, "|", atan(sl) * 57.29578, "|", r[0], "|", r[2], "|")
