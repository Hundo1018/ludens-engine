"""Experiment — energy budget of the MPM Drucker-Prager sand column (ROADMAP 17.58).

The column of `tests/test_mpm_sand.mojo` (0.24 x 0.42 x 0.24 m, 8 x 14 x 8
particles at spacing 0.03, obstacle floor mu 0.6, 0.3 s) is run at friction
angles 30, 60 and 85 degrees with `measure_loss` on. At rest the budget is

    E0 = sum m g y0                     (F = I, so no elastic energy)
    E  = sum (1/2) m v^2 + sum vol psi(F) + sum m g y

and the total energy lost to every sink is Q = E0 - E. The return map removes
`sand_loss` = sum vol (psi before - psi after) at each projection; the rest,
Q - sand_loss, is floor friction, obstacle push-out and the particle-grid
transfer. psi is the fixed-corotated energy whose stress step_ext scatters.
The 0 degree row is the control: no sand, so sand_loss is 0 and Q is all
friction, push-out and transfer.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime FLOOR: Real = 0.2
comptime STEPS = 600


def _block(mut m: MpmSolver, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int):
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0), vol * 1600.0, vol)


def _run(phi: Real) raises -> Tuple[Real, Real, Real, Real, Real]:
    """(E0, KE, elastic, gravitational PE, sand_loss) after STEPS steps."""
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), 0.6)
    if phi > 0:
        m.set_sand(phi)
    m.measure_loss = True
    _block(m, 0.68, FLOOR + 0.015, 0.68, 8, 14, 8)
    var e0 = Real(0)
    for ref q in m.p:
        e0 += q.mass * 9.8 * q.x[1]
    for _ in range(STEPS):
        m.step_ext(DT, G)
    var ke = Real(0)
    var el = Real(0)
    var pe = Real(0)
    for ref q in m.p:
        ke += 0.5 * q.mass * (q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2])
        el += q.vol * m.elastic_energy(q.f)
        pe += q.mass * 9.8 * q.x[1]
    return (e0, ke, el, pe, m.sand_loss)


def main() raises:
    var s = Suite("exp_sand_budget")
    for phi in [Real(0), Real(30), Real(60), Real(85)]:
        var r = _run(phi)
        var e0 = r[0]
        var ke = r[1]
        var el = r[2]
        var pe = r[3]
        var loss = r[4]
        var q = e0 - (ke + el + pe)
        print(
            "  friction", phi, "deg: E0", e0, "KE", ke, "elastic", el, "PE", pe,
            "| lost Q", q, "| return map", loss, "| rest (friction, transfer)", q - loss,
        )
        s.check(q >= 0 and loss >= 0, "phi " + String(phi) + ": energy is lost and the return map removes some of it")
    s.finish()
