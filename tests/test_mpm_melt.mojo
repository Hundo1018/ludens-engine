# tier: component
"""Melting MPM material (ROADMAP 17.61, `physics.mpm_melt.MpmMelt`).

Wax-like block: 8 x 6 x 8 particles 2.5 cm apart, 900 kg/m^3, E 2e4 Pa,
c 2000 J/(kg K), L 2e5 J/kg, melting at 330 K, alpha 1e-3 m^2/s (raised
from wax's 1e-7 so a test-length run melts more than one layer). MPM grid
32^3 of 5 cm, dt 5e-4 s.

  1. Unit: `melt_state` on the plateau: T stays at Tm while phi goes 0 -> 1.
  2. Ordinary: a solid block (300 K) keeps its height; the same block
     liquid (340 K) slumps and spreads; heated from a 600 K floor
     (h 1e5) the solid block's bottom melts and the block loses height,
     while the unheated control does not.
  3. Integration: enthalpy budget -- sum m H changes by the floor's heat to
     1e-5 (conduction moves enthalpy without creating it, through the
     latent plateau too).
  4. Extreme: no particles / c <= 0 raise.
  5. Mushy shear (1 - phi). The shear factor scales the deviatoric stress;
     the isotropic part of F - R stays. Three blocks, one step, no gravity.
     Pure shear F = I + 0.05 E12 (J = 1): the stress is 2 mu s dev + iso,
     with s the shear factor. Predictions, written after the first run and before this one:
       P1  v(mushy, s 0.5) - 0.5 v(solid, s 1) - 0.5 v(liquid, s 0) = 0 to
           1e-6 relative, since v = s dev + iso and iso = v(liquid);
       P2  under isotropic compression F = 0.99 I (dev = 0) the liquid moves
           exactly as the solid does, 1e-6 relative: a liquid keeps its
           compression resistance;
       P3  mushy phi stays 0.5 (uniform temperature, no enthalpy flow).
     Scene: section 5 uses blocks at y 0.5. At the floor (y 0.16) the bottom
     layer reaches the solver's sticky-wall band (grid j < 3), whose clamp
     is non-linear; the first run's P1 residual (4.5e-4, unchanged in f64)
     came from that band, not from the stress law (lifted: 1.4e-7).
     Revision: an earlier version scaled the whole 2 mu (F - R) term, which
     also removed the isotropic part, and its P2 (zero liquid motion) passed
     for that reason. The corrected formula and these predictions were
     written after that first run and before the run that passes.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.mpm import MpmSolver
from physics.mpm_melt import MpmMelt, melt_state
from geometry.mat import Mat3
from geometry.vec import length

comptime DX: Real = 0.05
comptime N = 32
comptime SP: Real = 0.025
comptime DT: Real = 5e-4
comptime G = Vec3(0, -9.8, 0, 0)


def block_at(y0: Real) -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2e4, 0.3)
    var vol = SP * SP * SP
    for i in range(8):
        for j in range(6):
            for k in range(8):
                m.add(Vec3(0.7 + Real(i) * SP, y0 + Real(j) * SP, 0.7 + Real(k) * SP, 0), vol * 900.0, vol)
    return m^


def block() -> MpmSolver:
    return block_at(0.16)


def height(m: MpmSolver) -> Real:
    var h = Real(-1e30)
    for ref q in m.p:
        h = max(h, q.x[1])
    return h


def bottom(m: MpmSolver) -> Real:
    var b = Real(1e30)
    for ref q in m.p:
        b = min(b, q.x[1])
    return b


def width(m: MpmSolver) -> Real:
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for ref q in m.p:
        lo = min(lo, q.x[0])
        hi = max(hi, q.x[0])
    return hi - lo


def run(mut m: MpmSolver, mut w: MpmMelt, steps: Int) raises:
    for _ in range(steps):
        w.step(m, DT, G)


def main() raises:
    var s = Suite("mpm_melt")

    # 1. the latent plateau
    var c = Real(2000)
    var lat = Real(2e5)
    var a0 = melt_state(Float64(c) * 330.0 - 2000.0, c, lat, 330.0)
    var a1 = melt_state(Float64(c) * 330.0 + 1e5, c, lat, 330.0)
    var a2 = melt_state(Float64(c) * 330.0 + 2e5 + 4000.0, c, lat, 330.0)
    s.check(abs(a0[0] - 329.0) < 1e-3 and a0[1] == 0, "below the plateau: T = H / c, solid")
    s.check(a1[0] == 330.0 and abs(a1[1] - 0.5) < 1e-6, "on the plateau: T = Tm, phi = 0.5")
    s.check(abs(a2[0] - 332.0) < 1e-3 and a2[1] == 1, "above: T = (H - L) / c, liquid")

    # 2. solid vs liquid vs heated
    var ms = block()
    var ws = MpmMelt(ms, SP, 1e-3, c, lat, 330.0, 300.0)
    var ml = block()
    var wl = MpmMelt(ml, SP, 1e-3, c, lat, 330.0, 340.0)
    var mh = block()
    var wh = MpmMelt(mh, SP, 1e-3, c, lat, 330.0, 300.0)
    var h0 = height(ms) - bottom(ms)
    var w0 = width(ms)
    # settle, then heat the bottom layer of the heated copy
    run(ms, ws, 400)
    run(ml, wl, 400)
    run(mh, wh, 400)
    wh.heat_floor(bottom(mh) + 0.5 * SP, 600.0, 1e5)
    var e0 = wh.total_enthalpy(mh)
    run(ms, ws, 2000)
    run(ml, wl, 2000)
    run(mh, wh, 2000)
    var hs = height(ms) - bottom(ms)
    var hl = height(ml) - bottom(ml)
    var hh = height(mh) - bottom(mh)
    print("after 1.2 s: height solid", hs, " liquid", hl, " heated", hh, " (start", h0, ")")
    print("  width solid", width(ms), " liquid", width(ml), " heated", width(mh), " (start", w0, ")")
    print("  melted fraction: solid", ws.melted(), " liquid", wl.melted(), " heated", wh.melted())
    s.check(ws.melted() == 0 and hs > 0.9 * h0, "solid block keeps its height (> 90 %)")
    s.check(wl.melted() == 1 and hl < 0.7 * h0 and width(ml) > 1.2 * w0, "liquid block slumps and spreads")
    s.check(wh.melted() > 0.1 and hh < 0.95 * hs, "heated block melts from below and loses height")

    # 3. enthalpy budget
    var e1 = wh.total_enthalpy(mh)
    var rel = abs((e1 - e0) - wh.heat_in) / wh.heat_in
    print("  enthalpy change", e1 - e0, "J  floor heat", wh.heat_in, "J  rel. error", rel)
    s.check(rel < 1e-5, "enthalpy changes by the floor's heat (1e-5)")

    # 4. bad input
    var raised = 0
    try:
        _ = MpmMelt(MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2e4, 0.3), SP, 1e-3, c, lat, 330.0, 300.0)
    except:
        raised += 1
    try:
        _ = MpmMelt(ms, SP, 1e-3, 0.0, lat, 330.0, 300.0)
    except:
        raised += 1
    s.check(raised == 2, "no particles / c <= 0 raise")

    # 5. mushy shear
    var zero_g = Vec3(0, 0, 0, 0)
    var shear_f = Mat3.identity()
    shear_f.set(0, 1, 0.05)
    var mm = block_at(0.5)
    var wm = MpmMelt(mm, SP, 1e-3, c, lat, 330.0, 330.0)
    var mS = block_at(0.5)
    var wS = MpmMelt(mS, SP, 1e-3, c, lat, 330.0, 300.0)
    var mL = block_at(0.5)
    var wL = MpmMelt(mL, SP, 1e-3, c, lat, 330.0, 340.0)
    for i in range(len(mm.p)):
        mm.p[i].f = shear_f
        mS.p[i].f = shear_f
        mL.p[i].f = shear_f
        wm.enthalpy[i] = Float64(c) * 330.0 + 0.5 * Float64(lat)
        wm.phi[i] = 0.5
        wm.heat.t[i] = 330.0
    wm.step(mm, DT, zero_g)
    wS.step(mS, DT, zero_g)
    wL.step(mL, DT, zero_g)
    var solid_mag = Real(0)
    var p1_err = Real(0)
    var phi_drift = Real(0)
    for i in range(len(mm.p)):
        solid_mag = max(solid_mag, length(mS.p[i].v))
        p1_err = max(p1_err, length(mm.p[i].v - mS.p[i].v * 0.5 - mL.p[i].v * 0.5))
        phi_drift = max(phi_drift, abs(wm.phi[i] - 0.5))
    var rel1 = p1_err / solid_mag

    # isotropic compression: the shear factor must not touch it
    var iso_f = Mat3.identity()
    for a in range(3):
        iso_f.set(a, a, 0.99)
    var mSi = block_at(0.5)
    var wSi = MpmMelt(mSi, SP, 1e-3, c, lat, 330.0, 300.0)
    var mLi = block_at(0.5)
    var wLi = MpmMelt(mLi, SP, 1e-3, c, lat, 330.0, 340.0)
    for i in range(len(mSi.p)):
        mSi.p[i].f = iso_f
        mLi.p[i].f = iso_f
    wSi.step(mSi, DT, zero_g)
    wLi.step(mLi, DT, zero_g)
    var iso_mag = Real(0)
    var iso_err = Real(0)
    for i in range(len(mSi.p)):
        iso_mag = max(iso_mag, length(mSi.p[i].v))
        iso_err = max(iso_err, length(mLi.p[i].v - mSi.p[i].v))
    var rel2 = iso_err / iso_mag
    print("mushy shear: solid |v| max", solid_mag, " P1 rel. err", rel1, " isotropic |v| max", iso_mag, " P2 rel. err", rel2, " phi drift", phi_drift)
    s.check(solid_mag > 0 and rel1 < 1e-6, "P1: v(mushy) = 0.5 v(solid) + 0.5 v(liquid), every particle (1e-6)")
    s.check(iso_mag > 0 and rel2 < 1e-6, "P2: liquid moves as the solid under isotropic compression (1e-6)")
    s.check(phi_drift < 1e-9, "P3: mushy phi stays 0.5 under uniform temperature")
    s.finish()
