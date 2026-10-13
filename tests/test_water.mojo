# tier: integration
"""Water surfaces and floating bodies (ROADMAP 17.60).

  1. Ordinary: `GerstnerWater` with every amplitude 0 equals `FlatWater`
     bit for bit; one wave with steepness 0 is A cos(k x - w t) to 1e-5 with
     w^2 = g k; with steepness 0.8 the inverse map lands on the displaced
     surface (|height - y| <= 1e-3 A) and the crest is still at +A.
  2. Integration: a 2 x 1 x 2 m box of density 500 floating on flat water
     (`float_body`, 8^3 samples) settles with its centre at the waterline
     (half submerged; the 1/8 sampling layers allow +-6.25 cm); on a 40 m
     swell of amplitude 0.5 m it heaves with the wave's period (within 10 %)
     and a peak-to-peak within 25 % of 2A; a ripple on a 1 m deep
     `ShallowWaterGrid` reaches a probe 5 m away at about 5 / sqrt(g H)
     (within 15 %, the grid's dispersion slows the peak).
  3. Extreme: a step above the CFL limit raises; a 2 x 2 grid raises; a box
     above the water gets no buoyancy and a sunk one gets its whole volume;
     with damping 0.5 /s the ripple's sum(eta^2) falls below half in 400
     steps (2 % measured; undamped 74 %: eta^2 alone is not the conserved
     energy, the kinetic part is not counted).
"""

from std.math import sqrt, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.water import FlatWater, GerstnerWater, ShallowWaterGrid, float_body

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _boat(y: Real) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, y, 0, 0), Inertia3.box(2000, 1, 0.5, 1)), Vec3(1, 0.5, 1, 0), False)
    return sc^


