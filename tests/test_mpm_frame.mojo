# tier: unit
"""MPM stress frame (ROADMAP 17.58). The P2G scatter needs the Kirchhoff
stress tau = P F^T = 2 mu (F - R) F^T + lambda (J - 1) J I. Adding the
volumetric term to P's diagonal and multiplying by F^T afterwards gives
lambda (J - 1) J F^T instead, which is asymmetric once F carries a rotation,
so internal forces exert a net torque.

  1. A pre-strained block (F = 0.95 R, R a 90 degree turn about z; no
     gravity, nothing touching it) must not spin up: the angular momentum
     about its centre stays small against the same block with F = 0.95 I
     scaled by nothing -- the reference is zero, so the bound is absolute
     and compared with the linear-momentum scale of the breathing mode.
  2. The rotated and unrotated blocks breathe alike: kinetic energy after
     the same number of steps agrees.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 24
comptime DT: Real = 1.0 / 4000.0


def _block(f0_scale: Real, turn: Bool) -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(8):
        for j in range(8):
            for k in range(8):
                m.add(Vec3(0.4 + Real(i) * sp, 0.4 + Real(j) * sp, 0.4 + Real(k) * sp, 0), vol * 1600.0, vol)
    for pi in range(m.count()):
        var f = m.p[pi].f.copy()
        for a in range(3):
            for b in range(3):
                f.set(a, b, 0)
        if turn:
            f.set(0, 1, -f0_scale)
            f.set(1, 0, f0_scale)
            f.set(2, 2, f0_scale)
        else:
            f.set(0, 0, f0_scale)
            f.set(1, 1, f0_scale)
            f.set(2, 2, f0_scale)
        m.p[pi].f = f^
    return m^


def _lz_and_ke(m: MpmSolver) -> Tuple[Real, Real]:
    var cx = Real(0)
    var cy = Real(0)
    var mass = Real(0)
    for ref q in m.p:
        cx += q.x[0] * q.mass
        cy += q.x[1] * q.mass
        mass += q.mass
    cx /= mass
    cy /= mass
    var lz = Real(0)
    var ke = Real(0)
    for ref q in m.p:
        lz += q.mass * ((q.x[0] - cx) * q.v[1] - (q.x[1] - cy) * q.v[0])
        ke += 0.5 * q.mass * (q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2])
    return (lz, ke)


def main() raises:
    var s = Suite("mpm_frame")
    var g = Vec3(0, 0, 0, 0)
    var a = _block(0.95, False)
    var b = _block(0.95, True)
    for _ in range(40):
        a.step(DT, g)
        b.step(DT, g)
    var ra = _lz_and_ke(a)
    var rb = _lz_and_ke(b)
    print("  F = 0.95 I: L_z", ra[0], "KE", ra[1], "; F = 0.95 Rz(90): L_z", rb[0], "KE", rb[1])
    s.check(abs(rb[0]) < 0.01 * rb[1], "a rotated pre-strained block gets no net torque")
    s.check(abs(rb[1] - ra[1]) < 0.05 * ra[1], "rotated and unrotated blocks breathe alike")
    var c = _block(0.95, True)
    var d = _block(0.95, False)
    for _ in range(40):
        c.step_ext(DT, g)
        d.step_ext(DT, g)
    var rc = _lz_and_ke(c)
    var rd = _lz_and_ke(d)
    print("  step_ext: F = 0.95 I: L_z", rd[0], "KE", rd[1], "; F = 0.95 Rz(90): L_z", rc[0], "KE", rc[1])
    s.check(abs(rc[0]) < 0.01 * rc[1], "step_ext: no net torque either")
    s.check(abs(rc[1] - rd[1]) < 0.05 * rd[1], "step_ext: rotated and unrotated blocks breathe alike")
    s.finish()
