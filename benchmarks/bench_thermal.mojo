"""Heat conduction (ROADMAP 17.61): cost per node per step on the two
discretisations, at the same 1 mm resolution over a 60 x 4 x 4 mm block, and
the largest stable dt each allows (the grid's dx^2 / (6 alpha) against the
tets' Gershgorin bound), so the cost per simulated second can be compared.

Run with: `mojo run -I build benchmarks/bench_thermal.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real
from physics.fem import FemBody, make_beam
from physics.thermal import HeatGrid, HeatTets
from harness.bench import BenchTable, now


def main() raises:
    var alpha = Real(1e-5)
    var t = BenchTable("Heat conduction: grid vs tets, 60 x 4 x 4 mm at 1 mm (17.61)")
    var g = HeatGrid(61, 5, 5, 1e-3, alpha, 300)
    g.fix(0, 2, 2, 400)
    var steps = 200
    var gdt = 0.9 * g.max_dt()
    var t0 = now()
    for _ in range(steps):
        g.step(gdt)
    var t1 = now()
    keep(g.t[3])
    t.add("grid 7-point, max dt " + String(Float32(g.max_dt())) + " s", len(g.t), "node-step", t1 - t0, steps * len(g.t))
    var b = FemBody(1e5, 0.3)
    make_beam(b, 60, 4, 4, 1e-3, 1e-6)
    var h = HeatTets(b, alpha, 300)
    h.fix(0, 400)
    var hdt = 0.9 * h.max_dt()
    var t2 = now()
    for _ in range(steps):
        h.step(hdt)
    var t3 = now()
    keep(h.t[3])
    t.add("tets (" + String(len(b.tets)) + "), max dt " + String(Float32(h.max_dt())) + " s", len(h.t), "node-step", t3 - t2, steps * len(h.t))
    t.print_report()
