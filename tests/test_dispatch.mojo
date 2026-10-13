# tier: integration
"""Injectable parallel-for (ROADMAP 17.75): who runs the fan-outs does not
change the result.

A scene of 40 separate two-box stacks (40 islands), stepped 120 ticks with
`cfg.parallel = True` (island fan-out) and again with `cfg.colored = True`
(same-colour pair fan-out), under each dispatcher: the runtime pool,
serial, reversed order, the work-stealing pool, and a host function called through the C ABI that
runs the items last to first. Every run's exact snapshot
(`scene_to_bytes`) must be equal: island runs to the island path dispatched
serially (the island schedule itself differs from the global sweep), colour
runs to the plain serial `cfg.parallel = False` step.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.serialize import scene_to_bytes
from scheduler.dispatch import Dispatch, Opaque, TaskFn

comptime DT: Real = 1.0 / 60.0


def host_reverse(ctx: Optional[Opaque], n: Int64, task: TaskFn, data: Opaque) abi("C"):
    """A stand-in host job system: runs every item, last to first."""
    var i = Int(n) - 1
    while i >= 0:
        task(data, Int64(i))
        i -= 1


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


def main() raises:
    var s = Suite("dispatch")
    var base_cfg = SolverConfig()
    base_cfg.broadphase = True
    var reference = run(base_cfg)
    var names = List[String]()
    names.append("parallel")
    names.append("serial")
    names.append("reverse")
    names.append("host (C ABI, reversed)")
    names.append("work stealing")
    for mode in range(2):
        var island_ref = List[UInt8]()
        for k in [1, 0, 2, 3, 4]:
            var cfg = SolverConfig()
            cfg.broadphase = True
            if mode == 0:
                cfg.parallel = True
            else:
                cfg.colored = True
                cfg.parallel = True
            if k == 0:
                cfg.dispatch = Dispatch.parallel()
            elif k == 1:
                cfg.dispatch = Dispatch.serial()
            elif k == 2:
                cfg.dispatch = Dispatch.reverse()
            elif k == 3:
                cfg.dispatch = Dispatch.from_host(host_reverse, None)
            else:
                cfg.dispatch = Dispatch.work_stealing()
            var got = run(cfg)
            if mode == 0 and k == 1:
                island_ref = got.copy()
            var want = island_ref.copy() if mode == 0 else reference.copy()
            var same = len(got) == len(want)
            if same:
                for i in range(len(got)):
                    if got[i] != want[i]:
                        same = False
                        break
            var path = "island fan-out" if mode == 0 else "colour fan-out"
            s.check(same, path + " under " + names[k] + " dispatch == " + ("serially dispatched islands" if mode == 0 else "the plain serial step") + " (snapshot bytes)")
    s.finish()
