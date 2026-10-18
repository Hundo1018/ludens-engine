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
