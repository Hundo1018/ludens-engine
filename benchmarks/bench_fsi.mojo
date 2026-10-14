"""LBM moving solids and rigid coupling (ROADMAP 17.59).

`Lbm.step` per lattice cell on a 32^3 box with no solid, one static sphere,
one moving sphere (Ladd bounce-back with force / torque bookkeeping, moved
every step) and eight moving spheres; and one `LbmCoupler.step` (lattice
step + `ContactScene6` step) with one coupled sphere.

Run with: `mojo run -I build benchmarks/bench_fsi.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fsi import LbmCoupler
from harness.bench import BenchTable, now


def lattice_row(mut t: BenchTable, label: String, spheres: Int, moving: Bool, steps: Int):
    var n = 32
    var l = Lbm(n, n, n, 0.16)
    l.init_uniform(1, 0.01, 0, 0)
    var ids = List[Int]()
    for k in range(spheres):
        var c = Vec3(8 + Real(k % 2) * 16, 8 + Real((k // 2) % 2) * 16, 8 + Real(k // 4) * 16, 0)
        if moving:
            ids.append(l.add_moving_sphere(c, 3, Vec3(0.005, 0, 0, 0), Vec3(0, 0, 0.001, 0)))
        else:
            l.set_solid_sphere(c[0], c[1], c[2], 3)
    var t0 = now()
    for st in range(steps):
        for k in range(len(ids)):
            var c = Vec3(8 + Real(k % 2) * 16 + Real(st) * 0.005, 8 + Real((k // 2) % 2) * 16, 8 + Real(k // 4) * 16, 0)
            l.move_sphere(ids[k], c, Vec3(0.005, 0, 0, 0), Vec3(0, 0, 0.001, 0))
        l.step()
    var t1 = now()
    keep(l.fx)
    t.add(label, l.cells(), "cell-step", t1 - t0, steps * l.cells())


def main() raises:
    var t = BenchTable("LBM with moving solids (17.59), 32^3")
    lattice_row(t, "no solid", 0, False, 60)
    lattice_row(t, "1 static sphere", 1, False, 60)
    lattice_row(t, "1 moving sphere (Ladd)", 1, True, 60)
    lattice_row(t, "8 moving spheres (Ladd)", 8, True, 60)
    t.print_report()

    var c = BenchTable("LbmCoupler.step: lattice + ContactScene6, one sphere (17.59)")
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_sphere(QuatBody6.at_rest(Vec3(16e-3, 16e-3, 16e-3, 0), Inertia3.sphere(0.0001, 3e-3)), 3e-3, False)
    var lbm = Lbm(32, 32, 32, 0.16)
    lbm.init_uniform(1, 0, 0, 0)
    var cp = LbmCoupler(lbm^, 1e-3, 1e-3, 1000, Vec3(0, 0, 0, 0))
    _ = cp.add_sphere(sc, sc.bset.id_of(0), 3e-3)
    var cfg = SolverConfig()
    var t0 = now()
    for _ in range(60):
        cp.step(sc, Vec3(-1, 0, 0, 0), cfg)
    var t1 = now()
    keep(sc.bset.bodies[0].pos[0])
    c.add("coupled step (32^3 lattice, 1 sphere)", 1, "step", t1 - t0, 60)
    c.print_report()
