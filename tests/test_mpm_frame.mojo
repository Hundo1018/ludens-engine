# tier: unit
"""MPM stress frame (ROADMAP 17.58). The P2G scatter needs the Kirchhoff
stress tau = P F^T = 2 mu (F - R) F^T + lambda (J - 1) J I. Adding the
volumetric term to P's diagonal and multiplying by F^T afterwards gives
lambda (J - 1) J F^T instead, which is asymmetric once F carries a rotation,
so internal forces exert a net torque.

  1. A block pre-strained to F = 0.95 R (R a 90 degree turn about z; no
     gravity, nothing touching it) must not spin up: the angular momentum
     about its centre stays below 1 % of sum m |r - c| |v|, the value it
     would have if every particle moved around the centre. Measured after 40
     steps: |L_z| 4.9e-8 for the turned block, 2.5e-8 for F = 0.95 I; before
     the fix L_z was -1.90 for the turned block.
  2. The turned and unturned blocks breathe alike: kinetic energy after the
     same steps agrees within 5 % (measured 10.774613 and 10.774611; before
     the fix 19.47 and 10.80).
"""

from harness.runner import Suite
from std.math import sqrt
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


def _lz_and_ke(m: MpmSolver) -> Tuple[Real, Real, Real]:
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
    var scale = Real(0)
    for ref q in m.p:
        scale += q.mass * sqrt((q.x[0] - cx) * (q.x[0] - cx) + (q.x[1] - cy) * (q.x[1] - cy)) * sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1])
        lz += q.mass * ((q.x[0] - cx) * q.v[1] - (q.x[1] - cy) * q.v[0])
        ke += 0.5 * q.mass * (q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2])
    return (lz, ke, scale)


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
    s.check(abs(rb[0]) < 0.01 * rb[2], "a rotated pre-strained block gets no net torque")
    s.check(abs(rb[1] - ra[1]) < 0.05 * ra[1], "rotated and unrotated blocks breathe alike")
    var c = _block(0.95, True)
    var d = _block(0.95, False)
    for _ in range(40):
        c.step_ext(DT, g)
        d.step_ext(DT, g)
    var rc = _lz_and_ke(c)
    var rd = _lz_and_ke(d)
    print("  step_ext: F = 0.95 I: L_z", rd[0], "KE", rd[1], "; F = 0.95 Rz(90): L_z", rc[0], "KE", rc[1])
    s.check(abs(rc[0]) < 0.01 * rc[2], "step_ext: no net torque either")
    s.check(abs(rc[1] - rd[1]) < 0.05 * rd[1], "step_ext: rotated and unrotated blocks breathe alike")
    s.finish()
