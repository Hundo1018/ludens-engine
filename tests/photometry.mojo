# tier: unit
# Colour temperature, photometric units, exposure and IES files (app/photometry.mojo), against values worked out
# independently, no GPU:
#   kelvin_xy     against Planck's law integrated with the CIE 1931 observer (the multi-lobe fit of Wyman, Sloan and
#                 Shirley 2013), and against the published chromaticity of CIE illuminant A (2856 K)
#   kelvin_rgb    luminance 1 at every temperature; warm to cool in order
#   Exposure      EV100 of the sunny 16 rule; what 100 000 lx of sun shows on a white surface
#   spot cone     the closed-form solid angle against a numerical integral of the shader's smoothstep
#   IES           a hand-written file: candela between its angles, its flux in closed form, its symmetries; the sample
#                 files under assets/lights; the baked table the shader reads; the files it refuses
from std.math import sqrt, exp, cos, sin, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from app.photometry import (
    kelvin_xy, kelvin_rgb, xy_rgb, Exposure, relative_from_lux, relative_from_candela, spot_solid_angle,
    candela_from_lumens_point, candela_from_lumens_spot, nit_from_lumens_area, IesProfile, baked_lookup,
)


def _g(lam: Float64, mu: Float64, s1: Float64, s2: Float64) -> Float64:
    var s = s1 if lam < mu else s2
    var t = (lam - mu) / s
    return exp(-0.5 * t * t)


def planck_xy(kelvin: Float64) -> Tuple[Float64, Float64]:
    """The chromaticity of a black body: Planck's law times the CIE 1931 colour matching functions, 360 .. 830 nm."""
    var X = 0.0
    var Y = 0.0
    var Z = 0.0
    var lam = 360.0
    while lam <= 830.0:
        var m = lam * 1e-9
        var b = 1.0 / (m * m * m * m * m * (exp(1.4387769e-2 / (m * kelvin)) - 1.0))
        X += b * (1.056 * _g(lam, 599.8, 37.9, 31.0) + 0.362 * _g(lam, 442.0, 16.0, 26.7) - 0.065 * _g(lam, 501.1, 20.4, 26.2))
        Y += b * (0.821 * _g(lam, 568.8, 46.9, 40.5) + 0.286 * _g(lam, 530.9, 16.3, 31.1))
        Z += b * (1.217 * _g(lam, 437.0, 11.8, 36.0) + 0.681 * _g(lam, 459.0, 26.0, 13.8))
        lam += 1.0
    return (X / (X + Y + Z), Y / (X + Y + Z))


def lum(c: Vec3) -> Float64:
    return 0.2126729 * Float64(c[0]) + 0.7151522 * Float64(c[1]) + 0.0721750 * Float64(c[2])


comptime CONE_FILE = """IESNA:LM-63-2002
[TEST] three angles
TILT=NONE
1 -1 2.0 3 1 1 2 0 0 0
1.0 1.0 10
0 45 90
0
500 250 0
"""

comptime QUAD_FILE = """IESNA:LM-63-1995
TILT=NONE
1 1000 1 2 2 1 2 0 0 0
1 1 10
0 90
0 90
100 100
40 40
"""


