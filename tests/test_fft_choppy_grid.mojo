# tier: integration
"""The FFT grid path for choppy oceans (ROADMAP 17.60, `FftOcean.update`
displacement grids, `height` at the updated t).

A 64^2, 200 m Phillips sea (seed 7, wind 10 m/s, A = 3e-6), lambda 0.8,
updated at t = 3 s:

  1. Ordinary: the displacement grids equal `displaced` (exact sums) at
     every 4th grid point to 1e-4 m.
  2. Integration: `height` at the updated t (grid inversion) against the
     exact choppy path (4 fixed-point iterations over sums) at 200 random
     points: worst difference printed, within 1.5x the non-choppy sea's own
     grid-vs-sum interpolation error; the grid query is > 100x faster
     (per-query times printed).
  3. Extreme: queried at another t, the choppy height takes the exact path
     (equal to it bit for bit).
"""

from std.time import perf_counter_ns
from harness.runner import Suite
from geometry.vec import Real
from scheduler.rng import SplitMix64
from physics.water import FftOcean

comptime SIZE: Real = 200.0


def sea(lam: Real) raises -> FftOcean:
    var o = FftOcean(64, SIZE, 0)
    o.phillips(7, 3e-6, 10, 0)
    o.choppy = lam
    return o^


def main() raises:
    var s = Suite("fft_choppy_grid")
    var o = sea(0.8)
    o.update(3.0)
    var cell = SIZE / 64
    var worst_d = Real(0)
    for j in range(0, 64, 4):
        for i in range(0, 64, 4):
            var p = o.displaced(Real(i) * cell, Real(j) * cell, 3.0)
            worst_d = max(worst_d, abs(p[0] - Real(i) * cell - o.disp_x[j * 64 + i]))
            worst_d = max(worst_d, abs(p[2] - Real(j) * cell - o.disp_z[j * 64 + i]))
    print("displacement grid vs exact sums: worst", worst_d, "m")
    s.check(worst_d < 1e-4, "the FFT displacement grids equal the exact displacement")

    var exact = sea(0.8)  # never updated: the exact path
    var flat = sea(0)
    flat.update(3.0)
    var flat_exact = sea(0)
    var rng = SplitMix64.seeded(5)
    var worst = Real(0)
    var worst_flat = Real(0)
    var xs = List[Real]()
    var zs = List[Real]()
    for _ in range(200):
        xs.append(Real(rng.next_f32()) * SIZE)
        zs.append(Real(rng.next_f32()) * SIZE)
    var tg = Real(0)
    var te = Real(0)
    for k in range(200):
        var t0 = perf_counter_ns()
        var hg = o.height(xs[k], zs[k], 3.0)
        var t1 = perf_counter_ns()
        var he = exact.height(xs[k], zs[k], 3.0)
        var t2 = perf_counter_ns()
        tg += Real(t1 - t0)
        te += Real(t2 - t1)
        worst = max(worst, abs(hg - he))
        worst_flat = max(worst_flat, abs(flat.height(xs[k], zs[k], 3.0) - flat_exact.height(xs[k], zs[k], 3.0)))
    print("choppy height, grid vs exact: worst", worst, "m;  non-choppy grid vs exact", worst_flat, "m;  per query grid", tg / 200, "ns, exact", te / 200, "ns")
    s.check(worst < 1.5 * worst_flat and te > 100 * tg, "grid path within 1.5x the plain grid's interpolation error, > 100x faster")

    var other = o.height(xs[0], zs[0], 3.5)
    var other_exact = exact.height(xs[0], zs[0], 3.5)
    s.check(other == other_exact, "at another t the exact path is taken")
    s.finish()
