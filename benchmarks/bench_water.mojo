"""Water surfaces (ROADMAP 17.60): query and step costs.

`height` per query for flat water, a 4-wave Gerstner sea with steepness 0
(no inverse map needed but still iterated) and 0.6, and a shallow-water grid
(bilinear sample); one `ShallowWaterGrid.step` per cell (128^2); one
`float_body` call per body at 4^3 samples on the Gerstner sea.

Run with: `mojo run -I build benchmarks/bench_water.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.water import WaterSurface, FlatWater, GerstnerWater, ShallowWaterGrid, float_body
from harness.bench import BenchTable, now


def query_row[W: WaterSurface](mut t: BenchTable, label: String, w: W, n: Int):
    var acc = Real(0)
    var t0 = now()
    for k in range(n):
        acc += w.height(Real(k % 997) * 0.37, Real(k % 89) * 0.53, Real(k) * 1e-4)
    var t1 = now()
    keep(acc)
    t.add(label, n, "query", t1 - t0, n)


def sea(q: Real) -> GerstnerWater:
    var g = GerstnerWater(0)
    g.add(1, 0, 0.6, 40, q)
    g.add(0.7, 0.7, 0.3, 17, q)
    g.add(-0.2, 1, 0.15, 9, q)
    g.add(0.9, -0.4, 0.08, 4.5, q)
    return g^


def main() raises:
    var t = BenchTable("Water surface height queries (17.60)")
    query_row(t, "flat", FlatWater(0), 200000)
    query_row(t, "gerstner 4 waves, Q = 0", sea(0), 200000)
    query_row(t, "gerstner 4 waves, Q = 0.6", sea(0.6), 200000)
    var sw = ShallowWaterGrid(128, 128, 0.25, 0, 0, 0, 1)
    sw.disturb(16, 16, 2, 0.2)
    query_row(t, "shallow-water grid 128^2 (sample)", sw, 200000)
    t.print_report()

    var u = BenchTable("Shallow-water step and float_body (17.60)")
    var dt = 0.5 * sw.max_dt()
    var t0 = now()
    for _ in range(100):
        sw.step(dt)
    var t1 = now()
    keep(sw.eta[100])
    u.add("ShallowWaterGrid.step 128^2", 128 * 128, "cell-step", t1 - t0, 100 * 128 * 128)
    var sc = ContactScene6[QuatBody6]()
    var id = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(2000, 1, 0.5, 1)), Vec3(1, 0.5, 1, 0), False)
    var g = sea(0.6)
    var t2 = now()
    var subv = Real(0)
    for k in range(2000):
        subv += float_body(sc, id, Vec3(1, 0.5, 1, 0), g, Real(k) * 0.01, 1000, Vec3(0, -9.8, 0, 0), 2.0, 4)
    var t3 = now()
    keep(subv)
    u.add("float_body 4^3 samples on the 4-wave sea", 1, "body", t3 - t2, 2000)
    u.print_report()