def main() raises:
    var s = Suite("water")

    # ---- surfaces ----------------------------------------------------------------------------------
    var flat = FlatWater(1.5)
    var calm = GerstnerWater(1.5)
    calm.add(1, 0, 0, 20)
    calm.add(0.3, 1, 0, 7, 0.5)
    var same = True
    for k in range(50):
        var x = Real(k) * 1.37 - 30
        var z = Real(k % 7) * 2.1
        var t = Real(k) * 0.31
        if calm.height(x, z, t) != flat.height(x, z, t):
            same = False
    s.check(same, "Gerstner with zero amplitudes == flat water, bit for bit")
    var sea = GerstnerWater(0)
    sea.add(1, 0, 0.5, 20)
    var k20 = 2 * Real(pi) / 20
    var w20 = sqrt(Real(9.8) * k20)
    var worst = Real(0)
    for k in range(40):
        var x = Real(k) * 0.77
        var t = Real(k) * 0.13
        worst = max(worst, abs(sea.height(x, 0, t) - 0.5 * cos(k20 * x - w20 * t)))
    print("  single wave Q=0: max |height - A cos(kx - wt)|", worst, "  omega", sea.omega(0), "(sqrt(g k) =", w20, ")")
    s.check(worst < 1e-5 and abs(sea.omega(0) - w20) < 1e-6, "steepness 0 is the plain sinusoid with deep-water dispersion")
    var steep = GerstnerWater(0)
    steep.add(1, 0.2, 0.5, 20, 0.8)
    var inv = Real(0)
    for k in range(30):
        var p = steep._displace(Real(k) * 1.1 - 10, Real(k % 5), Real(k) * 0.2)
        inv = max(inv, abs(steep.height(p[0], p[2], Real(k) * 0.2) - p[1]))
    var crest = steep.height(0, 0, 0)
    print("  steepness 0.8: inverse-map error", inv, "  crest height", crest)
    s.check(inv <= 1e-3 * 0.5 and abs(crest - 0.5) < 1e-3, "steep Gerstner: the inverse map lands on the surface, crest at +A")

    # ---- floating ------------------------------------------------------------------------------------
    var sc = _boat(1.0)
    var id = sc.bset.id_of(0)
    var still = FlatWater(0)
    for _ in range(600):
        _ = float_body(sc, id, Vec3(1, 0.5, 1, 0), still, 0, 1000, G, 2.0, 8)
        sc.step_soft(DT, G)
    var yc = sc.pose(id).pos[1]
    print("  box density 500 on flat water: centre y", yc, " (waterline 0)")
    s.check(abs(yc) <= 0.0625 + 0.005, "settles half submerged (within the sampling layer)")

    var swell = GerstnerWater(0)
    swell.add(1, 0, 0.5, 40)
    var period = 2 * Real(pi) / swell.omega(0)
    var sb = _boat(0)
    var sid = sb.bset.id_of(0)
    var t = Real(0)
    var lo = Real(1e9)
    var hi = Real(-1e9)
    var crossings = List[Real]()
    var last = Real(0)
    for st in range(1500):
        _ = float_body(sb, sid, Vec3(1, 0.5, 1, 0), swell, t, 1000, G, 2.0, 6)
        sb.step_soft(DT, G)
        t += DT
        var y = sb.pose(sid).pos[1]
        if st > 600:
            lo = min(lo, y)
            hi = max(hi, y)
            if last < 0 and y >= 0:
                crossings.append(t)
        last = y
    var measured = (crossings[len(crossings) - 1] - crossings[0]) / Real(len(crossings) - 1)
    print("  box on a 40 m swell, A = 0.5: heave", hi - lo, "(2A = 1)  period", measured, "(wave", period, ")")
    s.check(abs(measured / period - 1) < 0.1 and abs((hi - lo) - 1) < 0.25, "heave follows the swell: period within 10 %, height within 25 %")

    var above = _boat(5)
    s.check(float_body(above, above.bset.id_of(0), Vec3(1, 0.5, 1, 0), still, 0, 1000, G) == 0, "a box above the water: no buoyancy")
    var below = _boat(-5)
    var vfull = float_body(below, below.bset.id_of(0), Vec3(1, 0.5, 1, 0), still, 0, 1000, G)
    s.check(abs(vfull - 4) < 1e-4, "a sunk box: its whole volume (4 m^3)")

    # ---- shallow water -------------------------------------------------------------------------------
    var sw = ShallowWaterGrid(81, 81, 0.25, -10, -10, 0, 1.0)
    var dt = 0.5 * sw.max_dt()
    sw.disturb(0, 0, 1.0, 0.2)
    var e0 = sw.energy()
    var arrive = Real(-1)
    var peak = Real(0)
    var tt = Real(0)
    for _ in range(Int(3.0 / dt)):
        sw.step(dt)
        tt += dt
        var hgt = sw.height(5, 0, tt)
        if hgt > peak:
            peak = hgt
            arrive = tt
    var expect = Real(5) / sw.wave_speed()
    print("  ripple: peak at 5 m after", arrive, "s, 5 / sqrt(gH) =", expect, " energy", e0, "->", sw.energy())
    s.check(abs(arrive / expect - 1) < 0.15, "ripple arrives at 5 / sqrt(g H) within 15 %")
    var damped = ShallowWaterGrid(41, 41, 0.25, -5, -5, 0, 1.0, 9.8, 0.5)
    damped.disturb(0, 0, 1.0, 0.2)
    var kept = ShallowWaterGrid(41, 41, 0.25, -5, -5, 0, 1.0)
    kept.disturb(0, 0, 1.0, 0.2)
    var ed0 = damped.energy()
    var dt2 = 0.5 * kept.max_dt()
    for _ in range(400):
        damped.step(dt2)
        kept.step(dt2)
    print("  energy after 400 steps: damped", damped.energy() / ed0, " undamped", kept.energy() / ed0)
    s.check(damped.energy() < 0.5 * ed0, "damping drains ripple energy")
    var raised = 0
    try:
        sw.step(sw.max_dt() * 1.5)
    except:
        raised += 1
    try:
        _ = ShallowWaterGrid(2, 2, 1, 0, 0, 0, 1)
    except:
        raised += 1
    s.check(raised == 2, "CFL violation and a 2 x 2 grid raise")
    s.finish()
