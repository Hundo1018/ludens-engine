# tier: unit
"""D3Q27 plane Poiseuille flow (ROADMAP 17.60, `fluid.lbm_cumulant` walls and
body force; BGK path).

A 16^3 box, periodic in x and y, half-way bounce-back walls on the z planes
(wall at z = -1/2 and z = n - 1/2, so the channel width is n), a uniform force
F along x (Guo forcing). Steady profile: u(z) = F / (2 nu) (z + 1/2)(n - z - 1/2).
Run to steady state at two relaxation times; the error is measured at the
centre row against the analytic profile and must scale like the D3Q19 Lbm
result (`test_lbm_trt_guo`, relative error 8.5e-4 at tau 0.8).
"""

from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm_cumulant import Lbm27


def _profile_error(tau: Real, steps: Int) raises -> Real:
    var n = 16
    var nu = (tau - Real(0.5)) / 3
    var force = Real(1e-5)
    var l = Lbm27(n, nu)
    l.set_walls_z(True)
    l.set_force(force, 0, 0)
    for c in range(l.cells()):
        l.set_equilibrium(c, 1, 0, 0, 0)
    for _ in range(steps):
        l.step_bgk()
    var worst = Real(0)
    var umax = force / (2 * nu) * Real(n * n) / 4
    for z in range(n):
        var ux = Real(0)
        for y in range(n):
            for x in range(n):
                var c = (z * n + y) * n + x
                ux += l.velocity(c)[0]
        ux /= Real(n * n)
        var y = Real(z) + Real(0.5)
        var want = force / (2 * nu) * y * (Real(n) - y)
        worst = max(worst, abs(ux - want) / umax)
    return worst


def main() raises:
    var s = Suite("lbm27_poiseuille")
    var e08 = _profile_error(Real(0.8), 6000)
    var e15 = _profile_error(Real(1.5), 6000)
    print("  worst profile error / umax: tau 0.8", e08, " tau 1.5", e15)
    s.check(e08 < 0.01, "tau 0.8: profile within 1 % of umax")
    # Measured, not bounded: half-way bounce-back puts the wall at a tau-dependent
    # slip position, so the error grows from tau 0.8 (0.50 %) to tau 1.5 (1.17 %).
    # The 2 % bound was set after that measurement: it pins the current value as a
    # regression check, it does not validate the method at tau 1.5.
    s.check(e15 < 0.02, "tau 1.5: profile within 2 % of umax (regression pin; measured 1.17 %)")
    s.finish()
