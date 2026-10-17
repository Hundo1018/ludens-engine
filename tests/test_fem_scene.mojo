# tier: integration
"""FEM bodies in the rigid scene (ROADMAP 17.58, `physics.fem_scene`
`FemContactPort` with `couple_step`).

  1. Ordinary: a 50 kg box (0.4 m) dropped onto a 0.6 x 0.4 x 0.6 m block
     (E = 3e5, explicit FEM, `fem_coupled_step` with 16 substeps) on a
     static floor: for 3 s the box stays on the block (its bottom never
     more than 1 cm below the highest node under it, printed), drifts less
     than 5 cm sideways, and no node is below the floor or inside the box.
     The residual vertical bounce in the last second is printed (an
     undamped ~8 Hz mode of the position-level contact; not at rest).
  2. Integration: in zero gravity with no damping, a 1 kg sphere at 2 m/s
     hits a free FEM block (explicit, 16 substeps): the total momentum (sphere + nodes) is the same
     after 1 s (0.5 %) while the block has picked some up (> 0.2 kg m/s).
     The FEM state survives `write_state` / `read_state` with the scene
     snapshot: 30 more steps from the restored copy match bit for bit.
  3. Extreme: radius 0 and mu < 0 raise; an all-pinned block inside a box
     moves no node and pushes nothing.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fem import FemBody, make_beam
from physics.continuum import FemContinuum
from physics.coupling import couple_step
from physics.fem_scene import FemContactPort, fem_coupled_step
from physics.serialize import scene_to_bytes, scene_from_bytes, BinWriter, BinReader
from diag.counters import Counters

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _block(origin: Vec3, damping: Real) -> FemBody:
    var b = FemBody(3.0e5, 0.3, damping)
    make_beam(b, 6, 4, 6, 0.1, 0.3)
    for i in range(b.node_count()):
        b.x[i] += origin[0]
        b.y[i] += origin[1]
        b.z[i] += origin[2]
    return b^


def _p(sc2: ContactScene6[QuatBody6], f: FemContinuum, b: Int) -> Vec3:
    """Total momentum: body `b` (1 kg) plus every node."""
    var p = sc2.bset.bodies[b].vel * Real(1)
    for i in range(f.body.node_count()):
        var m = 1 / f.body.inv_m[i]
        p = p + Vec3(f.body.vx[i], f.body.vy[i], f.body.vz[i], 0) * m
    return p


def main() raises:
    var s = Suite("fem_scene")
    var cfg = SolverConfig()
    var counters = Counters()

    # ---- box on a rubber block ----------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    var box = sc.add(QuatBody6.at_rest(Vec3(0.3, 0.65, 0.3, 0), Inertia3.box(50, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_sleep_thresholds(box, 0, 0)
    var fem = FemContinuum(_block(Vec3(0, 0.02, 0, 0), 4.0))
    var port = FemContactPort(0.02, 0.5)
    var worst_sink = Real(-1e30)
    var bounce = Real(0)
    var low = Real(1e30)
    var inside = 0
    for k in range(180):
        fem_coupled_step(sc, port, fem, DT, G, cfg, counters, 16)
        ref bx = sc.bset.bodies[box.index()]
        var under = Real(-1e30)
        for i in range(fem.body.node_count()):
            var lp = bx.to_local(Vec3(fem.body.x[i], fem.body.y[i], fem.body.z[i], 0))
            if abs(lp[0]) < 0.2 and abs(lp[2]) < 0.2:
                under = max(under, fem.body.y[i] + 0.02)
            if k == 179:
                low = min(low, fem.body.y[i])
                if abs(lp[0]) < 0.19 and abs(lp[1]) < 0.19 and abs(lp[2]) < 0.19:
                    inside += 1
        worst_sink = max(worst_sink, under - (bx.pos[1] - 0.2))
        if k >= 120:
            bounce = max(bounce, abs(bx.vel[1]))
    ref bf = sc.bset.bodies[box.index()]
    var drift = length(Vec3(bf.pos[0] - 0.3, 0, bf.pos[2] - 0.3, 0))
    print("  50 kg box on the block, 3 s: deepest the box bottom went below the nodes under it", worst_sink, "m;  sideways drift", drift, "m;  box y", bf.pos[1], ";  last-second bounce |vy| up to", bounce, "m/s")
    s.check(worst_sink < 0.01 and drift < 0.05 and bf.pos[1] > 0.6, "the block holds the box up (bottom within 1 cm of the node tops), drift < 5 cm")
    s.check(low > 0.0 and inside == 0, "no node below the floor or inside the box")

    # ---- momentum in zero gravity -----------------------------------------------------------------------
    var zc = ContactScene6[QuatBody6]()
    var ball = zc.add_sphere(QuatBody6.at_rest(Vec3(-0.6, 0.2, 0.2, 0), Inertia3.sphere(1, 0.15)), 0.15, False)
    zc.set_velocity(ball, Vec3(2, 0, 0, 0), ZERO)
    zc.set_sleep_thresholds(ball, 0, 0)
    var zf = FemContinuum(_block(ZERO, 0.0))
    var zp = FemContactPort(0.02, 0.0)

    var p0 = _p(zc, zf, ball.index())
    var snap = List[UInt8]()
    var fsnap = List[UInt8]()
    for k in range(60):
        fem_coupled_step(zc, zp, zf, DT, ZERO, cfg, counters, 16)
        if k == 29:
            snap = scene_to_bytes(zc)
            var w = BinWriter()
            zf.write_state(w)
            fsnap = w.b.copy()
    var p1 = _p(zc, zf, ball.index())
    var block_p = p1 - zc.bset.bodies[ball.index()].vel
    print("  zero g: momentum before", p0, " after", p1, ";  block now carries", block_p, " ball vx", zc.bset.bodies[ball.index()].vel[0])
    s.check(length(p1 - p0) <= 0.005 * length(p0) and block_p[0] > 0.2, "momentum is exchanged, not created")

    var rc = scene_from_bytes(snap^)
    var rf = FemContinuum(_block(ZERO, 0.0))
    var rd = BinReader(fsnap^)
    rf.read_state(rd)
    var rp = FemContactPort(0.02, 0.0)
    for _ in range(30):
        fem_coupled_step(rc, rp, rf, DT, ZERO, cfg, counters, 16)
    var same = rc.bset.bodies[ball.index()].pos[0] == zc.bset.bodies[ball.index()].pos[0]
    for i in range(zf.body.node_count()):
        same = same and rf.body.x[i] == zf.body.x[i] and rf.body.vy[i] == zf.body.vy[i]
    s.check(same, "snapshot of scene + FEM state: 30 more steps bit for bit")

    # ---- extremes ---------------------------------------------------------------------------------------
    var raised = 0
    try:
        _ = FemContactPort(0, 0.5)
    except:
        raised += 1
    try:
        _ = FemContactPort(0.02, -1)
    except:
        raised += 1
    s.check(raised == 2, "radius 0 and mu < 0 raise")
    var pc = ContactScene6[QuatBody6]()
    var big = pc.add(QuatBody6.at_rest(Vec3(0.2, 0.2, 0.2, 0), Inertia3.box(5, 1, 1, 1)), Vec3(1, 1, 1, 0), False)
    var pf = FemContinuum(_block(ZERO, 0.0))
    for i in range(pf.body.node_count()):
        pf.body.pin(i)
    var pp = FemContactPort(0.02)
    var x0 = pf.body.x[5]
    _ = couple_step(pc, pp, pf, DT, ZERO, cfg, counters)
    s.check(pf.body.x[5] == x0 and pp.contacts == 0 and length(pc.bset.bodies[big.index()].vel) == 0, "pinned nodes neither move nor push")
    s.finish()
