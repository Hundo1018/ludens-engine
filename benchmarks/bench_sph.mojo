"""SPH vs PBF: what a second of simulated time costs, and how big dt can be.

Both solvers run on the same particle state, the same grid and the same
kernels, so this isolates the one thing that differs: SPH turns density error
into a pressure FORCE and integrates it explicitly, PBF treats density error as
a CONSTRAINT and projects positions to satisfy it.

The metric is deliberately cost per SECOND OF SIMULATED TIME rather than cost
per step. Cost per step flatters whichever solver takes smaller steps, and the
entire practical question here is how large a step each one can survive — a
stiff explicit solver is CFL-limited, a projection solver is not. Each row also
carries the settled density it achieved, so an unusable configuration is
visible rather than merely cheap: a row that is fast because it diverged is
marked by its own error column.
"""

from std.math import sqrt
from std.time import perf_counter_ns
from std.benchmark import keep
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid
from physics.sph import sph_step

comptime G = Vec3(0, -9.8, 0)
comptime SP: Real = 0.06
comptime SIM_TIME: Real = 1.0


def _scene() -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0), Vec3(0.6, 1.0, 0.6))
    f.calibrate(SP)
    for i in range(6):
        for j in range(6):
            for k in range(6):
                f.add(Vec3(0.12 + Real(i) * SP, 0.30 + Real(j) * SP, 0.12 + Real(k) * SP))
    return f^


def _mean_rho(mut f: PbfFluid) -> Real:
    f._rebuild_grid()
    var nbr = List[Int]()
    var tot = Real(0)
    for i in range(f.count()):
        f._neighbors(i, nbr)
        tot += f.density(i, nbr)
    return tot / Real(f.count())


def _maxv(f: PbfFluid) -> Real:
    var m = Real(0)
    for i in range(f.count()):
        var v = f.vx[i] * f.vx[i] + f.vy[i] * f.vy[i] + f.vz[i] * f.vz[i]
        if v > m:
            m = v
    return sqrt(m)


def _err(r: Real) -> String:
    var v = Int(Float64(r) * 100.0 + 0.5)
    var frac = v % 100
    var fs = String(frac)
    if frac < 10:
        fs = "0" + fs
    return String(v // 100) + "." + fs


def _sph_row(mut t: BenchTable, dt: Real, name: String) raises:
    var f = _scene()
    var steps = Int(SIM_TIME / dt)
    var t0 = Int(perf_counter_ns())
    for _ in range(steps):
        sph_step(f, dt, G)
    var el = Int(perf_counter_ns()) - t0
    var r = _mean_rho(f) / f.rho0
    var mv = _maxv(f)
    # UNSTABLE means diverged, not merely still-moving: a fluid that is at the
    # right density but has residual motion has simply not settled yet, and
    # conflating the two would mislabel a working configuration.
    var tag = "  UNSTABLE" if (r > 1.25 or mv > 5.0) else ""
    keep(steps)
    t.add(
        "sph dt=" + name + " rho=" + _err(r) + " v=" + _err(mv) + tag,
        f.count(), "sim-second", el, 1,
    )


def _pbf_row(mut t: BenchTable, dt: Real, name: String, iters: Int) raises:
    var f = _scene()
    var steps = Int(SIM_TIME / dt)
    var t0 = Int(perf_counter_ns())
    for _ in range(steps):
        f.step(dt, G, iters)
    var el = Int(perf_counter_ns()) - t0
    var r = _mean_rho(f) / f.rho0
    var mv = _maxv(f)
    var tag = "  UNSTABLE" if (r > 1.25 or mv > 5.0) else ""
    keep(steps)
    t.add(
        "pbf dt=" + name + " it=" + String(iters) + " rho=" + _err(r)
        + " v=" + _err(mv) + tag,
        f.count(), "sim-second", el, 1,
    )


def main() raises:
    var t = BenchTable("Fluids: SPH (explicit pressure) vs PBF (density projection)")
    _sph_row(t, 1.0 / 2000.0, "1/2000")
    _sph_row(t, 1.0 / 500.0, "1/500")
    _sph_row(t, 1.0 / 120.0, "1/120")
    _sph_row(t, 1.0 / 60.0, "1/60")
    _pbf_row(t, 1.0 / 120.0, "1/120", 4)
    _pbf_row(t, 1.0 / 60.0, "1/60", 4)
    _pbf_row(t, 1.0 / 30.0, "1/30", 4)
    _pbf_row(t, 1.0 / 30.0, "1/30", 8)
    t.print_report()
