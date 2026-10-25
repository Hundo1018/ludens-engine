# tier: integration
"""Cloth <-> lattice air, two-way (ROADMAP 17.61, `physics.cloth_air`).

Air: `Lbm` 24^3, periodic, dx 2 cm, 1 ms per lattice step, rho 1.2,
lattice viscosity 0.05 (0.02 m^2/s: far more viscous than air, so the
lattice stays stable at this resolution). Cloth: 0.2 m square sheet,
6 x 6 cells, 0.1 kg/m^2 (4 g), horizontal, no damping; drag k = 2
kg/(m^2 s), so the one-way terminal speed is m g / (k A) = 0.49 m/s.

  1. Ordinary: one-way (still air), the sheet reaches 0.49 m/s within 5 %.
     Two-way, the sheet drags the air down with it and falls faster;
     a sheet pinned across an upward flow leaves a slower wake above it
     than beside it.
  2. Integration (conservation): two-way, the air's momentum changes by
     what the cloth gave it (1e-3) and the two impulses are equal and
     opposite; one-way, the air's momentum does not change. Cloth + air
     momentum vs weight x time is printed with the drag-free fall beside
     it: the cloth's XPBD velocity (f32 position differences) loses a few
     % of momentum by itself.
  3. Extreme: k = 0 exchanges nothing; bad parameters raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from fluid.lbm import Lbm
from physics.cloth import MeshCloth, grid_mesh
from physics.cloth_air import ClothAir

comptime NL = 24
comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime RHO: Real = 1.2
comptime G = Vec3(0, -9.8, 0, 0)


def air(uy: Real = 0) -> Lbm:
    var l = Lbm(NL, NL, NL, 0.05)
    l.init_uniform(1.0, 0.0, uy, 0.0)
    return l^


def sheet() raises -> MeshCloth:
    var m = grid_mesh(6, 6, 0.2, 0.2, Vec3(0.14, 0.30, 0.14, 0))
    var c = MeshCloth(m[0], m[1], 0.1, 0, 1e-3)
    c.damping = 1.0
    return c^


def mean_vy(c: MeshCloth) -> Real:
    var s = Real(0)
    for v in c.v:
        s += v[1]
    return s / Real(len(c.v))


def momentum(c: MeshCloth) -> Vec3:
    var m = Vec3(0, 0, 0, 0)
    for i in range(len(c.v)):
        if c.w[i] > 0:
            m = m + c.v[i] * (1 / c.w[i])
    return m


def main() raises:
    var s = Suite("cloth_air")
    var steps = 300

    # one-way vs two-way free fall
    var c1 = sheet()
    var a1 = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 2.0, two_way=False)
    var p1 = a1.air_momentum()
    var c2 = sheet()
    var a2 = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 2.0)
    var p2 = a2.air_momentum()
    for _ in range(steps):
        a1.step(c1, G)
        a2.step(c2, G)
    var mass = c2.total_mass()
    var term = mass * 9.8 / (2.0 * 0.04)
    var v1 = mean_vy(c1)
    var v2 = mean_vy(c2)
    print("after 0.3 s: sheet vy one-way", v1, " two-way", v2, " (terminal one-way", -term, ")")
    var air_dy = a2.air_momentum()[1] - p2[1]
    print("  two-way: air momentum change y", air_dy, " air impulse", a2.air_impulse[1], " cloth impulse", a2.cloth_impulse[1])
    var total = momentum(c2)[1] + air_dy
    print("  cloth + air momentum y", total, " weight x time", -mass * 9.8 * Real(steps) * DT)
    print("  one-way: air momentum change", length(a1.air_momentum() - p1))
    s.check(abs(v1 + term) < 0.05 * term, "one-way: terminal speed m g / (k A) within 5 %")
    s.check(v2 < v1, "two-way: the sheet drags the air and falls faster")
    s.check(abs(air_dy - a2.air_impulse[1]) < 1e-3 * abs(a2.air_impulse[1]), "two-way: air momentum changes by the impulse it got (1e-3)")
    s.check(length(a2.cloth_impulse + a2.air_impulse) < 1e-6 * length(a2.air_impulse), "two-way: cloth and air impulses are equal and opposite")
    # the remaining gap to weight x time is the cloth's own: XPBD velocity
    # from f32 position differences loses momentum in free fall too
    var cf = sheet()
    var af = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 0.0)
    for _ in range(steps):
        af.step(cf, G)
    print("  free fall without drag: momentum y", momentum(cf)[1], " weight x time", -mass * 9.8 * Real(steps) * DT)
    s.check(length(a1.air_momentum() - p1) == 0, "one-way: the air is untouched")

    # a pinned sheet across an upward flow: wake above it
    var c3 = sheet()
    for i in range(len(c3.w)):
        c3.w[i] = 0
    var a3 = ClothAir(air(0.02), Vec3(0, 0, 0, 0), DX, DT, RHO, 2.0)
    var p3 = a3.air_momentum()
    for _ in range(200):
        a3.step(c3, G)
    var behind = a3.air_velocity(Vec3(0.24, 0.36, 0.24, 0))[1]
    var beside = a3.air_velocity(Vec3(0.02, 0.36, 0.02, 0))[1]
    var d3 = a3.air_momentum()[1] - p3[1]
    print("pinned sheet in 0.4 m/s upward flow, 0.2 s: vy above it", behind, " beside", beside, "  air momentum change", d3, " impulse", a3.air_impulse[1])
    s.check(behind < beside, "the pinned sheet leaves a slower wake above it")
    s.check(d3 < 0 and abs(d3 - a3.air_impulse[1]) < 1e-3 * abs(a3.air_impulse[1]), "the flow loses exactly the impulse the sheet takes")

    # k = 0 and bad input
    var c4 = sheet()
    var a4 = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 0.0)
    for _ in range(20):
        a4.step(c4, G)
    s.check(length(a4.air_impulse) == 0 and length(a4.cloth_impulse) == 0, "k = 0: nothing exchanged")
    var raised = 0
    try:
        _ = ClothAir(air(), Vec3(0, 0, 0, 0), 0.0, DT, RHO, 2.0)
    except:
        raised += 1
    try:
        _ = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, -1.0)
    except:
        raised += 1
    s.check(raised == 2, "dx <= 0 / k < 0 raise")
    s.finish()
