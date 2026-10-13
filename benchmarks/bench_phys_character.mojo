"""Character backends (ROADMAP 17.66): kinematic `Mover` vs `DynamicCharacter`.

64 characters walking on a floor, cost per character per tick. The kinematic
row is `Mover.update` (sweeps against the scene; the scene step is not
needed for them). The dynamic row is `DynamicCharacter.update` (one ray +
forces) plus the share of `ContactScene6.step_soft` the 64 capsules cost,
since they are bodies the solver integrates and collides.

Run with: `mojo run -I build benchmarks/bench_phys_character.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from gameplay.character import CharacterController
from gameplay.movement import Mover, MoveConfig, MODEL_ACCEL
from gameplay.phys_character import DynamicCharacter
from harness.bench import BenchTable, now

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def floor() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 200, 0.5, 200)), Vec3(200, 0.5, 200, 0), True)
    return sc^


def main() raises:
    var n = 64
    var ticks = 120
    var t = BenchTable("Character backends, 64 walkers (17.66)")
    var ks = floor()
    var movers = List[Mover]()
    var cfg = MoveConfig.default()
    cfg.model = MODEL_ACCEL
    for i in range(n):
        movers.append(Mover(CharacterController(Vec3(Real(i % 8) * 3, 0.9, Real(i // 8) * 3, 0)), cfg))
    var waters = List[WaterVolume]()
    var t0 = now()
    for k in range(ticks):
        for i in range(n):
            movers[i].update(ks, Vec3(Real(k % 3), 0, 1, 0), False, False, DT, G, waters)
    var t1 = now()
    keep(movers[3].cc.position[0])
    t.add("kinematic Mover.update", n, "character-tick", t1 - t0, n * ticks)
    var ds = floor()
    var chars = List[DynamicCharacter]()
    for i in range(n):
        chars.append(DynamicCharacter.spawn(ds, QuatBody6.at_rest(Vec3(Real(i % 8) * 3, 1, Real(i // 8) * 3, 0), Inertia3.box(80, 0.3, 0.9, 0.3)), 80, 0.3, 0.3, 1.0))
    var t2 = now()
    for k in range(ticks):
        for i in range(n):
            chars[i].update(ds, Vec3(Real(k % 3), 0, 1, 0), DT, G)
        ds.step_soft(DT, G)
    var t3 = now()
    keep(ds.bset.bodies[3].pos[0])
    t.add("DynamicCharacter.update + step_soft share", n, "character-tick", t3 - t2, n * ticks)
    t.print_report()
