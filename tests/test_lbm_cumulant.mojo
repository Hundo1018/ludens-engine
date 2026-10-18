# tier: unit
"""Cumulant collision on D3Q27, periodic (ROADMAP 17.60,
`fluid.lbm_cumulant`).

  1. Ordinary: a Taylor-Green vortex (extruded in z, amplitude 0.03, 32^3,
     nu 0.02) decays at the analytic rate exp(-4 nu k^2 t): after 400 steps
     the energy ratio is within 2 % of it and within 1 % of the D3Q27 BGK
     control's; mass is conserved to 1e-6 (relative).
  2. Galilean invariance: the same vortex (16^3, 200 steps) carried by a
     uniform flow u0 = 0.05 / 0.1 / 0.2. Without the correction of Geier
     et al. 2015 (`galilean` = 0) the decay slows by 1.35 / 5.5 / 24.5 %
     (BGK 0.88 / 3.6 / 15 %): the lattice cannot hold a third central
     moment (c^3 = c on {-1, 0, 1}) and the error scales as u0^2. With it
     (the default, `galilean` = 1: the u^2 grad u terms from the
     velocity-gradient estimate added to the diagonal relaxation) the
     deviations are 0.0 / 0.01 / 2.7 %; checked: under 0.5 % at u0 = 0.1,
     under 5 % at 0.2, and the uncorrected u0^2 scaling (x3..5 from 0.05
     to 0.1).
  3. Stability: a double shear layer (32^3, u 0.1, layer width 1/40,
     perturbation 0.05 in v) at nu 1e-4, 3000 steps: BGK blows up (NaN or
     > 1e30) in under 1000 steps; the cumulant collision survives at least
     twice as long. It does not stay stable (measured: it fails at about
     step 1950 at nu 1e-4 and 1500 at 1e-5 and 1e-6, the shear layer
     being under-resolved, with or without the Galilean correction); the
     numbers are printed.
  4. Extreme: n < 4 and nu <= 0 raise.
"""

from std.math import sin, cos, pi, exp, tanh
from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm_cumulant import Lbm27


def taylor_green(n: Int, nu: Real, amp: Real, u0: Real, galilean: Real = 1) raises -> Lbm27:
    var l = Lbm27(n, nu)
    l.galilean = galilean
    var k = 2 * Real(pi) / Real(n)
    for z in range(n):
        for y in range(n):
            for x in range(n):
                var xf = k * (Real(x) + 0.5)
                var yf = k * (Real(y) + 0.5)
                var ux = -amp * cos(xf) * sin(yf) + u0
                var uy = amp * sin(xf) * cos(yf)
                var rho = 1 - 3 * amp * amp / 4 * (cos(2 * xf) + cos(2 * yf))
                l.set_equilibrium((z * n + y) * n + x, rho, ux, uy, 0)
    return l^


def fluct_energy(l: Lbm27, u0: Real) -> Real:
    """Kinetic energy of the flow relative to the uniform velocity (u0, 0, 0)."""
    var e = Float64(0)
    for c in range(l.cells()):
        var r = l.density(c)
        var u = l.velocity(c)
        var dx = u[0] - u0
        e += 0.5 * Float64(r) * Float64(dx * dx + u[1] * u[1] + u[2] * u[2])
    return Real(e)


def decay(cumulant: Bool, n: Int, u0: Real, steps: Int, galilean: Real = 1) raises -> Real:
    var l = taylor_green(n, 0.02, 0.03, u0, galilean)
    var e0 = fluct_energy(l, u0)
    for _ in range(steps):
        if cumulant:
            l.step()
        else:
            l.step_bgk()
    return fluct_energy(l, u0) / e0


def survive(cumulant: Bool, nu: Real, steps: Int) raises -> Int:
    var n = 32
    var l = Lbm27(n, nu)
    for z in range(n):
        for y in range(n):
            for x in range(n):
                var xf = (Real(x) + 0.5) / Real(n)
                var yf = (Real(y) + 0.5) / Real(n)
                var ux = Real(0.1) * (tanh(40 * (yf - 0.25)) if yf <= 0.5 else tanh(40 * (0.75 - yf)))
                var uy = Real(0.05) * sin(2 * Real(pi) * (xf + 0.25))
                l.set_equilibrium((z * n + y) * n + x, 1, ux, uy, 0)
    for t in range(steps):
        if cumulant:
            l.step()
        else:
            l.step_bgk()
        if not l.is_finite():
            return t
    return steps


def main() raises:
    var s = Suite("lbm_cumulant")
    var steps = 400
    var k = 2 * Real(pi) / 32
    var want = exp(-4 * Float64(0.02) * Float64(k * k) * Float64(steps))
    var cum = decay(True, 32, 0, steps)
    var bgk = decay(False, 32, 0, steps)
    print("  Taylor-Green 32^3, nu 0.02, 400 steps: E/E0 cumulant", cum, " bgk", bgk, " analytic", want)
    s.check(abs(Float64(cum) / want - 1) < 0.02, "cumulant: decay within 2 % of the analytic rate")
    s.check(abs(cum / bgk - 1) < 0.01, "cumulant and BGK decay within 1 % of each other")
    var l = taylor_green(16, 0.02, 0.03, 0)
    var m0 = l.mass()
    for _ in range(100):
        l.step()
    var drift = abs((l.mass() - m0) / m0)
    print("  mass drift after 100 steps (16^3):", drift)
    s.check(drift < 1e-6, "mass conserved to 1e-6")

    var rest_c = decay(True, 16, 0, 200)
    var rest_b = decay(False, 16, 0, 200)
    var off_c = List[Real]()
    var on_c = List[Real]()
    var dev_b = List[Real]()
    for u0 in [Real(0.05), Real(0.1), Real(0.2)]:
        off_c.append(decay(True, 16, u0, 200, 0) / rest_c - 1)
        on_c.append(decay(True, 16, u0, 200, 1) / rest_c - 1)
        dev_b.append(decay(False, 16, u0, 200) / rest_b - 1)
    print("  Galilean error at u0 = 0.05 / 0.1 / 0.2: cumulant uncorrected", off_c[0], off_c[1], off_c[2], " corrected", on_c[0], on_c[1], on_c[2], " bgk", dev_b[0], dev_b[1], dev_b[2])
    var scale_c = off_c[1] / off_c[0]
    s.check(scale_c > 3 and scale_c < 5 and off_c[0] > 0, "uncorrected: the Galilean error grows as u0^2 (x3..5 from 0.05 to 0.1)")
    s.check(abs(on_c[1]) < 0.005 and abs(on_c[2]) < 0.05, "corrected: under 0.5 % at u0 = 0.1 and under 5 % at 0.2")
    s.check(abs(on_c[2]) < 0.5 * abs(dev_b[2]), "corrected cumulant's error at 0.2 is under half of BGK's")

    var tb = survive(False, 1e-4, 3000)
    var tc = survive(True, 1e-4, 3000)
    print("  double shear layer, nu 1e-4: BGK survives", tb, "steps, cumulant", tc, "(of 3000)")
    s.check(tb < 1000, "BGK blows up in under 1000 steps")
    s.check(tc >= 2 * tb, "cumulant survives at least twice as long")

    var raised = 0
    try:
        _ = Lbm27(3, 0.01)
    except:
        raised += 1
    try:
        _ = Lbm27(8, 0)
    except:
        raised += 1
    s.check(raised == 2, "n < 4 and nu <= 0 raise")
    s.finish()