def main() raises:
    var s = Suite("photometry")

    print("colour temperature: Kim et al. splines against Planck's law with the CIE 1931 observer")
    var worst = 0.0
    for k in [2000.0, 2700.0, 3200.0, 4000.0, 5000.0, 6500.0, 8000.0, 10000.0, 15000.0]:
        var a = kelvin_xy(k)
        var b = planck_xy(k)
        var e = max(abs(a[0] - b[0]), abs(a[1] - b[1]))
        worst = max(worst, e)
        var c = kelvin_rgb(k)
        print("  ", Int(k), "K: spline", a[0], a[1], " Planck", b[0], b[1], " rgb", c[0], c[1], c[2])
    print("   largest difference in x or y:", worst)
    var low = kelvin_xy(1800.0)
    var lowp = planck_xy(1800.0)
    print("   1800 K (below the range checked):", low[0], low[1], " Planck", lowp[0], lowp[1])
    s.check(worst < 0.003, "kelvin_xy: within 0.003 of Planck's law from 2000 to 15000 K")
    var ia = kelvin_xy(2856.0)
    print("   2856 K:", ia[0], ia[1], " CIE illuminant A: 0.44757 0.40745")
    s.check(abs(ia[0] - 0.44757) < 0.0015 and abs(ia[1] - 0.40745) < 0.0015, "kelvin_xy: 2856 K is CIE illuminant A within 0.0015")
    var d65 = xy_rgb(0.31271, 0.32902)
    s.check(abs(Float64(d65[0]) - 1.0) < 2e-3 and abs(Float64(d65[1]) - 1.0) < 2e-3 and abs(Float64(d65[2]) - 1.0) < 2e-3, "xy_rgb: the D65 white point is rgb (1, 1, 1)")
    var lworst = 0.0
    var t = 1700.0
    var prev = kelvin_rgb(1700.0)
    var ordered = True
    while t <= 24000.0:
        var c = kelvin_rgb(t)
        lworst = max(lworst, abs(lum(c) - 1.0))
        if Float64(c[2]) / Float64(c[0]) < Float64(prev[2]) / Float64(prev[0]) - 1e-9:
            ordered = False
        prev = c
        t += 100.0
    s.check(lworst < 1e-6, "kelvin_rgb: luminance 1 from 1700 to 24000 K")
    s.check(ordered, "kelvin_rgb: blue over red rises with the temperature")
    var w = kelvin_rgb(6504.0)
    print("   6504 K:", w[0], w[1], w[2])
    s.check(abs(Float64(w[0]) - 1.0) < 0.05 and abs(Float64(w[1]) - 1.0) < 0.05 and abs(Float64(w[2]) - 1.0) < 0.05, "kelvin_rgb: 6504 K is white within 5 % per channel")
    var raised = False
    try:
        _ = kelvin_rgb(1000.0)
    except:
        raised = True
    s.check(raised, "kelvin_rgb: 1000 K is outside the splines and raises")

    print("exposure")
    var e = Exposure()
    print("   f/16, 1/100 s, ISO 100: EV100", e.ev100(), "; 100 000 lx of sun on white shows", relative_from_lux(100000.0, e))
    s.almost(e.ev100(), 14.643856, "Exposure: the sunny 16 rule is EV100 14.64", tol=1e-5)
    s.almost(relative_from_lux(100000.0, e), 100000.0 / pi / (1.2 * 25600.0), "Exposure: E / pi / (1.2 * 2^EV100)", tol=1e-9)
    s.almost(Exposure.from_ev100(9.0).ev100(), 9.0, "Exposure.from_ev100", tol=1e-9)
    s.almost(Exposure(2.8, 1.0 / 60.0, 800.0).ev100(), 6.0 - 0.115, "Exposure: f/2.8 1/60 s ISO 800 is EV100 5.9", tol=0.01)
    s.almost(relative_from_candela(100.0, e) * pi, 100.0 * e.scale(), "relative_from_candela: cd / pi * scale", tol=1e-12)

    print("spot cone: closed form against the shader's smoothstep integrated")
    for pair in [(0.2, 0.3), (0.0, 0.8), (0.5, 0.51), (1.0, 1.4)]:
        var inner = pair[0]
        var outer = pair[1]
        var num = 0.0
        var n = 200000
        for i in range(n):
            var th = (Float64(i) + 0.5) / Float64(n) * pi
            var c = cos(th)
            var x = min(max((c - cos(outer)) / (cos(inner) - cos(outer)), 0.0), 1.0)
            num += x * x * (3.0 - 2.0 * x) * 2.0 * pi * sin(th) * pi / Float64(n)
        print("   inner", inner, "outer", outer, ": closed form", spot_solid_angle(inner, outer), "integral", num)
        s.check(abs(spot_solid_angle(inner, outer) - num) < 1e-5 * max(num, 1e-3), "spot_solid_angle " + String(inner) + " .. " + String(outer))
    s.almost(candela_from_lumens_point(4.0 * pi * 100.0), 100.0, "a 1257 lm bare point light is 100 cd", tol=1e-9)
    s.almost(candela_from_lumens_spot(1000.0, 0.0, 0.8) * spot_solid_angle(0.0, 0.8), 1000.0, "a spot's candela times its cone is its flux", tol=1e-9)
    s.almost(nit_from_lumens_area(pi * 2.0 * 100.0, 2.0), 100.0, "an area light: lm / (pi A)", tol=1e-9)

    print("IES: a hand-written file (vertical 0, 45, 90 at 500, 250, 0 cd, multiplier 2)")
    var p = IesProfile.parse(CONE_FILE)
    s.almost(p.peak(), 1000.0, "ies: the multiplier applies", tol=1e-9)
    s.almost(p.candela(pi / 8.0, 0.0), 750.0, "ies: linear between angles (22.5 degrees)", tol=1e-9)
    s.almost(p.candela(pi / 8.0, 2.0), 750.0, "ies: one horizontal angle is the same all round", tol=1e-9)
    s.almost(p.candela(2.0, 0.0), 0.0, "ies: nothing past its last vertical angle", tol=1e-12)
    # I = 1000 (1 - 2 theta / pi) to 90 degrees: flux 2 pi * 1000 * (1 - 2 / pi * int theta sin theta) = 2000 pi - 4000
    print("   flux: integrated", p.lumens(), "closed form", 2000.0 * pi - 4000.0)
    s.check(abs(p.lumens() / (2000.0 * pi - 4000.0) - 1.0) < 1e-3, "ies: the flux integrated over the sphere is 2000 pi - 4000 lm within 0.1 %")
    var q = IesProfile.parse(QUAD_FILE)
    s.almost(q.candela(0.5, pi), q.candela(0.5, 0.0), "ies, quadrants: 180 degrees is 0", tol=1e-9)
    s.almost(q.candela(0.5, 1.5 * pi), q.candela(0.5, 0.5 * pi), "ies, quadrants: 270 degrees is 90", tol=1e-9)
    s.almost(q.candela(pi / 2.0, 0.75 * pi), 70.0, "ies, quadrants: 135 degrees is 45, halfway between 100 and 40", tol=1e-9)
    s.almost(q.candela(pi / 2.0, 0.5 * pi), 40.0, "ies: horizontal 90 at vertical 90", tol=1e-9)

    print("IES: the sample files (assets/lights, scripts/assets/gen_light_profiles.py)")
    var dl = IesProfile.parse(open("assets/lights/downlight_cos8.ies", "r").read())
    var half = 0.0
    var a = 0.0
    while a < 1.0:  # the angle where cos^8 is half the peak: acos(0.5^(1/8)) = 23.51 degrees
        if dl.candela(a, 0.0) >= 0.5 * dl.peak():
            half = a
        a += 0.0005
    print("   downlight: peak", dl.peak(), "cd, half the peak at", half * 180.0 / pi, "degrees (cos^8: 23.51), flux", dl.lumens(), "lm")
    s.check(abs(half * 180.0 / pi - 23.51) < 0.1, "ies, downlight: half the peak at 23.51 degrees within 0.1")
    var st = IesProfile.parse(open("assets/lights/street_type2.ies", "r").read())
    var toward = st.candela(55.0 * pi / 180.0, 0.5 * pi)
    var away = st.candela(55.0 * pi / 180.0, 1.5 * pi)
    print("   street light: 55 degrees toward the street", toward, "cd; the same angle away from it", away, "cd")
    s.check(toward > 10.0 * away, "ies, street light: ten times as bright toward the street as away from it")
    s.almost(st.candela(0.7, 0.3 * pi), st.candela(0.7, 0.7 * pi), "ies, mirrored about 90-270: phi and 180 - phi agree", tol=1e-9)

    print("IES: the baked table against the profile (what the shader reads)")
    for which in range(2):
        var prof = dl.copy() if which == 0 else st.copy()
        var tab = prof.bake()
        var err = 0.0
        for i in range(97):
            for j in range(61):
                var th = Float64(i) / 96.0 * pi
                var ph = Float64(j) / 60.0 * 2.0 * pi
                err = max(err, abs(baked_lookup(tab, th, ph) - prof.candela(th, ph) / prof.peak()))
        print("   ", "downlight" if which == 0 else "street light", ": largest difference over 97 x 61 angles, as a fraction of the peak:", err)
        s.check(err < (0.01 if which == 0 else 0.06), "ies: the baked table follows the profile (" + ("downlight" if which == 0 else "street light") + ")")

    var refused = 0
    for bad in [
        String("IESNA:LM-63-2002\nTILT=INCLUDE\n"),
        String("IESNA:LM-63-2002\nTILT=NONE\n1 -1 1 2 1 2 2 0 0 0\n1 1 1\n0 90\n0\n1 1\n"),
        String("IESNA:LM-63-2002\nTILT=NONE\n1 -1 1 3 1 1 2 0 0 0\n1 1 1\n0 90\n"),
        String("no tilt line at all"),
    ]:
        try:
            _ = IesProfile.parse(bad)
        except:
            refused += 1
    s.eqi(refused, 4, "ies: TILT=INCLUDE, type B, a short file and a file without TILT raise")
    s.finish()
