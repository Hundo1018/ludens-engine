# tier: unit
"""D3Q27 plane Poiseuille flow through the cumulant collision (ROADMAP 17.60,
`fluid.lbm_cumulant` `Lbm27.step`).

Same geometry as `test_lbm27_poiseuille` (BGK path): a 16^3 box, periodic in x
and y, half-way bounce-back walls on the z planes (channel width n), and a
uniform force F along x. Steady profile u(z) = F / (2 nu) (z + 1/2)(n - z - 1/2).

The cumulant collision takes the force as a first-order velocity shift: the
moments are taken about u + F / rho, so the post-collision momentum is rho u + F
per step. This is not the Guo scheme. The shift was chosen over two alternatives
that were measured and rejected in the 17.60 note: shifting by F / (2 rho) gave
a 50 % profile error (half the force is lost), and adding a Guo source to the
post-collision populations gave 33 % to 62 % error.

Bounds (1 % of umax at both tau) were written before the final run. The probe
that chose the shift had already measured 0.32 % at tau 0.8 and 0.12 % at tau
1.5 with this code; this test confirms those numbers, it does not independently
validate the method.
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
        l.step()
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
    var s = Suite("lbm27_cumulant_poiseuille")
    var e08 = _profile_error(Real(0.8), 6000)
    var e15 = _profile_error(Real(1.5), 6000)
    print("  worst profile error / umax: tau 0.8", e08, " tau 1.5", e15)
    s.check(e08 < 0.01, "tau 0.8: profile within 1 % of umax")
    s.check(e15 < 0.01, "tau 1.5: profile within 1 % of umax")
    s.finish()
