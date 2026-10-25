# tier: integration
"""Water whose density follows its temperature (ROADMAP 17.61,
`physics.thermal_float`).

Glue:

  1. Equation of state: at t_ref the density is rho0; at t_ref + 30 K it is
     rho0 (1 - beta 30); a column held uniformly reports the held value as
     its mean temperature.
  2. Direction: a column with its top cell held hot warms by conduction, so
     its mean temperature rises over every block of 1 s and its density
     falls with it. A cold column is denser than rho0.
  3. Isolation passes through: a non-finite cell is counted by the grid and
     the column density stays finite.

Float integration: a box (half 0.3 x 0.2 x 0.3 m, footprint 0.36 m^2,
70 kg) floats in a tank whose surface is at y = 2 m; the column density is
copied into the `WaterVolume` every frame.
  4. Steady draft: the column held at 293.15, 323.15 and 353.15 K in turn.
     At rest the draft is M / (rho(T) A) within 2 % and the draft ratio
     between two temperatures is rho_ref / rho within 0.1 %. The absolute
     offset (measured +1.0 %) is the buoyancy splitting: the impulse lands
     once per frame, gravity per substep, so the velocity is a sawtooth and
     the implicit drag v / (1 + c f dt) acts on its post-impulse peak
     0.625 g dt; the periodic orbit needs buoyancy = weight (1 + 0.625 c f dt)
     = 1.0101 for c 2, f 0.487, dt 1/60. It cancels in the ratio.
  5. Transient: from the settled state, the top cell of the column is held
     at 353.15 K with alpha 1e-2 m^2/s (water is 1.4e-7; the value makes
     the transient visible in 20 s). The draft rises monotonically.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume, apply_buoyancy
from physics.thermal import HeatGrid
from physics.thermal_float import HeatedWater

comptime RHO0: Real = 998.2
comptime T0: Real = 293.15
comptime BETA: Real = 2.07e-4
comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime SURFACE: Real = 2
comptime HALF = Vec3(0.3, 0.2, 0.3, 0)
comptime MASS: Real = 70
comptime AREA: Real = 4 * 0.3 * 0.3
comptime SETTLE = 1200


def column(t0: Real, alpha: Real) raises -> HeatedWater:
    return HeatedWater(HeatGrid(1, 1, 7, 1.0, alpha, t0), RHO0, T0, BETA)


def scene(y0: Real) raises -> ContactScene6[QuatBody6]:
    """Body 0 is the floor, body 1 the box."""
    var bw = ContactScene6[QuatBody6]()
    _ = bw.add(QuatBody6.at_rest(Vec3(0, -5.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    var fl = bw.add(QuatBody6.at_rest(Vec3(0, y0, 0, 0), Inertia3.box(MASS, HALF[0], HALF[1], HALF[2])), HALF, False)
    bw.set_can_sleep(fl, False)
    return bw^


def draft(bw: ContactScene6[QuatBody6]) -> Real:
    return SURFACE - (bw.bset.bodies[1].position()[1] - HALF[1])


def run(mut bw: ContactScene6[QuatBody6], mut hw: HeatedWater, frames: Int) raises:
    var waters = List[WaterVolume]()
    waters.append(WaterVolume(Vec3(-10, -5, -10, 0), Vec3(10, SURFACE, 10, 0), hw.density(), 2, 2))
    for _ in range(frames):
        hw.step(DT)
        waters[0].density = hw.density()
        apply_buoyancy(bw, waters, G, DT)
        bw.step_soft(DT, G)


def case_steady(mut s: Suite) raises:
    var bw = scene(SURFACE - MASS / (RHO0 * AREA) + HALF[1])
    var d_ref: Real = 0
    var rho_ref: Real = 0
    for t in [T0, 323.15, 353.15]:
        var hw = column(t, 1e-5)
        run(bw, hw, SETTLE)
        var rho = hw.density()
        var expect = MASS / (rho * AREA)
        var d = draft(bw)
        var rel = (d - expect) / expect
        var om = bw.bset.bodies[1].omega_world()
        # Metacentric height of the flat box: GM = KB + BM - KG, with KB = d / 2,
        # BM = I / V = a^2 / (12 d) for a square waterplane of side a, KG = half height.
        var a = 2 * HALF[0]
        var gm = d / 2 + a * a / (12 * d) - HALF[1]
        print("  T", t, "rho", rho, "draft", d, "M/(rho A)", expect, "rel", rel, "|omega|", (om[0] * om[0] + om[1] * om[1] + om[2] * om[2]) ** 0.5, "GM", gm)
        s.check(gm > 0, "the flat box is stable at " + String(t) + " K (GM > 0), so its draft is the hydrostatic one")
        s.check(abs(rel) < 0.02, "steady draft at " + String(t) + " K is M / (rho A) within 2 %")
        if t == T0:
            d_ref = d
            rho_ref = rho
        else:
            var ratio_rel = (d / d_ref) / (rho_ref / rho) - 1
            print("  draft ratio vs rho_ref / rho: rel", ratio_rel)
            s.check(abs(ratio_rel) < 1e-3, "draft ratio to " + String(t) + " K is rho_ref / rho within 0.1 %")
            s.check(d > d_ref, "draft grows as the water warms to " + String(t) + " K")


def case_transient(mut s: Suite) raises:
    var bw = scene(SURFACE - MASS / (RHO0 * AREA) + HALF[1])
    var settle = column(T0, 1e-5)
    run(bw, settle, SETTLE)
    var hw = column(T0, 1e-2)
    hw.grid.fix(0, 0, 6, 353.15)
    var first = draft(bw)
    var last = first
    var monotone = True
    for _ in range(12):
        run(bw, hw, SETTLE // 12)
        var d = draft(bw)
        if d < last - 1e-4:
            monotone = False
        last = d
    # Quasi-static prediction: draft is proportional to 1 / rho, so the rise
    # is first * (rho_start / rho_end - 1) at the final mean temperature.
    var pred = first * (settle.density() / hw.density() - 1)
    var rise = last - first
    print("  heated top cell: draft start", first, "end", last, "rise", rise, "predicted", pred, "mean T", hw.mean_temperature())
    s.check(monotone, "draft never falls while the top cell is held hot")
    s.check(abs(rise / pred - 1) < 0.02, "the rise over 20 s matches the quasi-static prediction within 2 %")


def main() raises:
    var s = Suite("thermal_float")

    var w = column(T0, 1e-5)
    s.check(w.density() == RHO0, "density at t_ref is rho0")

    for k in range(7):
        w.grid.fix(0, 0, k, T0 + 30)
    var want = RHO0 * (1 - BETA * 30)
    s.almost(Float64(w.density()), Float64(want), "uniform +30 K column: density is rho0 (1 - beta 30)", tol=1e-3)
    s.almost(Float64(w.mean_temperature()), Float64(T0 + 30), "uniform column: mean temperature is the held value", tol=1e-4)

    var cold = column(T0 - 20, 1e-5)
    s.check(cold.density() > RHO0, "a column colder than t_ref is denser than rho0")

    var hot = column(T0, 1e-2)
    hot.grid.fix(0, 0, 6, 353.15)
    var last = hot.mean_temperature()
    var last_rho = hot.density()
    var rising = True
    var falling = True
    for _ in range(60):
        for _ in range(60):
            hot.step(1.0 / 60.0)
        var m = hot.mean_temperature()
        if m <= last:
            rising = False
        last = m
        var r = hot.density()
        if r >= last_rho:
            falling = False
        last_rho = r
    s.check(rising, "a column with its top held hot warms by conduction over every second")
    s.check(falling, "its density falls as it warms")
    s.check(hot.density() < RHO0, "after 60 s the hot column is less dense than rho0")

    var bad = column(T0, 1e-5)
    bad.grid.t[3] = Real(0) / Real(0)
    bad.step(1e-3)
    s.check(bad.grid.isolated == 1, "a non-finite cell is isolated and counted")
    s.check(isfinite(bad.density()), "the column density stays finite after the isolation")

    case_steady(s)
    case_transient(s)
    s.finish()
