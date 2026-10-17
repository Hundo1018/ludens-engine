# tier: unit
"""Oil and water in one SPH (ROADMAP 17.61, `physics.multiphase`).

Box 0.16 x 0.5 x 0.08 m, particles 2 cm apart (8 x 8 x 4 per layer),
B = 1.8e5 Pa (sound speed 15 m/s in the oil), alpha 0.5, dt 4e-4 s
(alpha 0.1 left 0.15 J of spurious motion in a resting equal-density
column and mixed it; 0.5 leaves ~0.01 J).

  1. Ordinary: oil (800 kg/m^3) placed UNDER water (1000) rises through it
     (Rayleigh-Taylor): after 1.5 s the oil's mean height is above the
     water's. Control: the same two layers with equal density (both
     1000) keep their order.
  2. Integration: pairwise pressure and viscosity forces are equal and
     opposite, so horizontal momentum (the walls only act along their
     normals; the box is symmetric) stays near 0; the settled heavy layer
     sits below the light one with a hydrostatic pressure step (printed).
  3. Extreme: dt above the CFL bound and rho0 <= 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.multiphase import MultiphaseSph
from scheduler.rng import SplitMix64

comptime SP: Real = 0.02
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 4e-4


def two_layers(rho_low: Real, rho_high: Real) raises -> MultiphaseSph:
    var m = MultiphaseSph(SP, 1.8e5, 0.5, Vec3(0, 0, 0, 0), Vec3(0.16, 0.5, 0.08, 0))
    var rng = SplitMix64.seeded(5)  # 1 mm jitter seeds the instability
    for j in range(16):
        for i in range(8):
            for k in range(4):
                var jit = Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0) * 0.002
                var p = Vec3((Real(i) + 0.5) * SP, (Real(j) + 0.5) * SP, (Real(k) + 0.5) * SP, 0) + jit
                if j < 8:
                    m.add(p, rho_low, 0)
                else:
                    m.add(p, rho_high, 1)
    return m^


def main() raises:
    var s = Suite("multiphase")
    var oil = two_layers(800.0, 1000.0)
    var same = two_layers(1000.0, 1000.0)
    var d0 = oil.mean_height(0) - oil.mean_height(1)
    var steps = 7500
    var worst_px = Real(0)
    for t in range(steps):
        oil.step(DT, G)
        same.step(DT, G)
        if t % 750 == 749:
            print("  t", Real(t + 1) * DT, "s: oil - water mean height", oil.mean_height(0) - oil.mean_height(1), "  equal densities", same.mean_height(0) - same.mean_height(1))
        var mo = oil.momentum()
        worst_px = max(worst_px, abs(mo[0]), abs(mo[2]))
    var d_oil = oil.mean_height(0) - oil.mean_height(1)
    var d_same = same.mean_height(0) - same.mean_height(1)
    print("start", d0, " after 3 s: oil - water", d_oil, "  equal densities", d_same)
    s.check(d0 < 0 and d_oil > 0, "light liquid placed under the heavy one ends above it")
    s.check(d_same < 0, "equal densities keep their order")
    var total_mass = Real(0)
    for m in oil.mass:
        total_mass += m
    print("worst horizontal momentum", worst_px, "kg m/s  (mass", total_mass, "kg; 1 cm/s of all of it =", total_mass * 0.01, ")")

    # pressure at the bottom vs hydrostatic of the settled column
    var pb = Real(0)
    var nb = 0
    for i in range(oil.count()):
        if oil.x[i][1] < 2 * SP:
            pb += oil.pres[i]
            nb += 1
    pb /= Real(nb)
    var hyd = (800.0 + 1000.0) * 9.8 * 0.16 - 1000.0 * 9.8 * 1.5 * SP
    print("mean pressure in the bottom two rows", pb, "Pa  (hydrostatic, both layers above them:", hyd, ")")

    var raised = 0
    try:
        oil.step(1.0, G)
    except:
        raised += 1
    try:
        oil.add(Vec3(0.05, 0.4, 0.04, 0), 0.0, 2)
    except:
        raised += 1
    s.check(raised == 2, "dt above CFL and rho0 <= 0 raise")
    s.finish()
