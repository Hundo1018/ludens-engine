# tier: integration
"""Degradation matrix: one worker (ROADMAP 17.76).

A host that gives the engine a single thread must get the same simulation
as one that gives it a pool. 40 two-box stacks (40 islands) stepped 120
ticks, snapshots (`scene_to_bytes`) compared:

  1. island fan-out (`parallel`) with `workers = 1` == with the default
     width == serially dispatched;
  2. same-colour fan-out (`colored`) with `workers = 1` == the plain serial
     step;
  3. parallel narrowphase (`parallel_collision`) with `workers = 1` == the
     serial narrowphase.

The other two rows of the matrix have nothing to compare on this engine:
there is no automatic GPU -> CPU switch (GPU solvers are explicit types a
host picks, and `has_accelerator()` hosts skip them), and SIMD width is not
a knob (`PadW` is fixed per dimension; the 17.76 fp probe found SIMD width
does not change results across x86-64 targets, only FMA contraction does).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.serialize import scene_to_bytes
from scheduler.dispatch import Dispatch

comptime DT: Real = 1.0 / 60.0


def run(cfg: SolverConfig) raises -> List[UInt8]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(40, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 5)), Vec3(50, 0.5, 5, 0), True)
    for k in range(40):
        for j in range(2):
            var id = sc.add(
                QuatBody6.at_rest(Vec3(Real(k) * 2, 0.25 + 0.51 * Real(j), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
                Vec3(0.25, 0.25, 0.25, 0), False,
            )
            sc.set_velocity(id, Vec3(0.1 * Real(k % 3), 0, 0, 0), Vec3(0, 0, 0, 0))
    for _ in range(120):
        sc.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    return scene_to_bytes(sc)


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def main() raises:
    var s = Suite("degrade")
    var base = SolverConfig()
    base.broadphase = True
    var serial = run(base)

    var isl = base
    isl.parallel = True
    var isl_default = run(isl)
    isl.workers = 1
    var isl_one = run(isl)
    isl.workers = 0
    isl.dispatch = Dispatch.serial()
    var isl_serial = run(isl)
    s.check(same(isl_one, isl_default) and same(isl_one, isl_serial), "island fan-out: 1 worker == pool == serial dispatch")

    var col = base
    col.colored = True
    col.parallel = True
    col.workers = 1
    s.check(same(run(col), serial), "same-colour fan-out with 1 worker == plain serial step")

    var pc = base
    pc.parallel_collision = True
    pc.workers = 1
    s.check(same(run(pc), serial), "parallel narrowphase with 1 worker == serial narrowphase")
    print("degrade: 40 islands x 120 ticks, snapshot bytes", len(serial))
    s.finish()
