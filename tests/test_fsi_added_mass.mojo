# tier: integration
"""Implicit wall drag for light bodies in the LBM <-> rigid coupling
(ROADMAP 17.59, `LbmSpherePort.set_implicit`, `Lbm.wall_drag`). Setting as `test_fsi`: dx = 1 mm,
dt = 1 ms, rho = 1000, lattice viscosity 0.16, R = 3 mm, 24^3 periodic
lattice, `couple_step` over an `LbmContinuum`.

  1. Ordinary: a sphere of density ratio 0.5 launched at 5 cm/s: with the
     plain exchange it diverges (as `LbmCoupler`, test_fsi); implicit, it
     stays finite and slows down (|v| after 0.3 s < 5 cm/s, never above the
     launch speed). The measured wall drag rho Z dx^3 is printed against
     rho V (the fit in `scripts/added_mass_fit.py` gives 0.66 rho V).
  2. Integration: a heavy sphere (ratio 1.5) settling under gravity for
     0.4 s ends at the same velocity with and without the implicit drag
     (within 5 %: at constant velocity both apply F + m g = 0).
  3. Extreme: ratios 0.2 and 0.05 (the fitted model's limit) stay finite
     and slow down; implicit off is the plain port bit for bit.
"""

from std.math import pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.continuum import LbmContinuum
from physics.coupling import couple_step
from physics.fsi import LbmSpherePort
from diag.counters import Counters
from fluid.lbm import Lbm

comptime DX: Real = 1e-3
comptime DT: Real = 1e-3
comptime RHO: Real = 1000
comptime NU_LAT: Real = 0.16
comptime N = 24
comptime R: Real = 3e-3


struct Run(Movable):
    var sc: ContactScene6[QuatBody6]
    var cont: LbmContinuum
    var port: LbmSpherePort

    def __init__(out self, ratio: Real, v0: Vec3, g: Real, implicit: Bool) raises:
        self.sc = ContactScene6[QuatBody6]()
        var vol = Real(4.0 / 3.0 * pi) * R * R * R
        var b = QuatBody6.at_rest(Vec3(18.5e-3, 11.5e-3, 11.5e-3, 0), Inertia3.sphere(ratio * RHO * vol, R))
        b.vel = v0
        _ = self.sc.add_sphere(b^, R, False)
        var lbm = Lbm(N, N, N, NU_LAT)
        lbm.init_uniform(1, 0, 0, 0)
        self.cont = LbmContinuum(lbm^, DT)
        self.port = LbmSpherePort(DX, RHO, Vec3(0, 0, 0, 0))
        self.port.set_implicit(implicit)
        _ = self.port.add_sphere(self.sc, self.cont, self.sc.bset.id_of(0), R)
        # Hasimoto: a uniform body force on the fluid carries the net weight
        var w_net = (ratio - 1) * RHO * vol * g
        var f_lat = w_net * DT * DT / (RHO * DX * DX * DX * DX)
        self.cont.lbm.force_x = f_lat / Real(N * N * N - self.cont.lbm.solid_count())

    def run(mut self, steps: Int, g: Real, cfg: SolverConfig) raises -> Tuple[Bool, Real]:
        """(finite throughout, max |v|)."""
        var counters = Counters()
        var vmax = Real(0)
        for _ in range(steps):
            _ = couple_step(self.sc, self.port, self.cont, DT, Vec3(-g, 0, 0, 0), cfg, counters)
            var v = self.sc.velocity(self.sc.bset.id_of(0))
            if not isfinite(v[0]):
                return (False, vmax)
            vmax = max(vmax, length(v))
        return (True, vmax)

    def vx(self) raises -> Real:
        return self.sc.velocity(self.sc.bset.id_of(0))[0]


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    c.iters = 4
    return c^


def main() raises:
    var s = Suite("fsi_added_mass")
    var cfg = _cfg()
    var plain = Run(0.5, Vec3(-0.05, 0, 0, 0), 0, False)
    var rp = plain.run(300, 0, cfg)
    var imp = Run(0.5, Vec3(-0.05, 0, 0, 0), 0, True)
    var ri = imp.run(300, 0, cfg)
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    print("  wall drag rho Z dx^3 / (rho V) per axis:", imp.port.zeta[0] * (1 / (RHO * vol)), " rotational / (0.4 rho V R^2):", imp.port.zeta_rot[0] * (1 / (0.4 * RHO * vol * R * R)))
    print("  ratio 0.5 at -0.05 m/s, 0.3 s: plain max |v|", rp[1], "finite", rp[0], ";  implicit: v", imp.vx(), "max |v|", ri[1])
    s.check(rp[1] > 1 or not rp[0], "plain exchange diverges at ratio 0.5")
    s.check(ri[0] and ri[1] <= 0.05 + 1e-9 and abs(imp.vx()) < 0.05, "implicit: finite and slowing")

    var h0 = Run(1.5, Vec3(0, 0, 0, 0), 9.8, False)
    _ = h0.run(400, 9.8, cfg)
    var h1 = Run(1.5, Vec3(0, 0, 0, 0), 9.8, True)
    _ = h1.run(400, 9.8, cfg)
    print("  ratio 1.5 settling 0.4 s: vx plain", h0.vx(), " implicit", h1.vx())
    s.check(abs(h1.vx() / h0.vx() - 1) < 0.05, "same settling velocity with and without (5 %)")

    var ok = True
    for ratio in [Real(0.2), Real(0.05)]:
        var l = Run(ratio, Vec3(-0.05, 0, 0, 0), 0, True)
        var rl = l.run(300, 0, cfg)
        print("  ratio", ratio, "implicit: v", l.vx(), "max |v|", rl[1], "finite", rl[0])
        ok = ok and rl[0] and rl[1] <= 0.05 + 1e-9 and abs(l.vx()) < 0.05
    s.check(ok, "ratios 0.2 and 0.05: finite and slowing")
    var z0 = Run(1.5, Vec3(0, 0, 0, 0), 9.8, False)
    var z1 = Run(1.5, Vec3(0, 0, 0, 0), 9.8, True)
    z1.port.set_implicit(False)
    _ = z0.run(50, 9.8, cfg)
    _ = z1.run(50, 9.8, cfg)
    s.check(z0.vx() == z1.vx(), "implicit off is the plain port")
    s.finish()
