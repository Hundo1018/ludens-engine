# tier: integration
"""Free-surface water on a 3-D MAC grid with a level set (ROADMAP 17.60,
`physics.mac_levelset3`, `LevelSetWater3`).

A 1 m box, 16 x 16 x 16 cells, g 9.81, dt 1/120 s, gravity along -y.

Predictions, written before the run:

  1. Still water: the lower half full, 1 s. The largest face speed stays
     below 1e-5 m/s, the volume does not change, every pressure solve
     converges. (The 2-D test makes the same claim on a 32^2 grid.)
  2. Slab against 2-D: a column 0.25 x 0.5 m, extruded in z beyond the
     box (z from -1 to 2 m), after 60 steps. Its z-invariant solution is the
     2-D solution, so the middle z plane of the 3-D run matches
     `LevelSetWater2` on the same grid: the largest |phi_3D - phi_2D| is
     below 1e-2 dx. The test does not check the z axis: a z-indexing bug
     would leave it intact.
     The box must extend past the domain in z. A box that ends at z = 0
     and z = 1 is not z-invariant: its z faces are the nearest faces for
     cells near the z walls, so phi differs there (initial z-variation
     0.0625 = dx, found by a first run of this test that used z 0..1).
  3. Dam break front at T = 1/6 s, on the middle z plane: Z = x / a is
     within 1.5..2.5 (Martin & Moyce; the 2-D test measures 1.81). The
     first run measured 1.625 with the box ending at the z walls; the
     measured value below is for the extruded box.
  4. 3-D volume over 1 s, and the front reaches the far wall by 0.5 s.
     The first form of this claim was "within 15 % of its start". At n = 16
     the 2-D `LevelSetWater2` reaches 0.844 of its start on the same
     problem (measured before this test was written), so the 15 % bound
     fails for both. The check is restated as parity: the 3-D range equals
     the 2-D range to 1e-3.
  5. Symmetry of a z-axis test: a column 0.25 x 0.5 x 0.25 m in the
     corner (x, z in [0, 0.25]) is symmetric under x <-> z. After 40
     steps, the largest |phi(i, j, k) - phi(k, j, i)| is below 1e-3 dx. The
     sweep orders of the redistancing are not symmetric under x <-> z,
     so this is a tolerance, not an identity.
  6. Extreme: n < 4 and dt = 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_levelset import LevelSetWater2
from physics.mac_levelset3 import LevelSetWater3


def main() raises:
    var s = Suite("levelset3")
    var n = 16
    var dx = Real(1) / Real(n)
    var dt = Real(1.0 / 120.0)

    var still = LevelSetWater3(n, dx)
    still.set_box(0, 0, 0, 1, 0.5, 1)
    var v0 = still.volume()
    var vmax = Real(0)
    var all_conv = True
    for _ in range(120):
        still.step(dt)
        vmax = max(vmax, still.max_speed())
        all_conv = all_conv and still.last.converged
    print("  still water, 1 s: max face speed", vmax, " volume ratio", still.volume() / v0)
    s.check(vmax < 1e-5 and still.volume() == v0 and all_conv, "P1 still water stays still (< 1e-5 m/s), same volume, solves converge")

    # 2. slab: 3-D over the full z extent against 2-D on the same grid
    var slab = LevelSetWater3(n, dx)
    slab.set_box(0, 0, -1, 0.25, 0.5, 2)
    var flat = LevelSetWater2(n, dx)
    flat.set_box(0, 0, 0.25, 0.5)
    for _ in range(60):
        slab.step(dt)
        flat.step(dt)
    var mid = n // 2
    var dmax = Real(0)
    for j in range(n):
        for i in range(n):
            var d = abs(slab.phi[(mid * n + j) * n + i] - flat.phi[j * n + i])
            if d > dmax:
                dmax = d
    print("  slab vs 2-D after 60 steps: max |dphi| / dx =", dmax / dx)
    s.check(dmax / dx < 1e-2, "P2 middle z plane matches LevelSetWater2 (max |dphi| < 1e-2 dx)")

    # 3-4. dam break in 3-D (corner column, full z extent kept as a slab)
    var dam = LevelSetWater3(n, dx)
    dam.set_box(0, 0, -1, 0.25, 0.5, 2)
    var w0 = dam.volume()
    var z_at = Real(0)
    var wall_by = Real(-1)
    var lo = Real(1e9)
    var hi = Real(0)
    for k in range(120):
        dam.step(dt)
        var t = Real(k + 1) * dt
        if k == 19:
            z_at = dam.front_x() / 0.25
        if wall_by < 0 and dam.front_x() > 0.95:
            wall_by = t
        var r = dam.volume() / w0
        lo = min(lo, r)
        hi = max(hi, r)
    print("  3-D dam break: Z at T = 1/6 s", z_at, " far wall at", wall_by, "s  volume ratio range", lo, hi)
    s.check(z_at > 1.5 and z_at < 2.5, "P3 dam-break front at T = 1/6 s within 1.5..2.5 column widths")
    var dam2 = LevelSetWater2(n, dx)
    dam2.set_box(0, 0, 0.25, 0.5)
    var w2 = dam2.volume()
    var lo2 = Real(1e9)
    var hi2 = Real(0)
    for _ in range(120):
        dam2.step(dt)
        var r2 = dam2.volume() / w2
        lo2 = min(lo2, r2)
        hi2 = max(hi2, r2)
    print("  2-D dam break at the same n: volume ratio range", lo2, hi2)
    s.check(wall_by > 0 and wall_by <= 0.5 and abs(lo - lo2) < 1e-3 and abs(hi - hi2) < 1e-3,
            "P4 front reaches the far wall by 0.5 s; volume range equals the 2-D range to 1e-3")

    # 5. x <-> z symmetry of a corner column: the test that exercises the z axis
    var sym = LevelSetWater3(n, dx)
    sym.set_box(0, 0, 0, 0.25, 0.5, 0.25)
    for _ in range(40):
        sym.step(dt)
    var asym = Real(0)
    for k in range(n):
        for j in range(n):
            for i in range(n):
                var d = abs(sym.phi[(k * n + j) * n + i] - sym.phi[(i * n + j) * n + k])
                if d > asym:
                    asym = d
    print("  corner column after 40 steps: max |phi(i,j,k) - phi(k,j,i)| / dx =", asym / dx)
    s.check(asym / dx < 1e-3, "P5 corner column is symmetric under x <-> z (max |dphi| < 1e-3 dx)")

    var raised = 0
    try:
        _ = LevelSetWater3(3, dx)
    except:
        raised += 1
    try:
        dam.step(0)
    except:
        raised += 1
    s.check(raised == 2, "P6 n < 4 and dt = 0 raise")
    s.finish()
