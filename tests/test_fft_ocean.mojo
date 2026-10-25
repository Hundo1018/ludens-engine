# tier: integration
"""FFT ocean spectrum (ROADMAP 17.60, `numerics.fft`, `physics.water.FftOcean`).

  1. Ordinary: the radix-2 FFT of 64 seeded values matches the direct DFT
     (1e-4 of the largest coefficient) and its inverse gives the input back
     (1e-5). One `FftOcean` mode is the Gerstner wave with Q = 0 of the same
     wavevector, amplitude and phase (seam parity: 200 random points and
     times, 1e-4 m), and its velocity matches Gerstner's within 1e-3 m/s
     (Gerstner differentiates numerically).
  2. Integration: a 64 x 64 Phillips sea (wind 10 m/s, 200 m patch,
     amplitude 3e-6: significant height printed, about 2 m as for a fully
     developed 10 m/s sea): the
     inverse-FFT grid at t = 3.7 s matches the direct mode sum at grid
     points (1e-3 of the wave height); the same seed gives the same sea bit
     for bit and another seed a different one; between grid points the
     bilinear grid is within 10 % of the wave height of the direct sum;
     a box floated with `float_body` on it stays finite and bobs.
  3. Extreme: n not a power of two, size <= 0 and a mode outside the grid
     raise; with no modes the surface is the level exactly; the surface
     repeats with the patch size.
"""

from std.math import pi, sin, cos, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from numerics.fft import fft, fft2
from physics.water import FftOcean, GerstnerWater, float_body
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from scheduler.rng import SplitMix64


