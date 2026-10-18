# tier: integration
"""Free-surface water: MAC grid + level set (ROADMAP 17.60,
`physics.mac_levelset`).

A 1 m box, 32 x 32 cells, g 9.81, dt 1/120 s.

  1. Ordinary (still water): the lower half full, 1 s: the largest face
     speed stays at rounding level (the ghost-fluid surface pressure
     balances gravity exactly), the volume does not change, every
     pressure solve converges.
  2. Integration (dam break): a 0.25 x 0.5 m column collapses. At
     t = 1/6 s (Martin & Moyce's T = t sqrt(2 g / a) = 1.48) the front is
     at Z = x / a = 1.81 (their measurement ~2.0; between 1.5 and 2.5
     checked); it reaches the far wall by 0.5 s. The volume over 1 s is
     printed: a level set does not conserve it (within 15 % checked).
  3. Extreme: n < 4 and dt = 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_levelset import LevelSetWater2


def main() raises:
    var s = Suite("levelset_water")
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1.0 / 120.0)

    var still = LevelSetWater2(n, dx)
    still.set_box(0, 0, 1, 0.5)
    var v0 = still.volume()
    var vmax = Real(0)
    var all_conv = True
    for _ in range(120):
        still.step(dt)
        vmax = max(vmax, still.max_speed())
        all_conv = all_conv and still.last.converged
    print("  still water, 1 s: max face speed", vmax, " volume ratio", still.volume() / v0)
    s.check(vmax < 1e-5 and still.volume() == v0 and all_conv, "still water stays still (< 1e-5 m/s), same volume, solves converge")

    var dam = LevelSetWater2(n, dx)
    dam.set_box(0, 0, 0.25, 0.5)
    var w0 = dam.volume()
    var z_at = Real(0)
    var wall_by = Real(-1)
    var lo = Real(1e9)
    var hi = Real(0)
    var line = String("  dam break front x:")
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
        if k % 20 == 19:
            line += " " + String(dam.front_x())
    print(line)
    print("  Z at T = 1.48:", z_at, " (Martin & Moyce ~2.0)  far wall reached at", wall_by, "s  volume ratio range", lo, hi)
    s.check(z_at > 1.5 and z_at < 2.5, "dam-break front at T = 1.48 within 1.5..2.5 column widths")
    s.check(wall_by > 0 and wall_by <= 0.5, "the front reaches the far wall by 0.5 s")
    s.check(lo > 0.85 and hi < 1.15, "volume within 15 % over 1 s (level sets do not conserve it)")

    var raised = 0
    try:
        _ = LevelSetWater2(3, dx)
    except:
        raised += 1
    try:
        dam.step(0)
    except:
        raised += 1
    s.check(raised == 2, "n < 4 and dt = 0 raise")
    s.finish()
