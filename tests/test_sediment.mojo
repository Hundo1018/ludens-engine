# tier: integration
"""Grains suspended in lattice fluid (ROADMAP 17.61, `physics.sediment`).

Fluid: `Lbm` 24^3, periodic, dx 2 mm, 1 ms per lattice step, rho 1000,
lattice viscosity 0.01 (nu 4e-5 m^2/s, 40x water, so the lattice is
stable at this step). Grains: quartz, 2650 kg/m^3, 0.5 mm, Stokes rate
beta 1087 /s, still-fluid settling speed 5.6 mm/s.

  1. Ordinary: in still fluid (one-way) a grain reaches the Stokes
     settling speed within 1 %; in an upward flow of twice that speed
     grains rise (held in suspension), in half of it they still sink at
     about (settling - flow).
  2. Integration (two-way): 400 grains settling drag the fluid down; the
     fluid's momentum changes by exactly the impulse it got (1e-3), which
     is minus the grains' drag impulse; the cloud sinks faster than the
     same cloud one-way (the fluid around it moves with it).
  3. Extreme: d <= 0 raises; grains stop at the floor.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from fluid.lbm import Lbm
from physics.sediment import Sediment

comptime DX: Real = 0.002
comptime DT: Real = 1e-3
comptime G = Vec3(0, -9.8, 0, 0)
comptime NU: Real = 0.01 * DX * DX / DT


def fluid(uy_lat: Real = 0) -> Lbm:
    var l = Lbm(24, 24, 24, 0.01)
    l.init_uniform(1.0, 0.0, uy_lat, 0.0)
    return l^


def sed(uy_lat: Real, two_way: Bool) raises -> Sediment:
    return Sediment(fluid(uy_lat), Vec3(0, 0, 0, 0), DX, DT, 1000.0, NU, 2650.0, 5e-4, Vec3(0, 0, 0, 0), Vec3(0.048, 0.048, 0.048, 0), two_way)


def main() raises:
    var s = Suite("sediment")
    var one = sed(0, False)
    one.add(Vec3(0.024, 0.04, 0.024, 0))
    for _ in range(100):
        one.step(G)
    var ws = one.settling_speed(G)
    print("Stokes rate", one.beta(), "/s  settling speed", ws, "m/s   grain vy after 0.1 s", one.v[0][1])
    s.check(abs(-one.v[0][1] / ws - 1) < 0.01, "still fluid: Stokes settling speed (1 %)")

    # upward flow: 2 x and 0.5 x the settling speed (lattice units: m/s / (dx / dt))
    var up2 = sed(2 * ws / (DX / DT), False)
    var up05 = sed(0.5 * ws / (DX / DT), False)
    for k in range(5):
        up2.add(Vec3(0.01 + 0.006 * Real(k), 0.02, 0.024, 0))
        up05.add(Vec3(0.01 + 0.006 * Real(k), 0.02, 0.024, 0))
    var h0 = up2.mean_height()
    for _ in range(500):
        up2.step(G)
        up05.step(G)
    print("upward flow 2 x settling: height change", up2.mean_height() - h0, "  0.5 x:", up05.mean_height() - h0, " (expected", 0.5 * ws, "/", -0.25 * ws, ")")
    s.check(up2.mean_height() > h0, "flow faster than settling holds grains up")
    s.check(abs((up05.mean_height() - h0) / (-0.25 * ws) - 1) < 0.05, "flow at half the settling speed: grains sink at (settling - flow), 5 %")

    # two-way cloud
    var c1 = sed(0, False)
    var c2 = sed(0, True)
    for i in range(20):
        for k in range(20):
            var p = Vec3(0.014 + 0.001 * Real(i), 0.036, 0.014 + 0.001 * Real(k), 0)
            c1.add(p)
            c2.add(p)
    var m0 = c2.fluid_momentum()
    var y0 = c1.mean_height()
    for _ in range(300):
        c1.step(G)
        c2.step(G)
    var dm = c2.fluid_momentum() - m0
    print("cloud of 400 grains, 0.3 s: sank one-way", y0 - c1.mean_height(), " two-way", y0 - c2.mean_height())
    print("  fluid momentum change y", dm[1], " impulse", c2.fluid_impulse[1], " grains' drag impulse", c2.grain_drag_impulse[1])
    s.check(dm[1] < 0 and abs(dm[1] - c2.fluid_impulse[1]) < 1e-3 * abs(c2.fluid_impulse[1]), "two-way: fluid momentum changes by its impulse (1e-3)")
    s.check(length(c2.fluid_impulse + c2.grain_drag_impulse) < 1e-6 * length(c2.fluid_impulse), "two-way: drag impulses equal and opposite")
    s.check(y0 - c2.mean_height() > y0 - c1.mean_height(), "two-way: the cloud drags the fluid and sinks faster")

    # floor and bad input
    var fl = sed(0, False)
    fl.add(Vec3(0.024, 0.001, 0.024, 0))
    for _ in range(400):
        fl.step(G)
    s.check(fl.x[0][1] == 0 and fl.v[0][1] == 0, "a grain stops at the floor")
    var raised = False
    try:
        _ = Sediment(fluid(), Vec3(0, 0, 0, 0), DX, DT, 1000.0, NU, 2650.0, 0.0, Vec3(0, 0, 0, 0), Vec3(0.048, 0.048, 0.048, 0))
    except:
        raised = True
    s.check(raised, "diameter <= 0 raises")
    s.finish()
