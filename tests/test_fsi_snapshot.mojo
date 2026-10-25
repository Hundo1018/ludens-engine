# tier: integration
"""Snapshot of a coupled LBM <-> rigid run (ROADMAP 17.59, `lbm_write` /
`lbm_read`, `lbm_continuum_write` / `_read`, `sphere_port_write` / `_read`
in `physics.fsi`).

  1. Ordinary: a sphere (density ratio 0.5, implicit wall drag) launched
     through a 24^3 lattice for 0.1 s, then snapshotted with the scene
     (`write_state`), the continuum and the port (its measured wall drag
     and mode: the restored port is built without `set_implicit`); a
     scene, lattice and port built the same way and restored from it
     continue 100 steps bit for bit with
     the original (body pose and velocity, every population).
  2. Integration: a snapshot taken with the sphere's unwrapped centre
     outside the grid (x > 24 mm, periodic) restores the same way.
  3. Extreme: restoring into a lattice of another size, or with another
     number of moving spheres, raises.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6, write_state, read_state
from physics.solver_config import SolverConfig
from physics.continuum import LbmContinuum
from physics.coupling import couple_step
from physics.fsi import LbmSpherePort, lbm_continuum_write, lbm_continuum_read, sphere_port_write, sphere_port_read
from physics.serialize import BinWriter, BinReader
from diag.counters import Counters
from fluid.lbm import Lbm

comptime DX: Real = 1e-3
comptime DT: Real = 1e-3
comptime R: Real = 3e-3


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    c.iters = 4
    return c^


def _lattice() -> Lbm:
    var l = Lbm(24, 24, 24, 0.16)
    l.init_uniform(1, 0, 0, 0)
    return l^


def _run(x0: Real, before: Int, after: Int) raises -> Bool:
    var cfg = _cfg()
    var counters = Counters()
    var sa = ContactScene6[QuatBody6]()
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    var b = QuatBody6.at_rest(Vec3(x0, 11.5e-3, 11.5e-3, 0), Inertia3.sphere(0.5 * 1000 * vol, R))
    b.vel = Vec3(0.05, 0.01, 0, 0)
    _ = sa.add_sphere(b^, R, False)
    var ca = LbmContinuum(_lattice(), DT)
    var pa = LbmSpherePort(DX, 1000, Vec3(0, 0, 0, 0))
    pa.set_implicit(True)
    _ = pa.add_sphere(sa, ca, sa.bset.id_of(0), R)
    for _ in range(before):
        _ = couple_step(sa, pa, ca, DT, Vec3(0, 0, 0, 0), cfg, counters)
    var x_snap = sa.bset.bodies[0].pos[0]
    var w = BinWriter()
    write_state(sa, w)
    lbm_continuum_write(ca, w)
    sphere_port_write(pa, w)

    var r = BinReader(w.b.copy())
    var sb = ContactScene6[QuatBody6]()
    read_state(sb, r)
    var cb = LbmContinuum(_lattice(), DT)
    var pb = LbmSpherePort(DX, 1000, Vec3(0, 0, 0, 0))
    _ = pb.add_sphere(sb, cb, sb.bset.id_of(0), R)
    lbm_continuum_read(cb, r)
    sphere_port_read(pb, r)

    for _ in range(after):
        _ = couple_step(sa, pa, ca, DT, Vec3(0, 0, 0, 0), cfg, counters)
        _ = couple_step(sb, pb, cb, DT, Vec3(0, 0, 0, 0), cfg, counters)
    var ba = sa.bset.bodies[0]
    var bb = sb.bset.bodies[0]
    var same = ba.pos == bb.pos and ba.vel == bb.vel and ba.omega == bb.omega
    for i in range(len(ca.lbm.f)):
        same = same and ca.lbm.f[i] == cb.lbm.f[i]
    print("  snapshot with the sphere at x", x_snap, "m (grid: 0 .. 0.024), +", after, "steps: sphere x", ba.pos[0], bb.pos[0], " same", same)
    return same


def main() raises:
    var s = Suite("fsi_snapshot")
    s.check(_run(11.5e-3, 100, 100), "restored coupled run continues bit for bit")
    s.check(_run(24.5e-3, 80, 100), "restored with the centre outside the grid (periodic), bit for bit")

    var raised = 0
    var w = BinWriter()
    var c = LbmContinuum(_lattice(), DT)
    lbm_continuum_write(c, w)
    var r1 = BinReader(w.b.copy())
    var small = LbmContinuum(Lbm(12, 12, 12, 0.16), DT)
    try:
        lbm_continuum_read(small, r1)
    except:
        raised += 1
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_sphere(QuatBody6.at_rest(Vec3(11.5e-3, 11.5e-3, 11.5e-3, 0), Inertia3.sphere(1e-4, R)), R, False)
    var with_sphere = LbmContinuum(_lattice(), DT)
    var p = LbmSpherePort(DX, 1000, Vec3(0, 0, 0, 0))
    _ = p.add_sphere(sc, with_sphere, sc.bset.id_of(0), R)
    var w2 = BinWriter()
    lbm_continuum_write(with_sphere, w2)
    var r2 = BinReader(w2.b.copy())
    var plain = LbmContinuum(_lattice(), DT)
    plain.lbm.set_wall_velocity(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    try:
        lbm_continuum_read(plain, r2)
    except:
        raised += 1
    s.check(raised == 2, "another size or sphere count raises")
    s.finish()
