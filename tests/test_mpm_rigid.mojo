# tier: integration
"""MPM <-> rigid body two-way coupling (ROADMAP 17.59, `physics.mpm_rigid`,
`MpmSolver.rigids`). Units as test_mpm_sand: dx 5 cm, 32^3 grid,
dt 1/2000 s, E 2e5, particle density 1600.

  1. Ordinary: a 0.15 m box of density 1000 dropped onto an elastic block
     resting on an obstacle floor comes to rest on it: after 1 s it is
     still (|v| < 2 cm/s), its bottom within one cell of the block's top
     beside it (4.2 cm measured: contact is decided at grid nodes, so a
     body rests about a cell above the material), the grid force on it
     equal to its weight within 10 % (1.001 measured), and no particle more
     than half a cell inside it.
  2. Integration: without gravity a rigid sphere (1 kg, 1 m/s) runs into a
     free block (16.6 kg): material + body momentum is the same after
     0.25 s (1e-3 of the initial; 1.4e-6 measured), the sphere slows (it
     bounces back at -0.15 m/s) and the block moves.
  3. Extreme: mu < 0 raises; with no coupled body `step_ext` is unchanged
     (test_mpm_sand's golden section stays bit for bit).
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.sdf3 import Sdf3
from physics.mpm import MpmSolver
from physics.mpm_rigid import MpmRigidCoupler, mpm_rigid_step
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DX: Real = 0.05
comptime N = 32
comptime DT: Real = 1.0 / 2000.0
comptime FLOOR: Real = 0.2


def _block(mut m: MpmSolver, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int):
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0), vol * 1600.0, vol)


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    return c^


def main() raises:
    var s = Suite("mpm_rigid")
    var cfg = _cfg()
    var g = Vec3(0, -9.8, 0, 0)

    # ---- box resting on an elastic block --------------------------------------------------------
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), 0.6)
    _block(m, 0.62, FLOOR + 0.015, 0.62, 12, 6, 12)
    var sc = ContactScene6[QuatBody6]()
    var cp = MpmRigidCoupler()
    for _ in range(400):
        mpm_rigid_step(m, cp, sc, DT, g, cfg)
    var top = Real(-1e30)
    for ref q in m.p:
        top = max(top, q.x[1])
    var half = Real(0.075)
    var mass = 1000 * (2 * half) ** 3
    var id = sc.add(QuatBody6.at_rest(Vec3(0.785, top + half + 0.05, 0.785, 0), Inertia3.box(mass, half, half, half)), Vec3(half, half, half, 0), False)
    _ = cp.add(m, sc, id, Sdf3.box(Vec3(0, 0, 0, 0), Vec3(half, half, half, 0)), 0.5)
    var fsum = Real(0)
    for k in range(2000):
        mpm_rigid_step(m, cp, sc, DT, g, cfg)
        if k >= 1600:
            fsum += m.rigids[0].force[1]
    var top2 = Real(-1e30)
    var deep = 0
    var box = sc.pose(id)
    for ref q in m.p:
        var lp = box.rot.conjugate().rotate(q.x - box.pos)
        if abs(lp[0]) < half and abs(lp[2]) < half:
            continue
        top2 = max(top2, q.x[1])
    for ref q in m.p:
        var lp = box.rot.conjugate().rotate(q.x - box.pos)
        if abs(lp[0]) < half - 0.5 * DX and abs(lp[1]) < half - 0.5 * DX and abs(lp[2]) < half - 0.5 * DX:
            deep += 1
    var fmean = fsum / 400
    var v = length(sc.velocity(id))
    print("  box (", mass, "kg) on the block after 1 s: bottom", box.pos[1] - half, " block top beside it", top2, " speed", v, " grid force", fmean, " weight", mass * 9.8, " particles inside", deep)
    s.check(v < 0.02 and abs(box.pos[1] - half - top2) < DX, "the box comes to rest on the block")
    s.check(abs(fmean / (mass * 9.8) - 1) < 0.1, "the block carries the box's weight (10 %)")
    s.check(deep == 0, "no particle inside the box")

    # ---- momentum exchange ----------------------------------------------------------------------
    var m2 = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _block(m2, 0.75, 0.7, 0.7, 6, 8, 8)
    var sc2 = ContactScene6[QuatBody6]()
    var cp2 = MpmRigidCoupler()
    var r = Real(0.08)
    var id2 = sc2.add_sphere(QuatBody6.at_rest(Vec3(0.55, 0.805, 0.805, 0), Inertia3.sphere(1, r)), r, False)
    sc2.bset.bodies[id2.index()].vel = Vec3(1, 0, 0, 0)
    _ = cp2.add(m2, sc2, id2, Sdf3.sphere(Vec3(0, 0, 0, 0), r), 0)
    var p0 = m2.total_momentum() + sc2.velocity(id2)
    for _ in range(500):
        mpm_rigid_step(m2, cp2, sc2, DT, Vec3(0, 0, 0, 0), cfg)
    var p1 = m2.total_momentum() + sc2.velocity(id2)
    print("  sphere into a free block: momentum before", p0, " after", p1, " sphere vx", sc2.velocity(id2)[0], " block px", m2.total_momentum()[0], " block mass", m2.total_mass())
    s.check(length(p1 - p0) < 1e-3 * length(p0), "material + body momentum is conserved")
    s.check(sc2.velocity(id2)[0] < 0.9 and m2.total_momentum()[0] > 0.1, "the sphere slows, the block moves")

    var raised = 0
    try:
        var cp3 = MpmRigidCoupler()
        _ = cp3.add(m2, sc2, id2, Sdf3.sphere(Vec3(0, 0, 0, 0), r), -1)
    except:
        raised += 1
    s.check(raised == 1, "mu < 0 raises")
    s.finish()
