# tier: integration
"""Taylor-Green vortex decay across grid solvers (ROADMAP 17.60:
`physics.mac_fluid.MacFluid2` against `fluid.lbm.Lbm`, both against the
analytic rate).

u = U sin(kx) cos(ky), v = -U cos(kx) sin(ky) on a periodic square is an
exact Navier-Stokes solution whose amplitude decays as exp(-2 nu k^2 t)
(its advection is balanced by pressure, so only viscosity remains).

  1. Ordinary: on a 32^2 MAC grid (L = 2 pi, nu 0.05, U 0.01, dt 0.05) the
     measured decay rate over t = 10 is 2 nu k^2 within 3 %, and every
     projection leaves the divergence below 1e-4 of U / dx (PCG converged).
  2. Integration (parity): a 32 x 32 x 1 D3Q19 lattice with the same
     vortex in lattice units (nu 0.05, U 0.01, 400 steps) decays at its
     analytic rate within 3 %; the two solvers' rates, each divided by its
     own 2 nu k^2, agree within 3 %.
  3. Extreme: n < 4, nu < 0 and an explicit-viscosity step past
     nu dt / dx^2 = 1/4 raise; a fluid at rest stays at rest.
"""

from std.math import pi, sin, cos, log
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2
from fluid.lbm import Lbm, BC_PERIODIC
from fluid.d3q19 import equilibrium

comptime N = 32
comptime NU: Real = 0.05
comptime U0: Real = 0.01


def _mac_amp(f: MacFluid2) -> Real:
    var k = 2 * Real(pi) / (Real(N) * f.dx)
    var num = Real(0)
    var den = Real(0)
    for j in range(N):
        for i in range(N):
            var x = Real(i) * f.dx
            var y = (Real(j) + 0.5) * f.dx
            var shape = sin(k * x) * cos(k * y)
            num += f.u[j * N + i] * shape
            den += shape * shape
    return num / den


def _lbm_amp(l: Lbm) -> Real:
    var k = 2 * Real(pi) / Real(N)
    var num = Real(0)
    var den = Real(0)
    for j in range(N):
        for i in range(N):
            var shape = sin(k * Real(i)) * cos(k * Real(j))
            num += l.velocity(l.idx(i, j, 0))[0] * shape
            den += shape * shape
    return num / den


def main() raises:
    var s = Suite("taylor_green")
    var dx = 2 * Real(pi) / Real(N)
    var f = MacFluid2(N, dx, NU)
    for j in range(N):
        for i in range(N):
            f.u[j * N + i] = U0 * sin(Real(i) * dx) * cos((Real(j) + 0.5) * dx)
            f.v[j * N + i] = -U0 * cos((Real(i) + 0.5) * dx) * sin(Real(j) * dx)
    var a0 = _mac_amp(f)
    var dt = Real(0.05)
    var worst_div = Real(0)
    var all_conv = True
    for _ in range(200):
        f.step(dt)
        all_conv = all_conv and f.last.converged
        var d = f.divergence()
        for q in range(N * N):
            worst_div = max(worst_div, abs(d[q]))
    var a1 = _mac_amp(f)
    var rate_mac = -log(a1 / a0) / 10
    var want_mac = 2 * NU * 1.0
    print("  MAC 32^2: amplitude", a0, "->", a1, " decay rate", rate_mac, " analytic", want_mac, " worst divergence", worst_div, "(U/dx", U0 / dx, ")")
    s.check(abs(rate_mac / want_mac - 1) < 0.03 and all_conv and worst_div < 1e-4 * U0 / dx, "MAC: Taylor-Green decays at 2 nu k^2 (3 %), divergence-free")

    var l = Lbm(N, N, 1, NU, BC_PERIODIC)
    var kl = 2 * Real(pi) / Real(N)
    for j in range(N):
        for i in range(N):
            var ux = U0 * sin(kl * Real(i)) * cos(kl * Real(j))
            var uy = -U0 * cos(kl * Real(i)) * sin(kl * Real(j))
            var c = l.idx(i, j, 0)
            for q in range(19):
                l.f[q * l.cells() + c] = equilibrium(q, 1.0, ux, uy, 0)
    var b0 = _lbm_amp(l)
    for _ in range(400):
        l.step()
    var b1 = _lbm_amp(l)
    var rate_lbm = -log(b1 / b0) / 400
    var want_lbm = 2 * NU * kl * kl
    print("  LBM 32 x 32 x 1: amplitude", b0, "->", b1, " decay rate", rate_lbm, " analytic", want_lbm, ";  ratios MAC", rate_mac / want_mac, " LBM", rate_lbm / want_lbm)
    s.check(abs(rate_lbm / want_lbm - 1) < 0.03, "LBM: Taylor-Green decays at 2 nu k^2 (3 %)")
    s.check(abs((rate_mac / want_mac) / (rate_lbm / want_lbm) - 1) < 0.03, "MAC and LBM agree on the decay (3 %)")

    var raised = 0
    try:
        _ = MacFluid2(3, 1, 0.1)
    except:
        raised += 1
    try:
        _ = MacFluid2(8, 1, -1)
    except:
        raised += 1
    var g = MacFluid2(8, 0.1, 0.1)
    try:
        g.step(0.05)
    except:
        raised += 1
    s.check(raised == 3, "bad size, viscosity or explicit step raise")
    var still = MacFluid2(8, 1, 0.01)
    for _ in range(10):
        still.step(0.1)
    var moving = Real(0)
    for q in range(64):
        moving = max(moving, abs(still.u[q]) + abs(still.v[q]))
    s.check(moving == 0, "at rest stays at rest")
    s.finish()
