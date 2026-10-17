# tier: integration
"""Conduction after thermal expansion (ROADMAP 17.61, `HeatTets.refresh`).

A 4 x 2 x 2 tet beam (1 cm cells) at 400 K, `expand`ed with
alpha_L 1.2e-3 from 300 K: every rest shape scales by s = 1.12.

  1. `refresh` rebuilds the conductances from the expanded rest shapes:
     each scales by s (vol s^3, gradients 1 / s) and the step bound by
     1 / s; capacities (mass) stay.
  2. The insulated, expanded beam still keeps its heat under `step`.
  3. A body with another element count raises.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.fem import FemBody, make_beam
from physics.thermal import HeatTets


def main() raises:
    var s = Suite("thermal_refresh")
    var b = FemBody(1e5, 0.3)
    make_beam(b, 4, 2, 2, 0.01, 0.001)
    var h = HeatTets(b, 1e-5, 400)
    var k0 = h.kel.copy()
    var c0 = h.cap.copy()
    var dt0 = h.max_dt()
    h.expand(b, 300, 1.2e-3)
    var unchanged = True
    for e in range(len(k0)):
        unchanged = unchanged and h.kel[e] == k0[e]
    h.refresh(b)
    var sc = Real(1.12)
    var worst = Real(0)
    for e in range(len(k0)):
        if abs(k0[e]) > 0:
            worst = max(worst, abs(h.kel[e] / (k0[e] * sc) - 1))
    var same_cap = True
    for i in range(len(c0)):
        same_cap = same_cap and h.cap[i] == c0[i]
    print("conductance / (s x rest) worst rel. error", worst, "  max_dt", dt0, "->", h.max_dt(), " ratio", dt0 / h.max_dt())
    s.check(unchanged, "expand alone leaves the conductances at the rest shape")
    s.check(worst < 1e-5, "refresh: conductances scale by s")
    s.check(abs(dt0 / h.max_dt() / sc - 1) < 1e-5, "refresh: step bound scales by 1 / s")
    s.check(same_cap, "capacities (mass) unchanged")

    for i in range(len(h.t)):
        h.t[i] = 300 + Real((i * 13) % 40)
    var q0 = h.heat()
    for _ in range(200):
        h.step(0.9 * h.max_dt())
    print("insulated expanded beam: heat drift", abs(h.heat() / q0 - 1))
    s.check(abs(h.heat() / q0 - 1) < 1e-5, "expanded beam keeps its heat")

    var other = FemBody(1e5, 0.3)
    make_beam(other, 2, 1, 1, 0.01, 0.001)
    var raised = False
    try:
        h.refresh(other)
    except:
        raised = True
    s.check(raised, "different element count raises")
    s.finish()
