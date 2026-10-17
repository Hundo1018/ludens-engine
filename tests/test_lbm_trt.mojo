# tier: component
"""Two-relaxation-time LBM collision (ROADMAP 17.60, `Lbm.trt_lambda`,
`collide_trt`).

  1. Ordinary: a Poiseuille channel (11 nodes across, walls by half-way
     bounce-back) at tau 0.8, 2.0 and 3.5. BGK's error against the analytic
     parabola grows with tau (its walls move with the viscosity: 1.2 % /
     11 % / 53 %); TRT with Lambda = 3/16 cuts it to 0.56 % / 2.5 % / 5.1 %
     (asserted: under half at every tau, under a fifth at 3.5). It still
     grows with tau: the exact wall placement of Lambda = 3/16 assumes a
     second-order force term, and this lattice forces by a velocity shift
     (shifted by tau- F / rho under TRT -- by tau F / rho, as BGK, the
     error was 29 % at tau 0.8).
  2. Integration: a shear wave decays at the input viscosity within 5 %
     under TRT (as BGK, test_lbm_validation).
  3. Extreme: TRT with Lambda = (tau - 1/2)^2 relaxes both parts at 1/tau,
     which is BGK: the populations agree with BGK's within 1e-6 after 200
     steps; trt_lambda = 0 is BGK itself (the golden sections of the
     BGK tests are unchanged).
"""

from std.math import pi, sin, log
from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm import Lbm, BC_PERIODIC, CELL_SOLID
from fluid.d3q19 import equilibrium

comptime N = 11


def _poiseuille(nu: Real, lam: Real) -> Real:
    var ch = Lbm(4, N, 4, nu, BC_PERIODIC)
    for z in range(4):
        for x in range(4):
            ch.flag[ch.idx(x, 0, z)] = CELL_SOLID
            ch.flag[ch.idx(x, N - 1, z)] = CELL_SOLID
    ch.init_uniform(1.0, 0, 0, 0)
    ch.force_x = Real(1e-5)
    ch.trt_lambda = lam
    var steps = Int(3000 / nu) + 2000
    for _ in range(steps):
        ch.step()
    var hw = Real(N - 2) * 0.5
    var umax = ch.force_x * hw * hw / (2 * nu)
    var worst = Real(0)
    for y in range(1, N - 1):
        var yy = Real(y) - Real(N - 1) * 0.5
        var ua = ch.force_x * (hw * hw - yy * yy) / (2 * nu)
        worst = max(worst, abs(ch.velocity(ch.idx(2, y, 2))[0] - ua))
    return worst / umax


def main() raises:
    var s = Suite("lbm_trt")
    var nus = [Real(0.1), Real(0.5), Real(1.0)]
    var bgk = List[Real]()
    var trt = List[Real]()
    for nu in nus:
        bgk.append(_poiseuille(nu, 0))
        trt.append(_poiseuille(nu, 3.0 / 16.0))
    print("  Poiseuille relative error, tau 0.8 / 2.0 / 3.5: BGK", bgk[0], bgk[1], bgk[2], ";  TRT 3/16", trt[0], trt[1], trt[2])
    s.check(bgk[2] > 2 * bgk[0] and trt[0] < 0.5 * bgk[0] and trt[1] < 0.5 * bgk[1] and trt[2] < 0.2 * bgk[2], "BGK's error grows with tau; TRT 3/16 halves it at every tau, 5x at tau 3.5")

    comptime NY = 32
    var nu_in = Real(0.03)
    var l = Lbm(4, NY, 4, nu_in, BC_PERIODIC)
    l.trt_lambda = 3.0 / 16.0
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
        l.step()
    var a1 = Real(0)
    for y in range(NY):
        a1 += l.velocity(l.idx(0, y, 0))[0] * Real(sin(2 * pi * Float64(y) / Float64(NY)))
    var k = 2 * Real(pi) / Real(NY)
    var nu_m = -log(a1 / a0) / (k * k * 400)
    print("  shear wave under TRT: nu measured", nu_m, " input", nu_in)
    s.check(abs(nu_m / nu_in - 1) < 0.05, "TRT recovers the input viscosity (5 %)")

    var a = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    var b = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    for c in range(a.cells()):
        var x = c % 6
        for i in range(19):
            a.f[i * a.cells() + c] = equilibrium(i, 1.0, 0.01 * Real(sin(Float64(x))), 0.005, 0)
            b.f[i * b.cells() + c] = a.f[i * a.cells() + c]
    b.trt_lambda = (b.tau - 0.5) * (b.tau - 0.5)
    for _ in range(200):
        a.step()
        b.step()
    var worst = Real(0)
    for i in range(len(a.f)):
        worst = max(worst, abs(a.f[i] - b.f[i]))
    print("  TRT with tau- = tau vs BGK, 200 steps: worst population difference", worst)
    s.check(worst < 1e-6, "TRT with equal rates is BGK")
    s.finish()
