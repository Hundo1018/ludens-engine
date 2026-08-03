"""MLS-MPM: cost per particle-step, and what plasticity costs.

MPM sits between the engine's other deformables: FEM keeps a fixed mesh and
therefore a fixed topology, PBF/SPH keep no rest shape at all, and MPM carries
elastic state on particles while using a transient grid to resolve coupling —
so the material can flow and pile up while still remembering strain.

Two axes. Particle count is the ordinary one; cost is dominated by the 3x3x3
scatter and gather, so per-particle cost should be flat. The second is the
plasticity switch, which is what buys the materials FEM cannot represent
(snow, mud, anything that keeps a new shape). It is a determinant clamp plus a
rescale, so it should be nearly free — and the row shows whether that holds.
"""

from std.time import perf_counter_ns
from std.benchmark import keep
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 200


def _column(mut m: MpmSolver, nx: Int, ny: Int, nz: Int, sp: Real):
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(
                    Vec3(0.35 + Real(i) * sp, 0.60 + Real(j) * sp, 0.35 + Real(k) * sp),
                    vol * 1000.0,
                    vol,
                )


def _row(mut t: BenchTable, nx: Int, ny: Int, nz: Int, plastic: Bool) raises:
    var m = MpmSolver(Vec3(0, 0, 0), DX, N, 100000.0, 0.2)
    _column(m, nx, ny, nz, 0.04)
    if plastic:
        m.set_plastic(0.94, 1.02)
    var np = m.count()
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        m.step(1.0 / 2000.0, G)
    var dt = Int(perf_counter_ns()) - t0
    keep(np)
    var tag = "plastic" if plastic else "elastic"
    t.add("mpm " + tag, np, "particle-step", dt, np * STEPS)


def main() raises:
    var t = BenchTable("MLS-MPM: particle scaling and the cost of plasticity")
    _row(t, 4, 6, 4, False)
    _row(t, 4, 6, 4, True)
    _row(t, 6, 10, 4, False)
    _row(t, 6, 10, 4, True)
    _row(t, 8, 12, 6, False)
    _row(t, 8, 12, 6, True)
    t.print_report()
