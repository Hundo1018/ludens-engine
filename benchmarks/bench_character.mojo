"""Character controller (ROADMAP 17.1): cost of one `update` vs scene size.

A controller walks in circles over a floor scattered with N static obstacles
(boxes and steps), so each update performs its real work: a few capsule
sweeps for move-and-slide, a penetration check and a ground probe. The cost
follows the world queries underneath (`bench_world_query`): flat at small N,
then the per-query linear prefilter.

Run: pixi run mojo run -I build benchmarks/bench_character.mojo
"""

from std.benchmark import keep
from std.math import sin, cos
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController

comptime STEPS = 240


def main():
    var table = BenchTable("Character controller (17.1): one update, walking over N obstacles")
    for n in [0, 16, 64, 256]:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(100, 1, 100, 0), True)
        for k in range(n):
            var a = Real(k) * 2.399963
            var r = Real(2) + Real(k) * 0.15
            var h = Real(0.1) if k % 2 == 0 else Real(0.6)
            _ = sc.add(QuatBody6.at_rest(Vec3(r * cos(a), h, r * sin(a), 0), Inertia3.box(1, 1, 1, 1)), Vec3(0.4, h, 0.4, 0), True)
        var c = CharacterController(Vec3(0, 0.92, 0, 0))
        var t0 = now()
        for i in range(STEPS):
            var a = Real(i) * 0.05
            c.update(sc, Vec3(2 * cos(a), 0, 2 * sin(a), 0), 0, 1.0 / 60.0, Vec3(0, -9.8, 0, 0))
        table.add("update", n, "step", now() - t0, STEPS)
        keep(c.position[0])
    table.print_report()
