# tier: component
"""ROADMAP 17.4: the arithmetic of the vehicle -- tire model, engine, gearbox,
differentials -- with no scene.

Ordinary: the tire curve is zero at zero slip, odd, peaks once at the stated
slip and falls to a lower sliding level; the force never exceeds mu * Fz in any
direction; the engine torque curve interpolates; gear ratios multiply.
Integration: combined slip trades longitudinal for lateral grip along a friction
ellipse; open / limited-slip / locked differentials move torque the way their
definitions say and always conserve the axle torque.
Extreme: zero load, zero friction, NaN-free huge slips, reverse gear, a torque
curve with one point or none, a limited-slip with bias larger than the torque."""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real
from gameplay.vehicle_tire import TireCurve, TireModel
from gameplay.vehicle_drive import (
    TorqueCurve,
    DriveConfig,
    split_axle,
    DIFF_OPEN,
    DIFF_LSD,
    DIFF_LOCKED,
)


def main() raises:
    var s = Suite("vehicle_drive")

    # ---- tire curve ----
    var c = TireCurve.default()
    s.almost(Float64(c.norm(0)), 0.0, "zero slip, zero force", 1e-7)
    s.almost(Float64(c.norm(1)), 1.0, "normalised peak is 1 at s = 1", 2e-3)
    s.almost(Float64(c.norm(0.5) + c.norm(-0.5)), 0.0, "odd in slip", 1e-6)
    s.check(c.norm(0.5) < c.norm(1.0), "rising before the peak")
    s.check(c.norm(3.0) < c.norm(1.0), "falling after the peak")
    s.check(c.norm(8.0) > 0.4 and c.norm(8.0) < 0.9, "sliding level between 40% and 90% of peak (" + String(c.norm(8.0)) + ")")
    var peak_seen = Real(0)
    var at = Real(0)
    for i in range(1, 400):
        var x = Real(i) * 0.01
        if c.norm(x) > peak_seen:
            peak_seen = c.norm(x)
            at = x
    s.almost(Float64(at), 1.0, "single peak at normalised slip 1", 0.05)
    s.almost(Float64(c.peak_x), 0.125, "default peak slip ratio", 0.01)

    # ---- friction ellipse ----
    var t = TireModel.default()
    var worst = Real(0)
    for i in range(-30, 31):
        for j in range(-30, 31):
            var f = t.grip(Real(i) * 0.02, Real(j) * 0.03, 1.0, 1000.0)
            var m = sqrt(f[0] * f[0] + f[1] * f[1])
            if m > worst:
                worst = m
    s.check(worst <= 1000.0 * 1.0035, "no slip combination exceeds mu * Fz (max " + String(worst) + ")")
    var pure = t.grip(0.125, 0, 1.0, 1000.0)
    s.almost(Float64(pure[0]), 1000.0, "pure longitudinal peak = mu Fz", 8.0)
    s.almost(Float64(pure[1]), 0.0, "no lateral force without lateral slip", 1e-3)
    var lat_only = t.grip(0, 0.18, 1.0, 1000.0)
    s.almost(Float64(lat_only[1]), 1000.0, "pure lateral peak = mu Fz", 8.0)
    var combo = t.grip(0.125, 0.18, 1.0, 1000.0)
    s.check(combo[0] < pure[0] * 0.8, "full braking slip costs longitudinal share when steering too")
    s.check(combo[1] < lat_only[1] * 0.8, "and costs lateral share")
    var neg = t.grip(-0.125, -0.18, 1.0, 1000.0)
    s.almost(Float64(neg[0] + combo[0]), 0.0, "force flips sign with slip (x)", 1e-3)
    s.almost(Float64(neg[1] + combo[1]), 0.0, "force flips sign with slip (y)", 1e-3)
    var half_mu = t.grip(0.125, 0, 0.5, 1000.0)
    s.almost(Float64(half_mu[0]), 500.0, "force scales with surface friction", 5.0)
    var zero_mu = t.grip(0.125, 0.18, 0.0, 1000.0)
    s.check(zero_mu[0] == 0 and zero_mu[1] == 0, "mu = 0 gives no force")
    var no_load = t.grip(0.125, 0.18, 1.0, 0.0)
    s.check(no_load[0] == 0 and no_load[1] == 0, "zero load gives no force")
    var huge = t.grip(1.0e6, -1.0e6, 1.0, 1000.0)
    s.check(huge[0] == huge[0] and huge[1] == huge[1] and abs(huge[0]) <= 1000.0 and abs(huge[1]) <= 1000.0, "absurd slip stays finite and bounded")

    # ---- torque curve and gearbox ----
    var tc = TorqueCurve.sedan()
    s.almost(Float64(tc.at(3500)), 300.0, "torque at a table point", 1e-3)
    s.almost(Float64(tc.at(2750)), 275.0, "torque interpolates between points", 1e-3)
    s.almost(Float64(tc.at(-100)), 120.0, "clamped below the first point", 1e-3)
    s.almost(Float64(tc.at(99999)), 150.0, "clamped above the last point", 1e-3)
    var single = TorqueCurve()
    single.add(1000, 77)
    s.almost(Float64(single.at(5000)), 77.0, "a one-point curve is constant", 1e-3)
    var empty = TorqueCurve()
    s.almost(Float64(empty.at(1000)), 0.0, "an empty curve gives no torque", 1e-9)

    var d = DriveConfig()
    s.almost(Float64(d.gear_ratio(1)), 3.6 * 3.6, "first gear x final drive", 1e-4)
    s.almost(Float64(d.gear_ratio(-1)), 3.4 * 3.6, "reverse x final drive", 1e-4)
    s.almost(Float64(d.gear_ratio(0)), 0.0, "neutral transmits nothing", 1e-9)
    s.almost(Float64(d.gear_ratio(99)), 0.8 * 3.6, "gear above the top clamps to the top", 1e-4)
    s.almost(Float64(d.engine_rpm(0, 1.0)), 2500.0, "launch: clutch slips to launch rpm under throttle", 1e-3)
    s.almost(Float64(d.engine_rpm(0, 0.0)), 900.0, "off throttle at rest: idle", 1e-3)
    s.almost(Float64(d.engine_rpm(4000, 1.0)), 4000.0, "locked: engine follows the wheels", 1e-3)
    s.almost(Float64(d.engine_torque(4000, 4000, 1.0)), 300.0, "full throttle torque", 1e-3)
    s.almost(Float64(d.engine_torque(4000, 4000, 0.5)), 150.0, "half throttle, half torque", 1e-3)
    s.almost(Float64(d.engine_torque(7000, 7000, 1.0)), 0.0, "fuel cut above redline", 1e-9)
    s.check(d.engine_torque(4000, 4000, 0.0) < 0, "engine braking when the throttle is closed")

    # ---- differentials ----
    var o = split_axle(DIFF_OPEN, 1000, 50, 10, 0, 0, 0)
    s.almost(Float64(o[0]), 500.0, "open: equal torque (left)", 1e-4)
    s.almost(Float64(o[1]), 500.0, "open: equal torque (right)", 1e-4)
    var l1 = split_axle(DIFF_LSD, 1000, 50, 10, 100, 10, 2000)
    s.almost(Float64(l1[0] + l1[1]), 1000.0, "LSD conserves axle torque", 1e-3)
    s.check(l1[1] > l1[0], "LSD sends torque to the slower (right) wheel")
    s.almost(Float64(l1[1] - l1[0]), 100.0 + 10.0 * 40.0, "LSD bias = preload + lock * dw", 1e-2)
    var l2 = split_axle(DIFF_LSD, 1000, 10, 50, 100, 10, 2000)
    s.check(l2[0] > l2[1], "mirrored: torque to the slower (left) wheel")
    s.almost(Float64(l2[0]), Float64(l1[1]), "LSD is mirror symmetric", 1e-3)
    var capped = split_axle(DIFF_LSD, 1000, 500, 0, 100, 100, 300)
    s.almost(Float64(capped[1] - capped[0]), 300.0, "LSD bias capped at max_bias", 1e-3)
    var big = split_axle(DIFF_LSD, 100, 500, 0, 1e6, 1e6, 1e9)
    s.check(big[0] >= -1e-3 and big[1] >= -1e-3, "LSD never reverses the faster wheel's torque")
    s.almost(Float64(big[0] + big[1]), 100.0, "bias larger than the torque still conserves it", 1e-3)
    var lk = split_axle(DIFF_LOCKED, 1000, 30, 20, 0, 0, 0)
    s.almost(Float64(lk[0]), 0.0, "locked: all torque to the slower wheel (torque cap)", 1e-3)
    s.almost(Float64(lk[1]), 1000.0, "locked: slower wheel gets the axle torque", 1e-3)
    var same = split_axle(DIFF_LSD, 1000, 20, 20, 100, 10, 500)
    s.almost(Float64(same[0]), 500.0, "equal wheel speeds: even split", 1e-4)
    var rev = split_axle(DIFF_LSD, -1000, 50, 10, 100, 10, 2000)
    s.almost(Float64(rev[0] + rev[1]), -1000.0, "negative (engine-brake) torque conserved", 1e-3)

    s.finish()
