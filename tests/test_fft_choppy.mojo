# tier: integration
"""Choppy FFT ocean and its normals (ROADMAP 17.60, `FftOcean.choppy`,
`displaced`, `normal`).

  1. Ordinary (seam parity): one mode with choppiness 0.6 is the Gerstner
     wave of steepness Q = 0.6 (same wavevector, amplitude, phase): heights
     at 200 random points and times within 1e-4 m (both invert their
     horizontal map with 4 iterations).
  2. Integration: choppy crests are narrow: along one wavelength, the
     fraction of the surface above the level is 0.5 without choppiness and
     at 0.6 that of a trochoid, 1/2 - Q k A / pi = 0.471 (within 0.005;
     400 samples); on a Phillips sea the analytic normal matches
     finite differences of the height within 2e-3 and is unit length.
  3. Extreme: a sea with no modes has normal (0, 1, 0) and its choppy
     height is the level.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.water import FftOcean, GerstnerWater
from scheduler.rng import SplitMix64


def _above(o: FftOcean, wavelength: Real) -> Real:
    var up = 0
    for k in range(400):
        if o.height(Real(k) / 400 * wavelength, 3, 1.3) > o.level:
            up += 1
    return Real(up) / 400


def main() raises:
    var s = Suite("fft_choppy")
    var rng = SplitMix64.seeded(11)
    var size = Real(100)
    var o = FftOcean(32, size, 0)
    o.set_mode(4, 0, 0.6, 0.3)
    o.choppy = 0.6
    var g = GerstnerWater(0)
    g.add(1, 0, 0.6, size / 4, 0.6, 0.3)
    var worst = Real(0)
    for _ in range(200):
        var x = Real(rng.next_f32()) * 200 - 50
        var z = Real(rng.next_f32()) * 200 - 50
        var t = Real(rng.next_f32()) * 20
        worst = max(worst, abs(o.height(x, z, t) - g.height(x, z, t)))
    print("  one choppy mode vs Gerstner Q = 0.6: worst height difference", worst)
    s.check(worst < 1e-4, "a choppy mode is the Gerstner wave of the same steepness")

    var flat_mode = FftOcean(32, size, 0)
    flat_mode.set_mode(4, 0, 0.6, 0.3)
    var f0 = _above(flat_mode, size / 4)
    var f6 = _above(o, size / 4)
    var want = 0.5 - 0.6 * (2 * Real(pi) / (size / 4)) * 0.6 / Real(pi)
    print("  fraction of a wavelength above the level: choppiness 0", f0, " 0.6", f6, " (trochoid 1/2 - Q k A / pi =", want, ")")
    s.check(abs(f0 - 0.5) < 0.01 and abs(f6 - want) < 0.005, "choppy crests narrow as a trochoid's")

    var sea = FftOcean(32, 200, 0)
    sea.phillips(5, 3e-6, 10, 3)
    var nerr = Real(0)
    var nlen = Real(0)
    for _ in range(50):
        var x = Real(rng.next_f32()) * 200
        var z = Real(rng.next_f32()) * 200
        var h = Real(1e-2)
        var gx = (sea.direct(x + h, z, 2) - sea.direct(x - h, z, 2)) / (2 * h)
        var gz = (sea.direct(x, z + h, 2) - sea.direct(x, z - h, 2)) / (2 * h)
        var l = (gx * gx + 1 + gz * gz) ** 0.5
        var fd = Vec3(-gx / l, 1 / l, -gz / l, 0)
        var nn = sea.normal(x, z, 2)
        nerr = max(nerr, length(nn - fd))
        nlen = max(nlen, abs(length(nn) - 1))
    print("  Phillips sea normals vs finite differences: worst", nerr, " |n| - 1", nlen)
    s.check(nerr < 2e-3 and nlen < 1e-5, "analytic normals match the height's slopes")

    var calm = FftOcean(16, 50, 0.7)
    calm.choppy = 0.5
    s.check(calm.normal(3, 4, 1) == Vec3(0, 1, 0, 0) and calm.height(3, 4, 1) == 0.7, "no modes: normal up, choppy height the level")
    s.finish()