def main() raises:
    var s = Suite("fft_ocean")

    # ---- FFT ------------------------------------------------------------------------------------
    var rng = SplitMix64.seeded(7)
    var n = 64
    var re = List[Real]()
    var im = List[Real]()
    for _ in range(n):
        re.append(Real(rng.next_f32()) - 0.5)
        im.append(Real(rng.next_f32()) - 0.5)
    var r0 = re.copy()
    var i0 = im.copy()
    fft(re, im)
    var worst = Real(0)
    var peak = Real(0)
    for k in range(n):
        var dr = Real(0)
        var di = Real(0)
        for j in range(n):
            var a = -2 * Real(pi) * Real(k * j) / Real(n)
            dr += r0[j] * cos(a) - i0[j] * sin(a)
            di += r0[j] * sin(a) + i0[j] * cos(a)
        worst = max(worst, abs(dr - re[k]) + abs(di - im[k]))
        peak = max(peak, abs(dr) + abs(di))
    fft(re, im, True)
    var back = Real(0)
    for j in range(n):
        back = max(back, abs(re[j] - r0[j]) + abs(im[j] - i0[j]))
    print("  FFT 64: worst |FFT - DFT|", worst, "of", peak, ";  round trip", back)
    s.check(worst < 1e-4 * peak and back < 1e-5, "FFT = direct DFT; inverse returns the input")

    # ---- one mode = Gerstner Q = 0 --------------------------------------------------------------
    var size = Real(100)
    var o = FftOcean(32, size, 0.5)
    o.set_mode(3, -2, 0.4, 0.7)
    var g = GerstnerWater(0.5)
    var kx = 2 * Real(pi) * 3 / size
    var kz = 2 * Real(pi) * -2 / size
    var kl = (kx * kx + kz * kz) ** 0.5
    g.add(kx, kz, 0.4, 2 * Real(pi) / kl, 0, 0.7)
    var dh = Real(0)
    var dv = Real(0)
    for _ in range(200):
        var x = Real(rng.next_f32()) * 300 - 100
        var z = Real(rng.next_f32()) * 300 - 100
        var t = Real(rng.next_f32()) * 20
        dh = max(dh, abs(o.height(x, z, t) - g.height(x, z, t)))
        dv = max(dv, abs(o.velocity(x, z, t)[1] - g.velocity(x, z, t)[1]))
    print("  one mode vs Gerstner Q = 0, 200 samples: worst height diff", dh, " vertical velocity diff", dv)
    s.check(dh < 1e-4 and dv < 1e-3, "a single FFT mode is the Gerstner wave (seam parity)")

    # ---- Phillips sea ---------------------------------------------------------------------------
    var sea = FftOcean(64, 200, 0)
    sea.phillips(42, 3e-6, 10, 3)
    sea.update(3.7)
    var hmax = Real(0)
    var gerr = Real(0)
    var cell = Real(200) / 64
    for j in range(0, 64, 5):
        for i in range(0, 64, 5):
            var d = sea.direct(Real(i) * cell, Real(j) * cell, 3.7)
            hmax = max(hmax, abs(d))
            gerr = max(gerr, abs(sea.height(Real(i) * cell, Real(j) * cell, 3.7) - d))
    var berr = Real(0)
    for _ in range(100):
        var x = Real(rng.next_f32()) * 200
        var z = Real(rng.next_f32()) * 200
        berr = max(berr, abs(sea.height(x, z, 3.7) - sea.direct(x, z, 3.7)))
    var same = FftOcean(64, 200, 0)
    same.phillips(42, 3e-6, 10, 3)
    var other = FftOcean(64, 200, 0)
    other.phillips(43, 3e-6, 10, 3)
    var bit = True
    var diff = False
    for i in range(64 * 64):
        bit = bit and same.h0_re[i] == sea.h0_re[i] and same.h0_im[i] == sea.h0_im[i]
        diff = diff or other.h0_re[i] != sea.h0_re[i]
    var var_ = Real(0)
    for i in range(64 * 64):
        var_ += sea.grid[i] * sea.grid[i]
    var hs = 4 * (var_ / Real(64 * 64)) ** 0.5
    print("  Phillips 64^2, 200 m, wind 10 m/s, A 3e-6: significant height 4 sigma", hs, " max |eta|", hmax, " grid vs sum at grid points", gerr, " bilinear between", berr)
    s.check(gerr < 1e-3 * hmax and berr < 0.1 * hmax, "FFT grid = mode sum at grid points; bilinear in between within 10 %")
    s.check(bit and diff, "same seed, same sea; another seed, another")

    var sc = ContactScene6[QuatBody6]()
    var id = sc.add(QuatBody6.at_rest(Vec3(100, 0, 100, 0), Inertia3.box(2000, 1, 0.5, 1)), Vec3(1, 0.5, 1, 0), False)
    var cfg = SolverConfig()
    var lo = Real(1e30)
    var hi = Real(-1e30)
    var fin = True
    for k in range(600):
        var t = Real(k) / 60
        sea.update(t)
        _ = float_body(sc, id, Vec3(1, 0.5, 1, 0), sea, t, 1000, Vec3(0, -9.8, 0, 0), 0.5, 4)
        sc.step(1.0 / 60, Vec3(0, -9.8, 0, 0), cfg)
        var y = sc.pose(id).pos[1]
        fin = fin and isfinite(y)
        if k > 300:
            lo = min(lo, y)
            hi = max(hi, y)
    print("  2 x 1 x 2 box of density 1000 / 2 on the sea, 5 to 10 s: heave", hi - lo)
    s.check(fin and hi - lo > 0.01, "a box floats on the sea and bobs")

    var raised = 0
    try:
        _ = FftOcean(48, 100, 0)
    except:
        raised += 1
    try:
        _ = FftOcean(32, 0, 0)
    except:
        raised += 1
    try:
        o.set_mode(16, 0, 1, 0)
    except:
        raised += 1
    s.check(raised == 3, "bad size, patch or mode raises")
    var calm = FftOcean(16, 50, 1.25)
    calm.update(2)
    s.check(calm.height(3.3, 7.1, 2) == 1.25 and calm.height(3.3, 7.1, 9) == 1.25, "no modes: the level exactly")
    s.check(abs(sea.height(13.0, 41.0, 3.7) - sea.height(213.0, -159.0, 3.7)) < 1e-5, "the surface repeats with the patch")
    s.finish()
