"""DCGA spike: one inner product answers plane, sphere AND torus.

The torus is the point of the exercise. It is a quartic, so it is not a CGA
round at all — "torus intersection via CGA" is a category error rather than a
missing feature — and the doubled algebra's job is to make it linear again.
Check 1 therefore verifies incidence on a PARAMETRISED torus surface, where
every sample is exactly on the quartic by construction, and checks the sign
flips correctly inside the tube and outside it.

Checks 2 and 3 are the uniformity claim: the identical `dcga_incidence` call,
with only the coefficient vector changed, must agree with the hand-written
plane and sphere tests. If the same expression did not cover all three there
would be no claim to make.
"""

from std.math import sqrt, cos, sin
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, dot, normalize, length
from geometry.dcga import (
    dcga_point, dcga_incidence, dcga_plane, dcga_sphere, dcga_torus,
    torus_analytic,
)


def main() raises:
    var s = Suite("dcga")
    var rng = SplitMix64.seeded(61)

    comptime R: Real = 2.0
    comptime r: Real = 0.6
    var tor = dcga_torus(R, r)

    # ---- 1. points ON the torus: incidence must vanish ----
    var worst = Real(0)
    for a in range(24):
        for b in range(24):
            var u = Real(a) * 0.2618
            var v = Real(b) * 0.2618
            var cu = Real(cos(Float64(u)))
            var su = Real(sin(Float64(u)))
            var cv = Real(cos(Float64(v)))
            var sv = Real(sin(Float64(v)))
            var p = Vec3((R + r * cv) * cu, (R + r * cv) * su, r * sv)
            var e = abs(dcga_incidence(dcga_point(p), tor))
            if e > worst:
                worst = e
    print("  worst |incidence| on the torus surface:", worst)
    s.check(worst < 1e-2, "DCGA incidence vanishes on the torus")

    # ---- 2. sign is consistent with inside / outside the tube ----
    var sign_ok = True
    for _ in range(300):
        var p = Vec3(
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 4 - 2,
        )
        var d = torus_analytic(R, r, p)  # <0 inside the tube, >0 outside
        var g = dcga_incidence(dcga_point(p), tor)
        if abs(d) < 1e-3:
            continue  # skip the surface itself, where the sign is undefined
        if (d < 0) != (g < 0):
            sign_ok = False
    s.check(sign_ok, "DCGA and the analytic torus agree on inside/outside")

    # ---- 3. THE SAME call answers a sphere ----
    var c = Vec3(0.4, -0.3, 0.9)
    var rad = Real(1.7)
    var sph = dcga_sphere(c, rad)
    var sph_ok = True
    var sph_worst = Real(0)
    for _ in range(300):
        var p = Vec3(
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
        )
        var want = dot(p - c, p - c) - rad * rad
        var got = dcga_incidence(dcga_point(p), sph)
        var e = abs(want - got)
        if e > sph_worst:
            sph_worst = e
        if e > 1e-2:
            sph_ok = False
    print("  worst sphere discrepancy:", sph_worst)
    s.check(sph_ok, "the same inner product reproduces the sphere test")

    # ---- 4. ... and a plane ----
    var n = normalize(Vec3(0.3, 0.8, -0.5))
    var dd = Real(1.25)
    var pl = dcga_plane(n, dd)
    var pl_ok = True
    for _ in range(300):
        var p = Vec3(
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
        )
        if abs(dot(p, n) - dd - dcga_incidence(dcga_point(p), pl)) > 1e-3:
            pl_ok = False
    s.check(pl_ok, "the same inner product reproduces the plane test")

    # ---- 5. a degenerate torus (minor -> 0) collapses onto its core circle ----
    var thin = dcga_torus(R, 0.02)
    var on_core = Vec3(R, 0, 0)
    var far = Vec3(0, 0, 0)
    s.check(
        abs(dcga_incidence(dcga_point(on_core), thin)) < 1e-2,
        "a thin torus still contains its core circle",
    )
    s.check(
        dcga_incidence(dcga_point(far), thin) > 0,
        "the torus centre is outside a thin tube",
    )

    s.finish()
