"""Position-Based Fluids: cost at a quality level, and what quality costs.

PBF shares its solver shape with the XPBD cloth already in the engine — predict,
project a constraint, derive velocity from the position change — so the rows
here are read the same way as the cloth ones: cost is only meaningful next to
the error it bought. The error column is mean density relative to rest, so 1.00
is a perfectly incompressible result and larger means the fluid was squashed.

Two sweeps. Iterations is the interesting one, because PBF has a sharp
convergence cliff rather than a gentle accuracy gradient: below a threshold the
density constraint never catches up with gravity and the fluid collapses into a
lump, which no amount of extra frames repairs. Particle count is the ordinary
scaling axis, with a uniform grid rebuilt each iteration so neighbour search
stays near-linear.
"""

from std.time import perf_counter_ns
from std.benchmark import keep
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 120  # long enough for the column to actually settle;
# at 40 the density column is still mid-fall and reads non-monotonically in
# the iteration count, which measures the transient rather than convergence
comptime SP: Real = 0.06


def _make(side: Int) -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0), Vec3(1.2, 1.6, 1.2))
    f.calibrate(SP)
    for i in range(side):
        for j in range(side):
            for k in range(side):
                f.add(
                    Vec3(0.2 + Real(i) * SP, 0.5 + Real(j) * SP, 0.2 + Real(k) * SP)
                )
    return f^


def _mean_rho(mut f: PbfFluid) -> Real:
    f._rebuild_grid()
    var nbr = List[Int]()
    var tot = Real(0)
    for i in range(f.count()):
        f._neighbors(i, nbr)
        tot += f.density(i, nbr)
    return tot / Real(f.count())


def _ratio_str(r: Real) -> String:
    var v = Int(Float64(r) * 100.0 + 0.5)
    var frac = v % 100
    var fs = String(frac)
    if frac < 10:
        fs = "0" + fs
    return String(v // 100) + "." + fs


def _row(mut t: BenchTable, side: Int, iters: Int) raises:
    var f = _make(side)
    var n = f.count()
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        f.step(DT, G, iters)
    var dt = Int(perf_counter_ns()) - t0
    var rho = _mean_rho(f)
    keep(n)
    t.add(
        "pbf it=" + String(iters) + " rho/rest=" + _ratio_str(rho / f.rho0),
        n, "particle-step", dt, n * STEPS,
    )


def main() raises:
    var t = BenchTable("Position-Based Fluids: cost at a density-error level")
    # iteration sweep at fixed N — the convergence cliff
    _row(t, 6, 2)
    _row(t, 6, 3)
    _row(t, 6, 4)
    _row(t, 6, 6)
    _row(t, 6, 10)
    # particle-count sweep at a converged iteration count
    _row(t, 8, 6)
    _row(t, 10, 6)
    _row(t, 12, 6)
    t.print_report()
