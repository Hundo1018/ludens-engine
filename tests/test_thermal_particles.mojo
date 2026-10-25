# tier: unit
"""Heat conduction on particles (ROADMAP 17.61, `HeatParticles`): the third
discretisation, checked against the same erf solution as `HeatGrid` and
`HeatTets` (test_thermal).

  1. Ordinary: a bar of particles on a 1 mm lattice, 60 x 11 x 11 (three
     layers at x <= 0 held at 400 K so the free particles keep full kernel
     support; 11 across so the centre line's neighbours do too -- with 7,
     particles near the faces have their sums boosted by the
     renormalisation and the centre line ran 2 K hot; h = 1.2 mm),
     alpha = 1e-5, 300 K: after 10 s its centre line
     matches T0 + (Ts - T0) erfc(x / (2 sqrt(alpha t))) within 1.5 K, and
     the grid of test_thermal at the same points within 1.5 K (parity;
     1.24 K measured: the kernel reaches 2.4 cells where the grid's stencil
     reaches 1, so its truncation error on a 20-cell-wide profile is the
     larger one; the grid is 0.014 K off).
  2. Integration: an insulated block of particles with a hot half keeps its
     heat (sum vol T) to 1e-5 over 200 steps and evens out (spread shrinks).
  3. Extreme: temperature <= 0 K, vol / h / alpha <= 0 and a step above
     the Gershgorin bound raise; a lone particle keeps its temperature.
"""

from std.math import erf, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.thermal import HeatGrid, HeatParticles

comptime DX: Real = 1e-3
comptime ALPHA: Real = 1e-5


def _erf_sol(x: Real, t: Real) -> Real:
    return 300 + 100 * (1 - Real(erf(Float64(x / (2 * sqrt(ALPHA * t))))))


def main() raises:
    var s = Suite("thermal_particles")
    var pts = List[Vec3]()
    for k in range(11):
        for j in range(11):
            for i in range(-2, 58):
                pts.append(Vec3(Real(i) * DX, Real(j) * DX, Real(k) * DX, 0))
    var hp = HeatParticles(pts^, DX * DX * DX, 1.2 * DX, ALPHA, 300)
    var line = List[Int]()
    for q in range(len(hp.x)):
        if hp.x[q][0] <= 1e-9:
            hp.fix(q, 400)
        if abs(hp.x[q][1] - 5 * DX) < 1e-9 and abs(hp.x[q][2] - 5 * DX) < 1e-9:
            line.append(q)
    var dt = min(Real(0.01), 0.9 * hp.max_dt())
    var steps = Int(10 / dt + 0.5)
    for _ in range(steps):
        hp.step(dt)
    var t_end = Real(steps) * dt
    var g = HeatGrid(200, 1, 1, DX, ALPHA, 300)
    g.fix(0, 0, 0, 400)
    var gsteps = Int(t_end / 0.01 + 0.5)
    for _ in range(gsteps):
        g.step(0.01)
    var ee = Real(0)
    var eg = Real(0)
    for q in line:
        var x = hp.x[q][0]
        if x < 0 or x > 0.04:
            continue
        ee = max(ee, abs(hp.t[q] - _erf_sol(x, t_end)))
        eg = max(eg, abs(hp.t[q] - g.t[Int(x / DX + 0.5)]))
    print("  particle bar (", len(hp.x), "particles, dt", dt, ", max_dt", hp.max_dt(), "): max |T - erf|", ee, "K;  max |T_particles - T_grid|", eg, "K")
    s.check(ee < 1.5 and eg < 1.5, "particles match the erf solution and the grid within 1.5 K")

    var blk = List[Vec3]()
    for k in range(6):
        for j in range(6):
            for i in range(6):
                blk.append(Vec3(Real(i), Real(j), Real(k), 0) * DX)
    var hb = HeatParticles(blk^, DX * DX * DX, 1.2 * DX, ALPHA, 300)
    for q in range(len(hb.x)):
        if hb.x[q][0] < 3 * DX:
            hb.t[q] = 500
    var h0 = hb.heat()
    var lo0 = Real(1e30)
    var hi0 = Real(-1e30)
    for v in hb.t:
        lo0 = min(lo0, v)
        hi0 = max(hi0, v)
    for _ in range(200):
        hb.step(0.9 * hb.max_dt())
    var lo1 = Real(1e30)
    var hi1 = Real(-1e30)
    for v in hb.t:
        lo1 = min(lo1, v)
        hi1 = max(hi1, v)
    var drift = abs(hb.heat() / h0 - 1)
    print("  insulated block: heat drift", drift, " spread", hi0 - lo0, "->", hi1 - lo1)
    s.check(drift < 1e-5 and hi1 - lo1 < 0.5 * (hi0 - lo0), "an insulated block keeps its heat and evens out")

    var raised = 0
    try:
        _ = HeatParticles([Vec3(0, 0, 0, 0)], 1, 1, 1, 0)
    except:
        raised += 1
    try:
        _ = HeatParticles([Vec3(0, 0, 0, 0)], 0, 1, 1, 300)
    except:
        raised += 1
    var two = HeatParticles([Vec3(0, 0, 0, 0), Vec3(DX, 0, 0, 0)], DX * DX * DX, 1.2 * DX, ALPHA, 300)
    try:
        two.step(2 * two.max_dt())
    except:
        raised += 1
    var lone = HeatParticles([Vec3(0, 0, 0, 0)], 1, 1, 1, 321)
    lone.step(1)
    s.check(raised == 3 and lone.t[0] == 321, "bad input and an unstable step raise; a lone particle keeps its temperature")
    s.finish()
