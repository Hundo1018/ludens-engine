# tier: integration
"""Node CCD for FEM in the scene (ROADMAP 17.58, `FemContactPort.ccd`).

A 2 x 2 x 2-cell FEM block (h = 0.05, E = 1e5, explicit) fired down at
a static 4 mm plate, node radius 5 mm, two contact passes per 1/60 s frame
(the overlap band is 14 mm thick):

  1. Ordinary: 9 free nodes (no tets) at 30 m/s: without CCD all end below
     the plate, with CCD all land on it (at plate top + radius, 0.2 mm).
  2. Integration: the 2 x 2 x 2 block at 3 m/s (0.025 m per pass, more than
     the band): without CCD every node ends below the plate; with CCD none,
     and the block rests on it intact (top above 9 cm). Measured: at 7 m/s
     the explicit FEM itself blows up on impact, CCD or not.
  3. Extreme: a block resting on the plate with CCD stays on it for 1 s.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fem import FemBody, make_beam
from physics.continuum import FemContinuum
from physics.fem_scene import FemContactPort, fem_coupled_step
from diag.counters import Counters

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime R: Real = 0.005
comptime HALF: Real = 0.002


def block(y: Real, vy: Real, tets: Bool = True) -> FemBody:
    var b = FemBody(1.0e5, 0.3, 4.0)
    if tets:
        make_beam(b, 2, 2, 2, 0.05, 0.02)
    else:  # free nodes: the sweep without elasticity
        for i in range(3):
            for k in range(3):
                b.add_node(Vec3(Real(i) * 0.05, 0, Real(k) * 0.05, 0), 0.02)
    for i in range(b.node_count()):
        b.y[i] += y
        b.vy[i] = vy
    return b^


def lowest(f: FemContinuum) -> Real:
    var lo = Real(1e30)
    for i in range(f.body.node_count()):
        lo = min(lo, f.body.y[i])
    return lo


def run(ccd: Bool, y: Real, vy: Real, frames: Int, mut swept: Int, tets: Bool = True) raises -> FemContinuum:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, HALF, 1)), Vec3(1, HALF, 1, 0), True)
    var fem = FemContinuum(block(y, vy, tets), -1e30, False, 32)
    var port = FemContactPort(R, 0.5, ccd)
    var cfg = SolverConfig()
    var counters = Counters()
    swept = 0
    for _ in range(frames):
        fem_coupled_step(sc, port, fem, DT, G, cfg, counters, 2)
        swept += port.swept

    return fem^


def highest(f: FemContinuum) -> Real:
    var hi = Real(-1e30)
    for i in range(f.body.node_count()):
        hi = max(hi, f.body.y[i])
    return hi


def below(f: FemContinuum) -> Int:
    var k = 0
    for i in range(f.body.node_count()):
        if f.body.y[i] < -HALF:
            k += 1
    return k


def main() raises:
    var s = Suite("fem_ccd")
    var s0 = 0
    var s1 = 0
    var p0 = run(False, 0.3, -30, 30, s0, False)
    var p1 = run(True, 0.3, -30, 30, s1, False)
    print("free nodes at 30 m/s: below the plate without CCD", below(p0), "of 9 ;  with CCD", below(p1), " resting at", lowest(p1), highest(p1), " swept", s1)
    s.check(below(p0) == 9 and below(p1) == 0 and abs(lowest(p1) - (HALF + R)) < 2e-4 and abs(highest(p1) - (HALF + R)) < 2e-4, "free nodes: tunnel without CCD; with CCD they land on the plate")

    var sa = 0
    var sb = 0
    var a = run(False, 0.3, -3, 60, sa)
    var b = run(True, 0.3, -3, 60, sb)
    print("block at 3 m/s: nodes below the plate without CCD", below(a), "of", a.body.node_count(), ";  with CCD", below(b), " swept", sb, " lowest", lowest(b), " top", highest(b))
    s.check(below(a) == a.body.node_count() and below(b) == 0, "block: every node tunnels without CCD; none with CCD")
    s.check(sb > 0 and abs(lowest(b) - (HALF + R)) < 1e-3 and highest(b) > 0.09, "the block rests on the plate, intact (top above 9 cm)")

    var sd = 0
    var d = run(True, HALF + R + 1e-4, 0, 60, sd)
    print("resting block with CCD: lowest", lowest(d), " top", highest(d), " swept", sd)
    s.check(lowest(d) > HALF + R - 1e-3 and highest(d) > 0.09, "a resting block with CCD stays on the plate")
    s.finish()
