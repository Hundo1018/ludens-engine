# tier: integration
"""3-D MAC grid fluid and smoke (ROADMAP 17.60, `physics.mac_fluid3`).

  1. Ordinary: a pseudo-random velocity field on 16^3 after one
     projection has max |div u| at the CG tolerance's level (the ratio to
     before is printed); a shear wave u = A sin(2 pi y / L) decays by
     viscosity at the discrete Laplacian's exact rate (advection leaves a
     field that does not vary along its own direction unchanged).
  2. Integration (parity): a z-independent field with w = 0 steps like
     `MacFluid2` -- the 2-D and 3-D u fields after 20 steps agree to the
     CG tolerance.
  3. Smoke: a hot cube at the bottom of a 16^3 box rises (temperature
     centre printed against time) and the box's mean vertical velocity
     stays under 1 % of its largest (buoyancy is taken against the mean
     temperature, so it adds no net momentum; what is left, 1.4e-3, is
     semi-Lagrangian advection, which does not conserve momentum).
  Also: before 17.60's warm-start guard the 2-D field of (2) grew from
  |u| 0.05 to 667 in 15 steps (`mac_fluid.warm_start_or_zero`).
  4. Extreme: n < 4, nu dt / dx^2 > 1/6 and dt = 0 raise.
"""

from std.math import sin, cos, exp, pi
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2
from physics.mac_fluid3 import MacFluid3, Smoke3


def _hash01(i: Int) -> Real:
    var h = UInt64(i) * UInt64(0x9E3779B97F4A7C15)
    h ^= h >> 29
    h *= UInt64(0xBF58476D1CE4E5B9)
    h ^= h >> 32
    return Real(Float64(h % 1000003) / 1000003.0) - 0.5


def _maxabs(f: List[Real]) -> Real:
    var m = Real(0)
    for x in f:
        m = max(m, abs(x))
    return m


def main() raises:
    var s = Suite("mac_fluid3")
    var n = 16
    var L = Real(1)
    var dx = L / Real(n)

    # 1a. projection
    var f = MacFluid3(n, dx, 0)
    for c in range(f.cells()):
        f.u[c] = _hash01(3 * c)
        f.v[c] = _hash01(3 * c + 1)
        f.w[c] = _hash01(3 * c + 2)
    var before = _maxabs(f.divergence())
    var r = f.project(0.01)
    var after = _maxabs(f.divergence())
    print("  projection 16^3: max |div| before", before, " after", after, " CG iterations", r.iters)
    s.check(r.converged and after < 1e-4 * before, "projection: max |div| down by 1e4 or more")

    # 1b. viscous decay of a shear wave
    var nu = Real(2e-3)
    var dt = Real(0.01)
    var a = Real(0.01)
    var sh = MacFluid3(n, dx, nu)
    for k in range(n):
        for j in range(n):
            for i in range(n):
                sh.u[(k * n + j) * n + i] = a * sin(2 * Real(pi) * (Real(j) + 0.5) * dx / L)
    var steps = 50
    for _ in range(steps):
        sh.step(dt)
    var kw = 2 * Real(pi) / L
    var disc = 1 - nu * dt / (dx * dx) * (2 - 2 * cos(kw * dx))  # per-step factor of the explicit 7-point step
    var want = Float64(1)
    for _ in range(steps):
        want *= Float64(disc)
    var got = Float64(sh.u[(0 * n + 4) * n + 0]) / Float64(a * sin(2 * Real(pi) * 4.5 * dx / L))
    var cont = exp(-Float64(nu) * Float64(kw * kw) * Float64(dt) * Float64(steps))
    print("  shear decay over", steps, "steps: amplitude ratio", got, " discrete", want, " continuous", cont)
    s.check(abs(got / want - 1) < 1e-4, "shear wave decays at the discrete viscous rate (1e-4)")
    s.check(abs(got / cont - 1) < 0.02, "and within 2 % of the continuous rate")

    # 2. parity with MacFluid2 on a z-independent field
    var f2 = MacFluid2(n, dx, nu)
    var f3 = MacFluid3(n, dx, nu)
    for j in range(n):
        for i in range(n):
            var uu = Real(0.05) * sin(2 * Real(pi) * (Real(j) + 0.5) * dx) + Real(0.02) * cos(2 * Real(pi) * Real(i) * dx)
            var vv = Real(0.05) * sin(2 * Real(pi) * (Real(i) + 0.5) * dx)
            f2.u[j * n + i] = uu
            f2.v[j * n + i] = vv
            for k in range(n):
                f3.u[(k * n + j) * n + i] = uu
                f3.v[(k * n + j) * n + i] = vv
    for _ in range(20):
        f2.step(dt)
        f3.step(dt)
    var worst = Real(0)
    var scale = Real(0)
    for k in [0, 7]:
        for j in range(n):
            for i in range(n):
                worst = max(worst, abs(f3.u[(k * n + j) * n + i] - f2.u[j * n + i]))
                worst = max(worst, abs(f3.v[(k * n + j) * n + i] - f2.v[j * n + i]))
                scale = max(scale, abs(f2.u[j * n + i]))
    print("  2-D parity after 20 steps: max |u3 - u2|", worst, " of", scale, " max |w|", _maxabs(f3.w))
    s.check(worst < 1e-4 * scale and _maxabs(f3.w) < 1e-6, "z-independent field: same as MacFluid2 (1e-4 relative), w stays ~0")

    # 3. smoke
    var sm = Smoke3(MacFluid3(n, dx, 1e-4), 2.0)
    for k in range(6, 10):
        for j in range(1, 4):
            for i in range(6, 10):
                sm.temp[(k * n + j) * n + i] = 1
    var y0 = sm.heat_centre_y()
    var line = String("  smoke heat centre y:") + " " + String(y0)
    for t in range(40):
        sm.step(0.02)
        if t % 10 == 9:
            line += " " + String(sm.heat_centre_y())
    var vsum = Float64(0)
    var vmax = Real(0)
    for c in range(sm.fluid.cells()):
        vsum += Float64(sm.fluid.v[c])
        vmax = max(vmax, abs(sm.fluid.v[c]))
    var vmean = vsum / Float64(sm.fluid.cells())
    print(line)
    print("  mean v", vmean, " max |v|", vmax)
    s.check(sm.heat_centre_y() > y0 + 2 * dx, "the hot cube rises more than 2 cells in 0.8 s")
    s.check(abs(vmean) < 1e-2 * Float64(vmax), "box mean vertical velocity ~0 (< 1 % of max; advection drift)")

    # 4. bad input
    var raised = 0
    try:
        _ = MacFluid3(3, dx, 0)
    except:
        raised += 1
    try:
        var hot = MacFluid3(n, dx, 1.0)
        hot.step(dt)
    except:
        raised += 1
    try:
        var z = MacFluid3(n, dx, 0)
        z.step(0)
    except:
        raised += 1
    s.check(raised == 3, "n < 4, viscosity above the explicit limit, dt = 0 raise")
    s.finish()
