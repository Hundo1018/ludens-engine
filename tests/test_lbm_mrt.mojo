# tier: component
"""MRT collision for D3Q19 (ROADMAP 17.60, `fluid.lbm_mrt`).

  1. Ordinary: with every rate at 1/tau (`Mrt.bgk`) the MRT step is BGK:
     populations within 1e-6 of `Lbm.step` after 200 steps of a forced
     6^3 box (3e-7 measured; the moment-space sums round differently).
  2. Integration: a shear wave (32 x 4 x 4, nu 0.03) under the default
     rates decays at the input viscosity within 5 %.
  3. Extreme (stability): a 64^2 double shear layer (u 0.05, width 1/80)
     at nu = 1.7e-4 (tau 0.50051): BGK diverges (populations non-finite or
     > 10) within 2000 steps, MRT does not.
"""

from std.math import sin, tanh, pi, isfinite, log
from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm import Lbm, BC_PERIODIC
from fluid.d3q19 import equilibrium
from fluid.lbm_mrt import Mrt, mrt_step


def shear_layer(nu: Real, n: Int) -> Lbm:
    var l = Lbm(n, n, 1, nu, BC_PERIODIC)
    for y in range(n):
        for x in range(n):
            var yy = Real(y) / Real(n)
            var u = Real(0.05) * (tanh(80 * (yy - 0.25)) if yy <= 0.5 else tanh(80 * (0.75 - yy)))
            var v = Real(0.05) * 0.05 * sin(2 * Real(pi) * (Real(x) / Real(n) + 0.25))
            var c = l.idx(x, y, 0)
            for i in range(19):
                l.f[i * l.cells() + c] = equilibrium(i, 1.0, u, v, 0)
    return l^


def finite(l: Lbm) -> Bool:
    for k in range(len(l.f)):
        if not isfinite(l.f[k]) or abs(l.f[k]) > 10:
            return False
    return True


def main() raises:
    var s = Suite("lbm_mrt")
    var a = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    var b = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    a.init_uniform(1.0, 0.02, 0.01, 0)
    b.init_uniform(1.0, 0.02, 0.01, 0)
    a.force_x = 1e-5
    b.force_x = 1e-5
    var mb = Mrt.bgk(b)
    for _ in range(200):
        a.step()
        mrt_step(b, mb)
    var d = Real(0)
    for k in range(len(a.f)):
        d = max(d, abs(a.f[k] - b.f[k]))
    print("MRT with every rate 1/tau vs BGK: largest population difference", d)
    s.check(d < 1e-6, "MRT(1/tau) == BGK")

    comptime NY = 32
    var nu_in = Real(0.03)
    var l = Lbm(4, NY, 4, nu_in, BC_PERIODIC)
    var mr = Mrt(l)
    for z in range(4):
        for y in range(NY):
            var uy = Real(0.01) * Real(sin(2 * pi * Float64(y) / Float64(NY)))
            for x in range(4):
                var c = l.idx(x, y, z)
                for i in range(19):
                    l.f[i * l.cells() + c] = equilibrium(i, 1.0, uy, 0, 0)
    var a0 = Real(0)
    for y in range(NY):
        a0 += l.velocity(l.idx(0, y, 0))[0] * Real(sin(2 * pi * Float64(y) / Float64(NY)))
    for _ in range(400):
        mrt_step(l, mr)
    var a1 = Real(0)
    for y in range(NY):
        a1 += l.velocity(l.idx(0, y, 0))[0] * Real(sin(2 * pi * Float64(y) / Float64(NY)))
    var k = 2 * Real(pi) / Real(NY)
    var nu_m = -log(a1 / a0) / (k * k * 400)
    print("shear wave under MRT: nu measured", nu_m, " input", nu_in)
    s.check(abs(nu_m / nu_in - 1) < 0.05, "MRT recovers the input viscosity (5 %)")

    var l1 = shear_layer(1.7e-4, 64)
    var l2 = shear_layer(1.7e-4, 64)
    var m2 = Mrt(l2)
    var dead1 = -1

    for st in range(2000):
        if dead1 < 0:
            l1.step()
            if st % 100 == 99 and not finite(l1):
                dead1 = st
        mrt_step(l2, m2)
    var ok2 = finite(l2)
    print("double shear layer, tau", l1.tau, ": BGK diverged by step", dead1, " MRT finite after 2000", ok2)
    s.check(dead1 >= 0 and ok2, "BGK diverges at nu 1.7e-4, MRT stays finite")
    s.finish()
