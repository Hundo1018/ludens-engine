"""Contact-solver benchmark: SequentialImpulse vs PBD vs XPBD.

The identical workload — drop a grid of boxes onto a floor and simulate F frames
through the same `PhysicsWorld` step (broadphase + narrowphase + solve) — run via
each interchangeable solver at a fixed iteration count. All solvers settle the
stack to the same non-penetrating rest (see `test_physics_dynamics`); the table
shows what each costs (the position-based PBD/XPBD do less per contact than the
velocity impulse solver, which also resolves friction). Run:
`mojo run -I build benchmarks/bench_physics.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Vec2, Real
from physics.rigidbody import RigidBody
from physics.solver import ContactSolver, SequentialImpulse, Pbd, Xpbd
from physics.step import PhysicsWorld


def build_world[S: ContactSolver](
    cols: Int, rows: Int, iters: Int
) raises -> PhysicsWorld[2, S]:
    var w = PhysicsWorld[2, S](Vec2(0, -10), iters)
    _ = w.add(RigidBody[2].static_box(Vec2(0, -1), Vec2(50, 1), 0.0, 0.5))
    for r in range(rows):
        for c in range(cols):
            var x = Real(c) * 1.05 - Real(cols) * 0.5
            var y = Real(r) * 1.05 + 0.6
            _ = w.add(RigidBody[2].dynamic(Vec2(x, y), Vec2(0.5, 0.5), 1.0, 0.0, 0.5))
    return w^


def bench_solver[S: ContactSolver](
    mut table: BenchTable, variant: String, cols: Int, rows: Int, frames: Int, iters: Int
) raises:
    var w = build_world[S](cols, rows, iters)
    var n = cols * rows
    var t0 = now()
    for _f in range(frames):
        w.step(1.0 / 60.0)
        keep(w.body(1).pos[1])
    var t1 = now()
    table.add(variant, n, "step", t1 - t0, frames * n)


def main() raises:
    var table = BenchTable("Contact solvers — drop a box grid onto a floor")
    var cols = 10
    var rows = 10  # 100 dynamic boxes + 1 floor
    var frames = 60
    var iters = 10
    bench_solver[SequentialImpulse](table, "impulse", cols, rows, frames, iters)
    bench_solver[Pbd](table, "pbd", cols, rows, frames, iters)
    bench_solver[Xpbd](table, "xpbd", cols, rows, frames, iters)
    table.print_report()
