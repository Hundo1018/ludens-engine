# tier: unit
"""Temperature ceiling and cell isolation in `HeatGrid` (ROADMAP 17.61).

  1. The public input check: a temperature above `T_MAX` (1e5 K) raises in
     the constructor and in `fix`; a value at the ceiling is accepted. Zero
     and negative temperatures still raise.
  2. Isolation: a cell whose value is not finite (set from outside the API,
     the only way it can happen) is reset to the mean of its finite
     neighbours and counted in `isolated`; the step runs and every cell
     stays finite. On a uniform 300 K grid the reset value is exactly 300 K,
     so the rest of the field is unchanged by the isolation.
  3. A clean grid is never counted: `isolated` stays 0 over 50 steps.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real
from physics.thermal import HeatGrid, T_MAX


def grid(t0: Real) raises -> HeatGrid:
    return HeatGrid(8, 8, 8, 1e-3, 1e-5, t0)


def raises_on(t: Real) -> Bool:
    try:
        _ = grid(t)
        return False
    except:
        return True


def raises_fix(t: Real) raises -> Bool:
    var g = grid(300)
    try:
        g.fix(1, 1, 1, t)
        return False
    except:
        return True


def main() raises:
    var s = Suite("thermal_guard")

    s.check(raises_on(1e9), "a 1e9 K constructor value raises")
    s.check(raises_fix(1e9), "a 1e9 K fixed cell raises")
    s.check(raises_on(0), "0 K still raises")
    s.check(raises_on(-5), "a negative temperature still raises")
    s.check(not raises_on(T_MAX), "a value at the ceiling is accepted")
    s.check(raises_on(T_MAX * 1.01), "a value just above the ceiling raises")

    var zero: Real = 0
    var nan = zero / zero
    var inf = Real(1) / zero
    var g = grid(300)
    g.t[g.idx(3, 3, 3)] = nan
    g.t[g.idx(5, 2, 6)] = inf
    g.step(1e-4)
    var all_finite = True
    var worst: Real = 0
    for c in range(len(g.t)):
        if not isfinite(g.t[c]):
            all_finite = False
        else:
            var d = g.t[c] - 300
            if d < 0:
                d = -d
            if d > worst:
                worst = d
    s.check(g.isolated == 2, "two non-finite cells are isolated and counted")
    s.check(all_finite, "after the step every cell is finite")
    s.check(worst <= 1e-3, "the uniform field is unchanged by the isolation (worst deviation " + String(worst) + " K)")

    var clean = grid(300)
    clean.fix(0, 0, 0, 350)
    for _ in range(50):
        clean.step(1e-4)
    s.check(clean.isolated == 0, "a clean grid is never counted over 50 steps")

    s.finish()
