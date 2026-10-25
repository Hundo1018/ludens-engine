# tier: integration
"""Buoyant smoke with vorticity confinement on the MAC grid (ROADMAP 17.60,
`physics.mac_fluid.Smoke2`). 64^2 periodic box, 1 m, nu 1e-4.

  1. Ordinary: a hot blob (Gaussian, peak 1, radius 6 cm) at the bottom
     rises: its temperature centroid climbs (printed, > 0.1 m in 2 s); with
     buoyancy 0 nothing moves (velocity stays 0).
  2. Integration: buoyancy adds no net momentum (it is taken relative to
     the mean temperature): after the first step |sum v| < 1e-3 sum |v|
     (2.3e-4 measured: the mean is an f32 sum over 4096 cells).
     Later the box does drift (3 % after 2 s, printed): semi-Lagrangian
     advection does not conserve momentum. Vorticity confinement
     (epsilon 2) keeps more kinetic energy and more enstrophy than none
     after 2 s (1.15x and 1.38x measured).
  3. Extreme: epsilon < 0 raises; temperature stays within its initial
     range (semi-Lagrangian advection is bounded by bilinear interpolation).
"""

from std.math import exp
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2, Smoke2

comptime N = 64
comptime DX: Real = 1.0 / 64.0
comptime DT: Real = 0.01


def _smoke(buoy: Real, eps: Real) raises -> Smoke2:
    var s = Smoke2(MacFluid2(N, DX, 1e-4), buoy, eps)
    for j in range(N):
        for i in range(N):
            var x = (Real(i) + 0.5) * DX - 0.5
            var y = (Real(j) + 0.5) * DX - 0.2
            s.temp[j * N + i] = exp(-(x * x + y * y) / (0.06 * 0.06))
    return s^


def _centroid_y(s: Smoke2) -> Real:
    var w = Real(0)
    var acc = Real(0)
    for j in range(N):
        for i in range(N):
            var t = s.temp[j * N + i]
            w += t
            acc += t * (Real(j) + 0.5) * DX
    return acc / w


def _enstrophy(s: Smoke2) -> Real:
    var w = s.vorticity()
    var e = Real(0)
    for k in range(len(w)):
        e += w[k] * w[k]
    return e * DX * DX


def main() raises:
    var st = Suite("smoke")
    var plain = _smoke(4, 0)
    var conf = _smoke(4, 2)
    var calm = _smoke(0, 0)
    var y0 = _centroid_y(plain)
    var tmin = Real(1e30)
    var tmax = Real(-1e30)
    for k in range(N * N):
        tmin = min(tmin, plain.temp[k])
        tmax = max(tmax, plain.temp[k])
    for _ in range(200):
        plain.step(DT)
        conf.step(DT)
        calm.step(DT)
    var y1 = _centroid_y(plain)
    var still = Real(0)
    for k in range(N * N):
        still = max(still, abs(calm.fluid.u[k]) + abs(calm.fluid.v[k]))
    print("  hot blob, 2 s: centroid y", y0, "->", y1, ";  buoyancy 0: max |velocity|", still)
    st.check(y1 - y0 > 0.1 and still == 0, "a hot blob rises; without buoyancy nothing moves")

    var one = _smoke(4, 0)
    one.step(DT)
    var sv1 = Real(0)
    var sa1 = Real(0)
    for k in range(N * N):
        sv1 += one.fluid.v[k]
        sa1 += abs(one.fluid.v[k])
    var sv = Real(0)
    var sa = Real(0)
    for k in range(N * N):
        sv += plain.fluid.v[k]
        sa += abs(plain.fluid.v[k])
    var ke = conf.kinetic_energy() / plain.kinetic_energy()
    var en = _enstrophy(conf) / _enstrophy(plain)
    print("  net vertical momentum after one step", sv1, "of", sa1, ";  after 2 s", sv, "of", sa, ";  confinement / none: kinetic energy", ke, " enstrophy", en)
    st.check(abs(sv1) < 1e-3 * sa1, "buoyancy adds no net momentum to the periodic box")
    st.check(ke > 1 and en > 1, "vorticity confinement keeps more swirl")

    var raised = 0
    try:
        _ = Smoke2(MacFluid2(8, 0.1, 0), 1, -1)
    except:
        raised += 1
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for k in range(N * N):
        lo = min(lo, plain.temp[k])
        hi = max(hi, plain.temp[k])
    print("  temperature range", tmin, tmax, "->", lo, hi)
    st.check(raised == 1 and lo >= tmin - 1e-6 and hi <= tmax + 1e-6, "epsilon < 0 raises; temperature stays in range")
    st.finish()
