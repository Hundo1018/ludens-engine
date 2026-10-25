"""Steady-state allocation probe (ROADMAP 17.79), driven by
`scripts/alloc_probe.py` under an LD_PRELOAD malloc counter.

Each scene is warmed up, then `MARKS` markers are dropped around a fixed
number of steps; a marker is a `sched_yield` call, which the counter shim
intercepts to print the number of allocations so far. The driver turns
consecutive marks into allocations per step.
"""

from std.ffi import external_call
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime WARM = 60
comptime STEPS = 30


def mark(name: StringLiteral):
    print("SCENE", name, flush=True)
    _ = external_call["sched_yield", Int32]()


def pile(n: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 30, 0.5, 30)), Vec3(30, 0.5, 30, 0), True)
    for k in range(n):
        var id = sc.add(QuatBody6.at_rest(Vec3(Real(k % 10) * 1.2 - 6, 0.25 + 0.5 * Real(k // 100), Real((k // 10) % 10) * 1.2 - 6, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
        sc.set_can_sleep(id, False)
    return sc^


def run(name: StringLiteral, cfg: SolverConfig) raises:
    var sc = pile(200)
    for _ in range(WARM):
        sc.step(DT, G, cfg)
    mark(name)
    for _ in range(STEPS):
        sc.step(DT, G, cfg)
    mark(name)


def main() raises:
    print("STEPS", STEPS, flush=True)
    # control: one fresh List per step must count one allocation per step
    mark("control")
    var kept = List[List[Int]]()
    for k in range(STEPS):
        var l = List[Int](capacity=1000 + k)
        l.append(k)
        kept.append(l^)
    mark("control")
    print("kept", len(kept), kept[STEPS - 1][0])
    var base = SolverConfig()
    run("serial", base)
    var bp = base
    bp.broadphase = True
    run("broadphase", bp)
    var par = bp
    par.parallel = True
    run("island-parallel", par)
    var col = bp
    col.colored = True
    run("colored", col)
