# tier: integration
"""`VehicleElement`: a wheeled car as one force element (ROADMAP 17.74).

Parity: the car stepped through `VehicleElement.apply` ends bit for bit where
direct `Vehicle.update` calls end (330 steps, idle then throttle and steer).
Composition: a rocket `Thruster` on the same chassis adds its impulse on top
of the car's.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleConfig, VehicleInput, spawn_chassis
from gameplay.vehicle_wheel import RayWheel
from gameplay.vehicle_element import VehicleElement
from gameplay.force_element import Thruster

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime REST_Y: Real = 0.55


def _road() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 3000, 1, 3000)), Vec3(3000, 1, 3000, 0), True)
    sc.set_friction(f.index(), 0.5)
    return sc^


def _input(k: Int) -> VehicleInput:
    return VehicleInput.idle() if k < 90 else VehicleInput(0.7, 0, 0.3, 0)


def main() raises:
    var s = Suite("vehicle_element")

    var sa = _road()
    var cfg = VehicleConfig()
    var ida = spawn_chassis(sa, cfg, Vec3(0, REST_Y, 0, 0))
    var va = Vehicle[RayWheel].attach(sa, ida, cfg.copy(), RayWheel())
    for k in range(330):
        va.update(sa, _input(k), DT)
        sa.step_soft(DT, G)

    var sb = _road()
    var idb = spawn_chassis(sb, cfg, Vec3(0, REST_Y, 0, 0))
    var el = VehicleElement[RayWheel](Vehicle[RayWheel].attach(sb, idb, cfg.copy(), RayWheel()), DT)
    for k in range(330):
        el.input = _input(k)
        _ = el.apply(sb, idb, Real(k) * DT)
        sb.step_soft(DT, G)
    var pa = sa.bset.bodies[ida.index()].pos
    var pb = sb.bset.bodies[idb.index()].pos
    print("330 steps: direct update x", pa[0], " z", pa[2], "; as an element x", pb[0], " z", pb[2])
    s.check(pa[0] == pb[0] and pa[1] == pb[1] and pa[2] == pb[2], "element and direct update end at the same position bit for bit")

    # a 3 kN rocket along the chassis +z for 1 s on a coasting car launched at 5 m/s
    var speeds = List[Real]()
    for with_rocket in range(2):
        var sc = _road()
        var id = spawn_chassis(sc, cfg, Vec3(0, REST_Y, 0, 0))
        var e = VehicleElement[RayWheel](Vehicle[RayWheel].attach(sc, id, cfg.copy(), RayWheel()), DT)
        var rocket = Thruster(Vec3(0, 0, 0, 0), Vec3(0, 0, 1, 0), 3000.0, Real(with_rocket))
        for _ in range(120):
            _ = e.apply(sc, id, 0)
            sc.step_soft(DT, G)
        sc.set_velocity(id, Vec3(0, 0, 5, 0), Vec3(0, 0, 0, 0))
        e.vehicle.sync_wheels(5)
        for _ in range(60):
            _ = e.apply(sc, id, 0)
            _ = rocket.apply(sc, id, 0)
            sc.step_soft(DT, G)
        speeds.append(sc.velocity(id)[2])
    var gain = speeds[1] - speeds[0]
    var ideal = Real(3000.0) * 1.0 / cfg.mass
    print("coasting from 5 m/s, 1 s: without rocket", speeds[0], " with 3 kN rocket", speeds[1], " gain", gain, " F t / m", ideal)
    s.check(gain > 0.5 * ideal and gain < 1.1 * ideal, "a thruster on the same chassis adds to the car's speed")
    s.finish()
