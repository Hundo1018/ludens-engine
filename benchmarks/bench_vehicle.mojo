"""Raycast vehicles (ROADMAP 17.4): cost of one vehicle update, by wheel-cast
variant and by fleet size.

The seam is `WheelCast`: one ray, a swept sphere, or a swept capsule per wheel
(`test_vehicle_wheel` checks they agree on the same road). Each row is the
`VehicleSet.update` of N cars driving on a floor with a few static obstacles,
divided by N * steps -- a vehicle-step. The set shares one pose list, but each
wheel query still scans every collider (one per car plus the road), so the
per-vehicle cost grows with N: the same linear prefilter `bench_world_query`
measures.

Run: pixi run mojo run -I build benchmarks/bench_vehicle.mojo
"""

from std.benchmark import keep
from std.math import cos, sin
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleSet, VehicleConfig, VehicleInput, spawn_chassis
from gameplay.vehicle_wheel import WheelCast, RayWheel, SphereWheel, CapsuleWheel

comptime STEPS = 120
comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(2000, 1, 2000, 0), True)
    for k in range(12):
        var a = Real(k) * 2.4
        _ = sc.add(
            QuatBody6.at_rest(Vec3(40 * cos(a), 0.05, 40 * sin(a), 0), Inertia3.box(1, 1, 1, 1)),
            Vec3(1.5, 0.05, 1.5, 0),
            True,
        )
    return sc^


def _run[W: WheelCast](mut table: BenchTable, label: String, n: Int, proto: W) raises:
    var sc = _scene()
    var fleet = VehicleSet[W]()
    var ins = List[VehicleInput]()
    for k in range(n):
        var cfg = VehicleConfig()
        var col = k % 8
        var row = k // 8
        var id = spawn_chassis(sc, cfg, Vec3(Real(col) * 6 - 20, 0.72, Real(row) * 6 - 20, 0))
        _ = fleet.add(Vehicle[W].attach(sc, id, cfg^, proto.copy()))
        ins.append(VehicleInput(0.5, 0, 0.1, 0))
    # settle, untimed
    for _ in range(60):
        fleet.update(sc, ins, DT)
        sc.step_soft(DT, G)
    var spent = 0
    for _ in range(STEPS):
        var t0 = now()
        fleet.update(sc, ins, DT)
        spent += now() - t0
        sc.step_soft(DT, G)
    keep(sc.bset.bodies[fleet.items[0].chassis.index()].pos[0])
    table.add(label, n, "vehicle-step", spent, STEPS * n)


def main() raises:
    var table = BenchTable("Raycast vehicle (17.4): one update per vehicle, wheel-cast variants")
    for n in [1, 8, 32, 128]:
        _run(table, "ray", n, RayWheel())
        _run(table, "sphere sweep", n, SphereWheel())
        _run(table, "capsule sweep", n, CapsuleWheel())
    table.print_report()
