"""ROADMAP 17.47: step cost by joint kind.

A hanging chain of 64 links (0.1 m boxes, 1 kg) under gravity, joined by
one kind throughout; 120 warm-up steps, then 60 timed, at iters 4 and 8.
`ball` is the 17.2 baseline (no ext pass runs); the others pay for the
ext pass (limits / cone / slider rows) on every joint.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.joints6 import Joint6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime N = 64
comptime STEPS = 60


def _chain(kind: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var prev = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), True)
    for k in range(N):
        var id = sc.add(QuatBody6.at_rest(Vec3(0, -0.1 * Real(k + 1), 0, 0), Inertia3.box(1, 0.04, 0.04, 0.04)), Vec3(0.04, 0.04, 0.04, 0), False)
        sc.set_can_sleep(id, False)
        var la = Vec3(0, -0.05, 0, 0)
        var lb = Vec3(0, 0.05, 0, 0)
        var j: Int
        match kind:
            case 0:
                j = sc.add_joint(Joint6.ball(prev.index(), id.index(), la, lb))
            case 1:
                j = sc.add_joint(Joint6.hinge(prev.index(), id.index(), la, lb, Vec3(0, 0, 1, 0)))
                sc.set_joint_limits(j, -0.3, 0.3)
            case 2:
                j = sc.add_joint(Joint6.cone_twist(prev.index(), id.index(), la, lb, Vec3(0, -1, 0, 0), Vec3(0, -1, 0, 0)))
                sc.set_cone_limit(j, 0.5)
                sc.set_joint_limits(j, -0.2, 0.2)
            case _:
                j = sc.add_joint(Joint6.slider(prev.index(), id.index(), la, lb, Vec3(0, -1, 0, 0)))
                sc.set_joint_limits(j, -0.02, 0.02)
        sc.set_collide_connected(j, False)
        prev = id
    # a sideways push so limits engage
    sc.bset.bodies[N].vel = Vec3(2, 0, 1, 0)
    return sc^


def main() raises:
    var t = BenchTable("Joint kinds (17.47): 64-link hanging chain, step cost")
    var names: List[String] = ["ball (no ext pass)", "hinge + limit", "cone-twist + cone + twist", "slider + travel"]
    for iters in [4, 8]:
        for kind in range(4):
            var sc = _chain(kind)
            var cfg = SolverConfig()
            cfg.iters = iters
            for _ in range(120):
                sc.step(DT, G, cfg)
            var t0 = Int(perf_counter_ns())
            for _ in range(STEPS):
                sc.step(DT, G, cfg)
            t.add(names[kind] + ", iters " + String(iters), N, "step", Int(perf_counter_ns()) - t0, STEPS)
    t.print_report()
