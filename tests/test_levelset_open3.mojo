# tier: integration
"""3-D open boundaries for the level set (ROADMAP 17.60,
`physics.mac_levelset3`, `LevelSetWater3.set_open`), checked against the 2-D
outlet (`LevelSetWater2.set_open`, test_levelset_open).

Setup: 16 x 16 x 16 cells, dx 1/16 m, dt 1/240 s, 60 steps (0.25 s), gravity
9.81 along -y. A liquid slab x in [0.25, 0.75], y in [0, 0.5] m sits on the
floor. The 3-D box is extruded in z beyond the domain, as in test_levelset3,
so the z walls are not wet and the slab is uniform in z. Run A: the floor is an
outlet, other walls solid. The 2-D run uses the same grid, dt and walls.

Smoothed volume: V = sum H(phi) dx^d (d = 2 or 3), H as in test_levelset_open.

Predictions, written before the run:
  P1. The 3-D run stays z-invariant: every z plane of phi matches the middle
      plane to 1e-4 dx (the solver floor, 5.7e-5 dx in the closed box).
  P2. The middle plane matches the 2-D outlet run to 1e-3 dx everywhere.
  P3. Per unit depth, the 3-D volume matches the 2-D volume: |V3 / (n dx) -
      V2| / V2 < 1e-3.
  P4. The slab drains: V(0.25 s) < 0.9 V0 in 3-D.

Measured (first run, 2026-10-27, 4/4 pass): z invariance 0.0 dx; middle plane
against 2-D 0.0 dx (identical to the printed precision); volume per unit depth
relative difference 4.5e-7 (summation order over 16^3 against 16^2 cells);
V(0.25 s) / V0 = 0.332. The exact zeros are recorded as measured, not
assumed: the bounds P1 and P2 are the predictions, and both hold with room.
"""

from harness.runner import Suite
from geometry.vec import Real
from std.math import sin
from physics.mac_levelset import LevelSetWater2
from physics.mac_levelset3 import LevelSetWater3

comptime PI: Real = 3.141592653589793
comptime N = 16
comptime STEPS = 60


def _h(f: Real, eps: Real) -> Real:
    if f < -eps:
        return Real(1)
    if f > eps:
        return Real(0)
    return 0.5 * (1 - f / eps - sin(PI * f / eps) / PI)


def main() raises:
    var s = Suite("levelset_open3")
    var dx = Real(1) / Real(N)
    var dt = Real(1) / Real(240)

    var ls3 = LevelSetWater3(N, dx, 9.81)
    ls3.set_box(0.25, 0.0, -1.0, 0.75, 0.5, 2.0)
    ls3.set_open(False, False, True, False, False, False)
    var ls2 = LevelSetWater2(N, dx, 9.81)
    ls2.set_box(0.25, 0.0, 0.75, 0.5)
    ls2.set_open(False, False, True, False)

    var v3_0 = Real(0)
    var v2_0 = Real(0)
    for c in range(N * N * N):
        v3_0 += _h(ls3.phi[c], dx)
    for c in range(N * N):
        v2_0 += _h(ls2.phi[c], dx)
    var v3_init = v3_0 * dx * dx * dx
    var v2_init = v2_0 * dx * dx
    print("  initial: 3-D", v3_init, " 2-D", v2_init, " (per unit depth)", v3_init / (Real(N) * dx))

    for _ in range(STEPS):
        ls3.step(dt)
        ls2.step(dt)

    var dmax_z = Real(0)
    var dmax_2d = Real(0)
    var mid = N // 2
    for k in range(N):
        for j in range(N):
            for i in range(N):
                var d = abs(ls3.phi[(k * N + j) * N + i] - ls3.phi[(mid * N + j) * N + i])
                dmax_z = max(dmax_z, d)
    for j in range(N):
        for i in range(N):
            var d = abs(ls3.phi[(mid * N + j) * N + i] - ls2.phi[j * N + i])
            dmax_2d = max(dmax_2d, d)

    var v3 = Real(0)
    var v2 = Real(0)
    for c in range(N * N * N):
        v3 += _h(ls3.phi[c], dx)
    for c in range(N * N):
        v2 += _h(ls2.phi[c], dx)
    var V3 = v3 * dx * dx * dx
    var V2 = v2 * dx * dx
    var per_depth_err = abs(V3 / (Real(N) * dx) - V2) / V2

    print("  z invariance max |dphi| / dx:", dmax_z / dx)
    print("  3-D mid plane against 2-D max |dphi| / dx:", dmax_2d / dx)
    print("  V3 per unit depth", V3 / (Real(N) * dx), " V2", V2, " relative", per_depth_err)
    print("  V3(0.25 s) / V0:", V3 / v3_init)

    s.check(dmax_z / dx < 1e-4, "P1 3-D run is z-invariant (max |dphi| < 1e-4 dx)")
    s.check(dmax_2d / dx < 1e-3, "P2 3-D middle plane matches the 2-D outlet run (< 1e-3 dx)")
    s.check(per_depth_err < 1e-3, "P3 3-D volume per unit depth matches the 2-D volume (< 1e-3)")
    s.check(V3 < 0.9 * v3_init, "P4 the 3-D slab drains (V(0.25 s) < 0.9 V0)")
    s.finish()
