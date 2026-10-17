# tier: integration
"""Moving spheres across the periodic boundary (ROADMAP 17.59,
`Lbm.move_sphere` with unwrapped centres).

The periodic lattice is invariant under whole-cell shifts, so a sphere
that crosses the boundary must feel what a twin shifted by 12 cells feels
while staying inside.

  1. Ordinary: R = 3 on 24^3, moving +x at 0.05 cells/step and spinning
     about z at 0.01 rad/step for 240 steps from x = 18.3 (crosses x = 24 and
     ends at 30.3, unwrapped) and from x = 6.3 (never near the edge): force
     and torque series agree within 1e-3 of their peak, mass within 1e-5.
     The solid cell count stays that of the sphere throughout (before the
     fix the box was clamped to the grid and the sphere lost its cells at
     the edge).
  2. Integration: a coupled body (`LbmSpherePort`, test_fsi units)
     launched at 5 cm/s across the boundary slows down as its shifted twin
     does (end velocity within 1e-3 relative).
  3. Extreme: a centre four periods out (x = 100.3) gives the same first
     force as x = 4.3 (1e-4); in tunnel mode x is not wrapped: a sphere at
     x = 1 has no solid cell at the far x end.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from fluid.lbm import Lbm, BC_TUNNEL
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.continuum import LbmContinuum
from physics.coupling import couple_step
from physics.fsi import LbmSpherePort
from diag.counters import Counters


struct Track(Movable):
    var f: List[Vec3]
    var t: List[Vec3]
    var solid_ok: Bool
    var mass: Real

    def __init__(out self, x0: Real) raises:
        self.f = List[Vec3]()
        self.t = List[Vec3]()
        self.solid_ok = True
        var l = Lbm(24, 24, 24, 0.16)
        l.init_uniform(1, 0, 0, 0)
        var c = Vec3(x0, 11.5, 11.5, 0)
        var k = l.add_moving_sphere(c, 3, Vec3(0.05, 0, 0, 0), Vec3(0, 0, 0.01, 0))
        var solid0 = l.solid_count()
        for _ in range(240):
            c = c + Vec3(0.05, 0, 0, 0)
            l.move_sphere(k, c, Vec3(0.05, 0, 0, 0), Vec3(0, 0, 0.01, 0))
            l.step()
            self.f.append(l.obj_f[k])
            self.t.append(l.obj_t[k])
            if abs(l.solid_count() - solid0) > solid0 // 4:
                self.solid_ok = False
        self.mass = 0
        for cell in range(l.cells()):
            if l.flag[cell] == 0:
                self.mass += l.density(cell)


def _series_err(a: List[Vec3], b: List[Vec3]) -> Real:
    var peak = Real(0)
    var err = Real(0)
    for i in range(len(a)):
        peak = max(peak, length(a[i]))
        err = max(err, length(a[i] - b[i]))
    return err / peak


def _coupled(x0: Real) raises -> Real:
    var sc = ContactScene6[QuatBody6]()
    var r = Real(3e-3)
    var vol = Real(4.0 / 3.0 * pi) * r * r * r
    var b = QuatBody6.at_rest(Vec3(x0, 11.5e-3, 11.5e-3, 0), Inertia3.sphere(1.5 * 1000 * vol, r))
    b.vel = Vec3(0.05, 0, 0, 0)
    _ = sc.add_sphere(b^, r, False)
    var lbm = Lbm(24, 24, 24, 0.16)
    lbm.init_uniform(1, 0, 0, 0)
    var cont = LbmContinuum(lbm^, 1e-3)
    var port = LbmSpherePort(1e-3, 1000, Vec3(0, 0, 0, 0))
    _ = port.add_sphere(sc, cont, sc.bset.id_of(0), r)
    var cfg = SolverConfig()
    cfg.substeps = 1
    cfg.iters = 4
    var counters = Counters()
    for _ in range(200):
        _ = couple_step(sc, port, cont, 1e-3, Vec3(0, 0, 0, 0), cfg, counters)
    return sc.velocity(sc.bset.id_of(0))[0]


def main() raises:
    var s = Suite("lbm_periodic")
    var a = Track(18.3)
    var b = Track(6.3)
    var ef = _series_err(a.f, b.f)
    var et = _series_err(a.t, b.t)
    print("  crossing vs shifted twin, 240 steps: force error", ef, " torque error", et, " (of peak);  mass", a.mass, b.mass)
    s.check(ef < 1e-3 and et < 1e-3 and abs(a.mass / b.mass - 1) < 1e-5, "a sphere crossing the boundary feels what its shifted twin feels")
    s.check(a.solid_ok and b.solid_ok, "the sphere keeps its cells across the boundary")

    var va = _coupled(20.5e-3)
    var vb = _coupled(8.5e-3)
    print("  coupled body across the boundary, 0.2 s: v", va, " shifted twin", vb)
    s.check(abs(va / vb - 1) < 1e-3 and va < 0.05, "a coupled body crosses the boundary like its twin")

    var far = Lbm(24, 24, 24, 0.16)
    far.init_uniform(1, 0, 0, 0)
    var kf = far.add_moving_sphere(Vec3(100.3, 11.5, 11.5, 0), 3, Vec3(0.05, 0, 0, 0), Vec3(0, 0, 0, 0))
    far.step()
    var near = Lbm(24, 24, 24, 0.16)
    near.init_uniform(1, 0, 0, 0)
    var kn = near.add_moving_sphere(Vec3(4.3, 11.5, 11.5, 0), 3, Vec3(0.05, 0, 0, 0), Vec3(0, 0, 0, 0))
    near.step()
    s.check(length(far.obj_f[kf] - near.obj_f[kn]) <= 1e-4 * length(near.obj_f[kn]), "four periods out = the wrapped position")

    var tun = Lbm(24, 24, 24, 0.16, BC_TUNNEL)
    tun.init_uniform(1, 0, 0, 0)
    _ = tun.add_moving_sphere(Vec3(1, 11.5, 11.5, 0), 3, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var far_end = 0
    for z in range(24):
        for y in range(24):
            for x in range(20, 24):
                if tun.flag[tun.idx(x, y, z)] != 0:
                    far_end += 1
    s.check(far_end == 0, "tunnel mode: x is not wrapped")
    s.finish()
