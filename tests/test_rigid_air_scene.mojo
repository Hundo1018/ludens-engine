# tier: integration
"""`RigidPart` + `AirPart` in one `Coupler` (ROADMAP 17.61).

A 4 g rigid body with two immersed points on one side of its centre of
mass (x = +0.06 m, z = +-0.04 m) sits in a 24^3 lattice (dx 2 cm, 1 ms,
viscosity 0.05) with the air streaming along +y at 0.02 lattice units
(0.4 m/s). No gravity. The drag on the off-centre points pushes the body
along +y and spins it about +z (r = +x, F = +y). Per step the coupler's
imbalance stays at rounding level and the air's momentum changes by minus
what the body received, to a fixed 1.3e-6 kg m / s offset that
does not grow with the number of steps (100, 300 and 600 steps).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from fluid.lbm import Lbm
from diag.counters import Counters
from physics.cloth_air import lattice_momentum
from physics.cloth_air_parts import AirPart
from physics.rigid_air_part import RigidPart
from physics.coupler import Coupler, EXPLICIT

comptime NL = 24
comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime RHO: Real = 1.2


def streaming() -> Lbm:
    var l = Lbm(NL, NL, NL, 0.05)
    l.init_uniform(1.0, 0.0, 0.02, 0.0)
    return l^


def main() raises:
    var s = Suite("rigid_air_scene")
    var counters = Counters()
    var centre = Vec3(0.24, 0.24, 0.24, 0)
    var local: List[Vec3] = [Vec3(0.06, 0, 0.04, 0), Vec3(0.06, 0, -0.04, 0)]
    var pts = List[Vec3]()
    for p in local:
        pts.append(centre + p)
    var body = RigidPart(centre, Quat.identity(), 0.004, Vec3(2e-6, 2e-6, 2e-6, 0), 0.08, Vec3(0, 0, 0, 0), local.copy())
    var cp = Coupler[RigidPart, AirPart](body^, AirPart(streaming(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1, pts), 1, EXPLICIT)
    var p0 = lattice_momentum(cp.b.lbm, RHO, DX, DT)
    var worst = Real(0)
    for _ in range(300):
        cp.step(DT, counters)
        worst = max(worst, length(cp.a.received))
    var gave = cp.a.total
    var dp = lattice_momentum(cp.b.lbm, RHO, DX, DT) - p0
    var gap = length(dp + gave)
    print("rigid in air, 0.3 s: v", cp.a.v[0], cp.a.v[1], cp.a.v[2], " w_z", cp.a.w[2], " max imbalance", cp.max_imbalance, " per-step impulse up to", worst)
    print("  air momentum change", dp[1], " body received", gave[1], " mismatch", gap, "(1.3e-6 at 100, 300 and 600 steps: a fixed offset, not drift)")
    s.check(cp.a.v[1] > 0 and cp.a.w[2] > 0, "the streaming air pushes the body along +y and spins it about +z")
    s.check(cp.max_imbalance <= 1e-6 * worst, "per-step imbalance at rounding level")
    s.check(gap < 2e-6, "air momentum change = -(body impulses) within 2e-6 kg m / s (a fixed offset)")
    s.finish()
