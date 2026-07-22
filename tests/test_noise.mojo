from std.math import sqrt, floor
from harness.runner import Suite
from geometry.vec import Real
from procedural.noise import (
    value3,
    perlin3,
    perlin2,
    worley3,
    fbm3,
    fbm2,
)


def main() raises:
    var s = Suite("noise")

    # 1. Determinism: pure function of (coords, seed) -> two calls agree
    #    bit-for-bit, and different seeds decorrelate.
    var a = Float64(perlin3(1.5, 2.25, -0.75, 7))
    var b = Float64(perlin3(1.5, 2.25, -0.75, 7))
    var c = Float64(perlin3(1.5, 2.25, -0.75, 8))
    s.check(a == b, "perlin3 is deterministic (same seed -> identical)")
    s.check(a != c, "different seed decorrelates")

    # 2. Range: value/Perlin/fBm stay within [-1, 1] over a dense sweep;
    #    Worley is a non-negative distance.
    var lo = Float64(1e30)
    var hi = Float64(-1e30)
    var wlo = Float64(1e30)
    var vlo = Float64(1e30)
    var vhi = Float64(-1e30)
    var flo = Float64(1e30)
    var fhi = Float64(-1e30)
    for i in range(60):
        for j in range(60):
            var x = Real(i) * 0.17 - 5
            var y = Real(j) * 0.17 - 5
            var p = Float64(perlin3(x, y, x * 0.5, 3))
            if p < lo:
                lo = p
            if p > hi:
                hi = p
            var w = Float64(worley3(x, y, x * 0.3, 3))
            if w < wlo:
                wlo = w
            var v = Float64(value3(x, y, x * 0.5, 3))
            if v < vlo:
                vlo = v
            if v > vhi:
                vhi = v
            var f = Float64(fbm3(x, y, x * 0.5, 3))
            if f < flo:
                flo = f
            if f > fhi:
                fhi = f
    print("  perlin3 range:", lo, hi, " value3:", vlo, vhi, " fbm3:", flo, fhi)
    print("  worley3 min distance:", wlo)
    s.check(lo >= -1.0 and hi <= 1.0, "perlin3 stays in [-1, 1]")
    s.check(vlo >= -1.0 and vhi <= 1.0, "value3 stays in [-1, 1]")
    s.check(flo >= -1.0 and fhi <= 1.0, "fbm3 stays in [-1, 1]")
    s.check(wlo >= 0.0, "worley3 is a non-negative distance")
    # it actually varies (not a constant) — real signal
    s.check(hi - lo > 0.5, "perlin3 actually varies across the field")

    # 3. Continuity: no lattice-boundary jumps. Step across an integer
    #    boundary in tiny increments; the max first difference must stay
    #    small (a discrete hash without the fade would jump ~O(1) here).
    var maxjump = Float64(0)
    var prev = Float64(perlin3(0.0, 0.3, 0.7, 5))
    for k in range(1, 400):
        var x = Real(k) * 0.01  # sweeps across x = 1, 2, 3
        var cur = Float64(perlin3(x, 0.3, 0.7, 5))
        var d = abs(cur - prev)
        if d > maxjump:
            maxjump = d
        prev = cur
    print("  perlin3 max step (dx=0.01):", maxjump)
    s.check(maxjump < 0.1, "perlin3 is continuous across cell boundaries")

    # 4. Gradient continuity (quintic fade): the SECOND difference is also
    #    bounded — the field is smooth, not just continuous.
    var maxcurv = Float64(0)
    var p0 = Float64(perlin3(0.0, 0.11, 0.0, 9))
    var p1 = Float64(perlin3(0.01, 0.11, 0.0, 9))
    for k in range(2, 400):
        var x = Real(k) * 0.01
        var p2 = Float64(perlin3(x, 0.11, 0.0, 9))
        var curv = abs(p2 - 2 * p1 + p0)
        if curv > maxcurv:
            maxcurv = curv
        p0 = p1
        p1 = p2
    print("  perlin3 max curvature:", maxcurv)
    s.check(maxcurv < 0.02, "perlin3 has continuous gradients (quintic fade)")

    # 5. 2D primitives work and stay in range (terrain path).
    var t2 = Float64(perlin2(3.3, -1.2, 4))
    var f2lo = Float64(1e30)
    var f2hi = Float64(-1e30)
    for i in range(80):
        var v = Float64(fbm2(Real(i) * 0.3, Real(i) * 0.11, 4))
        if v < f2lo:
            f2lo = v
        if v > f2hi:
            f2hi = v
    print("  perlin2 sample:", t2, " fbm2 range:", f2lo, f2hi)
    s.check(t2 >= -1.0 and t2 <= 1.0, "perlin2 in [-1, 1]")
    s.check(f2lo >= -1.0 and f2hi <= 1.0, "fbm2 in [-1, 1]")

    s.finish()
