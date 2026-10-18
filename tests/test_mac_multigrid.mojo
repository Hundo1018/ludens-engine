# tier: integration
"""MAC projection with Jacobi PCG vs multigrid-preconditioned CG (ROADMAP
17.84, `MacFluid2.use_multigrid`). The pressure-solver seam's parity test.

A hot Gaussian blob in a 64^2 periodic box (test_smoke's scene, buoyancy 4,
epsilon 2) stepped 1 s (100 steps) with each solver:

  1. Parity: every projection converges with both; the velocity fields
     differ by < 1 % of the peak speed and the kinetic energies by < 1 %
     after 1 s; the worst post-projection divergence of both is < 1e-3 of
     peak speed / dx.
  2. Cost: total iterations over the run (printed); MGPCG uses fewer than a
     quarter of Jacobi PCG's.
  3. Extreme: `use_multigrid` on n = 48 (not a power of two) raises.
"""

from std.math import exp
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2, Smoke2

comptime N = 64
comptime DX: Real = 1.0 / 64.0
comptime DT: Real = 0.01


def smoke(mg: Bool) raises -> Smoke2:
    var f = MacFluid2(N, DX, 1e-4)
    if mg:
        f.use_multigrid()
    var s = Smoke2(f^, 4, 2)
    for j in range(N):
        for i in range(N):
            var x = (Real(i) + 0.5) * DX - 0.5
            var y = (Real(j) + 0.5) * DX - 0.2
            s.temp[j * N + i] = exp(-(x * x + y * y) / (0.06 * 0.06))
    return s^


def main() raises:
    var st = Suite("mac_multigrid")
    var a = smoke(False)
    var b = smoke(True)
    var it_a = 0
    var it_b = 0
    var conv = True
    var div_a = Real(0)
    var div_b = Real(0)
    for _ in range(100):
        a.step(DT)
        b.step(DT)
        it_a += a.fluid.last.iters
        it_b += b.fluid.last.iters
        conv = conv and a.fluid.last.converged and b.fluid.last.converged
        var da = a.fluid.divergence()
        var db = b.fluid.divergence()
        for k in range(N * N):
            div_a = max(div_a, abs(da[k]))
            div_b = max(div_b, abs(db[k]))
    var peak = Real(0)
    var du = Real(0)
    for k in range(N * N):
        peak = max(peak, max(abs(a.fluid.u[k]), abs(a.fluid.v[k])))
        du = max(du, max(abs(a.fluid.u[k] - b.fluid.u[k]), abs(a.fluid.v[k] - b.fluid.v[k])))
    var ka = a.kinetic_energy()
    var kb = b.kinetic_energy()
    print("1 s: peak speed", peak, " max velocity difference", du, " KE", ka, kb, " worst divergence", div_a, div_b, "(peak/dx", peak / DX, ")")
    print("iterations over 100 steps: Jacobi PCG", it_a, " MGPCG", it_b)
    st.check(conv and du < 0.01 * peak and abs(ka / kb - 1) < 0.01, "both solvers converge every step and agree (1 % of peak speed, 1 % KE)")
    st.check(div_a < 1e-3 * peak / DX and div_b < 1e-3 * peak / DX, "both leave the field divergence-free")
    st.check(4 * it_b < it_a, "MGPCG needs < 1/4 of Jacobi PCG's iterations")
    var raised = False
    try:
        var g = MacFluid2(48, 0.1, 0)
        g.use_multigrid()
    except:
        raised = True
    st.check(raised, "n = 48 raises")
    st.finish()
