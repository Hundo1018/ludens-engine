"""ROADMAP 17.67: cost of one Mover update per velocity model.

16 characters walking circles on a flat floor (a few capsule sweeps per
update, as in 17.1), 300 ticks after 30 settling ticks. The model only
changes how the horizontal velocity is integrated, so the rows should be
close; the swimming row adds the water-volume test and drag.
"""

from std.time import perf_counter_ns
from std.math import cos, sin
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from gameplay.character import CharacterController
from gameplay.movement import Mover, MoveConfig, MODEL_DIRECT, MODEL_ACCEL, MODEL_QUAKE

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _run(model: Int, swim: Bool) raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 60, 0.5, 60)), Vec3(60, 0.5, 60, 0), True)
    var waters = List[WaterVolume]()
    if swim:
        waters.append(WaterVolume(Vec3(-60, -1, -60, 0), Vec3(60, 2.0, 60, 0), 1000, 1, 1))
    var ms = List[Mover]()
    for k in range(16):
        var cfg = MoveConfig.default()
        cfg.model = model
        ms.append(Mover(CharacterController(Vec3(Real(k % 4) * 6 - 9, 0.92, Real(k // 4) * 6 - 9, 0)), cfg))
    var none = List[WaterVolume]()
    for _ in range(30):
        for k in range(16):
            ms[k].update(sc, Vec3(0, 0, 0, 0), False, False, DT, G, none)
    var t0 = Int(perf_counter_ns())
    for t in range(300):
        var a = Real(t) * 0.02
        for k in range(16):
            ms[k].update(sc, Vec3(2 * cos(a + Real(k)), 0, 2 * sin(a + Real(k)), 0), t % 90 == 0, t % 90 < 10, DT, G, waters)
    return (Int(perf_counter_ns()) - t0) // (300 * 16)


def main() raises:
    print("### Movement modes (17.67): one update\n")
    print("| model | mode | ns per update |")
    print("|---|---|---:|")
    print("| direct | walk |", _run(MODEL_DIRECT, False), "|")
    print("| acceleration | walk |", _run(MODEL_ACCEL, False), "|")
    print("| quake | walk |", _run(MODEL_QUAKE, False), "|")
    print("| acceleration | swim |", _run(MODEL_ACCEL, True), "|")
    print("")
