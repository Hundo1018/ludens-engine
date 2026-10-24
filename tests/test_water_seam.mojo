# tier: integration
"""`apply_buoyancy_surface`: the water volumes' buoyancy with the level from a
`WaterSurface` (ROADMAP 17.60).

  1. Ordinary (seam parity): a box and a sphere dropped into a water volume
     move bit for bit the same over 3 s with `apply_buoyancy` and with
     `apply_buoyancy_surface` on `FlatWater` at the volume's top.
  2. Integration: the same box (1 m, density 500) on a 40 m Gerstner swell
     of amplitude 0.5 heaves 2A within 25 % (measured 1.11; 1.18 with the staircase submerged volume: its own heave
     period, about 1.4 s, against the wave's 5.06 s amplifies the forced
     motion -- 1.085 undamped -- and 10 to 20 s still carries some of the
     drop), and on a `FftOcean` single mode of the same wave the heave is
     the same within 2 % (measured identical: the two surfaces are one
     wave).
  3. Extreme: a body outside every footprint is untouched; a body above
     the surface is untouched.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fields import WaterVolume, apply_buoyancy
from physics.water import FlatWater, GerstnerWater, FftOcean, WaterSurface, apply_buoyancy_surface

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 1.0, 0, 0), Inertia3.box(500, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    _ = sc.add_sphere(QuatBody6.at_rest(Vec3(3, 1.5, 0, 0), Inertia3.sphere(300, 0.5)), 0.5, False)
    return sc^


def _pool() -> List[WaterVolume]:
    return [WaterVolume(Vec3(-50, -20, -50, 0), Vec3(50, 0, 50, 0), 1000, 1, 1)]


def _heave[W: WaterSurface](water: W) raises -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(500, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var cfg = SolverConfig()
    var pool = _pool()
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for k in range(1200):
        var t = Real(k) * DT
        apply_buoyancy_surface(sc, pool, water, t, G, DT, 4)
        sc.step(DT, G, cfg)
        if k > 600:
            var y = sc.pose(sc.bset.id_of(0)).pos[1]
            lo = min(lo, y)
            hi = max(hi, y)
    return hi - lo


def main() raises:
    var s = Suite("water_seam")
    var cfg = SolverConfig()
    var a = _scene()
    var b = _scene()
    var pool = _pool()
    var flat = FlatWater(0)
    var same = True
    for k in range(180):
        apply_buoyancy(a, pool, G, DT)
        apply_buoyancy_surface(b, pool, flat, Real(k) * DT, G, DT)
        a.step(DT, G, cfg)
        b.step(DT, G, cfg)
        for i in range(2):
            same = same and a.bset.bodies[i].pos == b.bset.bodies[i].pos and a.bset.bodies[i].vel == b.bset.bodies[i].vel
    print("  box and sphere, 3 s: y", a.bset.bodies[0].pos[1], a.bset.bodies[1].pos[1], " same", same)
    s.check(same, "FlatWater at the volume's top: apply_buoyancy, bit for bit")

    var g = GerstnerWater(0)
    g.add(1, 0, 0.5, 40, 0, 0)
    var o = FftOcean(32, 320, 0)
    o.set_mode(8, 0, 0.5, 0)
    var hg = _heave(g)
    var ho = _heave(o)
    print("  1 m box on a 40 m swell, A 0.5, 10 to 20 s: heave Gerstner", hg, " FFT mode", ho, " (2A = 1)")
    s.check(abs(hg - 1) < 0.25 and abs(ho / hg - 1) < 0.02, "the box rides the swell; the FFT mode is the same wave")

    var c = ContactScene6[QuatBody6]()
    _ = c.add(QuatBody6.at_rest(Vec3(100, -1, 0, 0), Inertia3.box(500, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    _ = c.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(500, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    apply_buoyancy_surface(c, pool, g, 0, G, DT)
    s.check(c.bset.bodies[0].vel == Vec3(0, 0, 0, 0) and c.bset.bodies[1].vel == Vec3(0, 0, 0, 0), "outside the footprint or above the surface: untouched")
    s.finish()
