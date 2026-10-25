# tier: integration
"""Snapshots of SPH <-> rigid and MPM <-> rigid runs (ROADMAP 17.59,
`sph_rigid_write` / `_read`, `mpm_rigid_write` / `_read`).

  1. Ordinary (SPH): a 0.15 m box dropped into a 320-particle tank, 300
     steps (in the water by then), snapshotted with the scene (`write_state`); a fluid, coupler and
     scene built the same way and restored continue 60 steps bit for bit
     with the original (every particle, the box pose).
  2. Integration (MPM): a box dropped onto an elastic block (432
     particles), 300 steps (on the block by then), same protocol: every
     particle and the box bit for bit.
  3. Extreme: restoring into a fluid with another particle count, or an
     MPM solver with no coupled body, raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6, write_state, read_state
from physics.solver_config import SolverConfig
from physics.pbf import PbfFluid
from physics.sph import box_floor_boundary
from physics.sph_rigid import SphRigidCoupler, sph_rigid_step, sph_rigid_write, sph_rigid_read
from physics.mpm import MpmSolver
from physics.mpm_rigid import MpmRigidCoupler, mpm_rigid_step, mpm_rigid_write, mpm_rigid_read
from physics.serialize import BinWriter, BinReader

comptime SP: Real = 0.05
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0


def cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    return c^


def tank(extra: Int = 0) -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.4, 0.6, 0.4, 0))
    f.calibrate(SP)
    for i in range(8):
        for j in range(5):
            for k in range(8):
                f.add(Vec3(0.025 + Real(i) * SP, 0.025 + Real(j) * SP, 0.025 + Real(k) * SP, 0))
    for e in range(extra):
        f.add(Vec3(0.2, 0.4 + Real(e) * 0.01, 0.2, 0))
    return f^


def sph_scene(mut sc: ContactScene6[QuatBody6], mut cp: SphRigidCoupler, f: PbfFluid) raises:
    _ = sc.add(QuatBody6.at_rest(Vec3(0.2, -0.05, 0.2, 0), Inertia3.box(1, 1, 0.05, 1)), Vec3(1, 0.05, 1, 0), True)
    var id = sc.add(QuatBody6.at_rest(Vec3(0.2, 0.4, 0.2, 0), Inertia3.box(1.5, 0.075, 0.075, 0.075)), Vec3(0.075, 0.075, 0.075, 0), False)
    _ = cp.add_box(id, Vec3(0.075, 0.075, 0.075, 0), SP * 0.5, f.rho0)


def block(mut m: MpmSolver):
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(12):
        for j in range(3):
            for k in range(12):
                m.add(Vec3(0.62 + Real(i) * sp, 0.215 + Real(j) * sp, 0.62 + Real(k) * sp, 0), vol * 1600.0, vol)


def mpm_scene(mut m: MpmSolver, mut sc: ContactScene6[QuatBody6], mut cp: MpmRigidCoupler) raises:
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, 0.2, 1.0, 0)), 0.6)
    block(m)
    var id = sc.add(QuatBody6.at_rest(Vec3(0.785, 0.45, 0.785, 0), Inertia3.box(2.0, 0.075, 0.075, 0.075)), Vec3(0.075, 0.075, 0.075, 0), False)
    _ = cp.add(m, sc, id, Sdf3.box(Vec3(0, 0, 0, 0), Vec3(0.075, 0.075, 0.075, 0)), 0.5)


def main() raises:
    var s = Suite("couple_snapshot")
    var c = cfg()

    var fa = tank()
    var floor = box_floor_boundary(fa.lo, fa.hi, SP, fa.rho0)
    var sa = ContactScene6[QuatBody6]()
    var ca = SphRigidCoupler(1000, fa.rho0)
    sph_scene(sa, ca, fa)
    for _ in range(300):
        sph_rigid_step(fa, floor, ca, sa, DT, G, c)
    var w = BinWriter()
    write_state(sa, w)
    sph_rigid_write(fa, ca, w)
    var r = BinReader(w.b.copy())
    var sb = ContactScene6[QuatBody6]()
    read_state(sb, r)
    var fb = tank()
    var cb = SphRigidCoupler(1000, fb.rho0)
    _ = cb.add_box(sb.bset.id_of(1), Vec3(0.075, 0.075, 0.075, 0), SP * 0.5, fb.rho0)
    sph_rigid_read(fb, cb, r)
    for _ in range(60):
        sph_rigid_step(fa, floor, ca, sa, DT, G, c)
        sph_rigid_step(fb, floor, cb, sb, DT, G, c)
    var same = True
    for i in range(fa.count()):
        same = same and fa.x[i] == fb.x[i] and fa.y[i] == fb.y[i] and fa.z[i] == fb.z[i] and fa.vy[i] == fb.vy[i]
    var ba = sa.bset.bodies[1].position()
    var bb = sb.bset.bodies[1].position()
    print("SPH: box y after 360 steps", ba[1], "restored", bb[1], " force", ca.force[0][1], cb.force[0][1])
    s.check(same and ba[0] == bb[0] and ba[1] == bb[1] and ba[2] == bb[2], "SPH <-> rigid: restored run == original, bit for bit")

    var ma = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 2.0e5, 0.3)
    var ra = ContactScene6[QuatBody6]()
    var pa = MpmRigidCoupler()
    mpm_scene(ma, ra, pa)
    for _ in range(300):
        mpm_rigid_step(ma, pa, ra, DT, G, c)
    var w2 = BinWriter()
    write_state(ra, w2)
    mpm_rigid_write(ma, w2)
    var r2 = BinReader(w2.b.copy())
    var rb = ContactScene6[QuatBody6]()
    read_state(rb, r2)
    var mb = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 2.0e5, 0.3)
    mb.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, 0.2, 1.0, 0)), 0.6)
    block(mb)
    var pb = MpmRigidCoupler()
    _ = pb.add(mb, rb, rb.bset.id_of(0), Sdf3.box(Vec3(0, 0, 0, 0), Vec3(0.075, 0.075, 0.075, 0)), 0.5)
    mpm_rigid_read(mb, r2)
    for _ in range(60):
        mpm_rigid_step(ma, pa, ra, DT, G, c)
        mpm_rigid_step(mb, pb, rb, DT, G, c)
    var same2 = True
    for k in range(len(ma.p)):
        same2 = same2 and ma.p[k].x[0] == mb.p[k].x[0] and ma.p[k].x[1] == mb.p[k].x[1] and ma.p[k].v[1] == mb.p[k].v[1]
    var qa = ra.bset.bodies[0].position()
    var qb = rb.bset.bodies[0].position()
    print("MPM: box y after 360 steps", qa[1], "restored", qb[1], " material force on it", ma.rigids[0].force[1])
    s.check(same2 and qa[1] == qb[1] and qa[0] == qb[0], "MPM <-> rigid: restored run == original, bit for bit")

    var raised = 0
    try:
        var r3 = BinReader(w.b.copy())
        var sc3 = ContactScene6[QuatBody6]()
        read_state(sc3, r3)
        var f3 = tank(5)
        var c3 = SphRigidCoupler(1000, f3.rho0)
        _ = c3.add_box(sc3.bset.id_of(1), Vec3(0.075, 0.075, 0.075, 0), SP * 0.5, f3.rho0)
        sph_rigid_read(f3, c3, r3)
    except:
        raised += 1
    try:
        var r4 = BinReader(w2.b.copy())
        var sc4 = ContactScene6[QuatBody6]()
        read_state(sc4, r4)
        var m4 = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 2.0e5, 0.3)
        block(m4)
        mpm_rigid_read(m4, r4)
    except:
        raised += 1
    s.check(raised == 2, "particle-count and coupled-body mismatches raise")
    s.finish()
