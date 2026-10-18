"""Grid fluids per cell-step on the Taylor-Green vortex (ROADMAP 17.60):
the MAC projection solver (`physics.mac_fluid`; pressure by Jacobi PCG and,
17.84, by multigrid-preconditioned CG) and the
D3Q19 lattice (`fluid.lbm`) as a quasi-2-D 1-cell-thick slab. Both reach
the analytic decay within 0.5 % (test_taylor_green); this is their cost.
"""

from std.math import pi, sin, cos
from std.benchmark import keep
from geometry.vec import Real
from physics.mac_fluid import MacFluid2
from fluid.lbm import Lbm, BC_PERIODIC
from fluid.d3q19 import equilibrium
from harness.bench import BenchTable, now
from physics.flip import FlipWater2
from physics.flip_apic import ApicState, apic_step


def flip_rows(mut t: BenchTable) raises:
    """FLIP vs APIC transfers (17.60) on the 0.25 x 0.5 m dam break, 0.2 s."""
    for apic in [False, True]:
        var d = FlipWater2(80, 24, 0.025)
        var st = ApicState()
        d.fill_box(0, 0, 0.25, 0.5)
        var steps = 50
        var t0 = now()
        for _ in range(steps):
            if apic:
                apic_step(d, st, 0.004)
            else:
                d.step(0.004)
        var t1 = now()
        keep(d.px[0])
        t.add("dam break 80 x 24, " + ("APIC" if apic else "FLIP 0.95"), d.count(), "particle-step", t1 - t0, steps * d.count())


def main() raises:
    var t = BenchTable("Grid fluids on the Taylor-Green vortex (17.60)")
    for n in [32, 64]:
        var dx = 2 * Real(pi) / Real(n)
        var f = MacFluid2(n, dx, 0.05)
        for j in range(n):
            for i in range(n):
                f.u[j * n + i] = 0.01 * sin(Real(i) * dx) * cos((Real(j) + 0.5) * dx)
                f.v[j * n + i] = -0.01 * cos((Real(i) + 0.5) * dx) * sin(Real(j) * dx)
        var steps = 50
        var t0 = now()
        var iters = 0
        for _ in range(steps):
            f.step(0.02)
            iters += f.last.iters
        var t1 = now()
        keep(f.u[3])
        t.add("MAC " + String(n) + "^2 (PCG " + String(iters // steps) + " iterations / step)", n * n, "cell-step", t1 - t0, steps * n * n)
        var g = MacFluid2(n, dx, 0.05)
        g.use_multigrid()
        for j in range(n):
            for i in range(n):
                g.u[j * n + i] = 0.01 * sin(Real(i) * dx) * cos((Real(j) + 0.5) * dx)
                g.v[j * n + i] = -0.01 * cos((Real(i) + 0.5) * dx) * sin(Real(j) * dx)
        iters = 0
        t0 = now()
        for _ in range(steps):
            g.step(0.02)
            iters += g.last.iters
        t1 = now()
        keep(g.u[3])
        t.add("MAC " + String(n) + "^2 (MGPCG " + String(iters // steps) + " iterations / step)", n * n, "cell-step", t1 - t0, steps * n * n)
        var l = Lbm(n, n, 1, 0.05, BC_PERIODIC)
        var k = 2 * Real(pi) / Real(n)
        for j in range(n):
            for i in range(n):
                var c = l.idx(i, j, 0)
                for q in range(19):
                    l.f[q * l.cells() + c] = equilibrium(q, 1.0, 0.01 * sin(k * Real(i)) * cos(k * Real(j)), -0.01 * cos(k * Real(i)) * sin(k * Real(j)), 0)
        var t2 = now()
        for _ in range(steps):
            l.step()
        var t3 = now()
        keep(l.f[5])
        t.add("LBM D3Q19 " + String(n) + "^2 x 1", n * n, "cell-step", t3 - t2, steps * n * n)
    t.print_report()
    var f = BenchTable("FLIP water: FLIP 0.95 vs APIC transfers (17.60)")
    flip_rows(f)
    f.print_report()
