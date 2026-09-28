"""Example 20 — one 2-D world, three contact solvers: the ContactSolver seam.

A three-box stack is dropped onto a static floor and simulated for 4 s with
each of the interchangeable 2-D solvers:
  * `SequentialImpulse` — velocity-level impulses (Box2D lineage);
  * `Pbd`               — position-based projection;
  * `Xpbd`              — compliant position-based projection.
The same world type is instantiated with each solver as its parameter
(`PhysicsWorld[2, S]`), so the swap is a type argument. Each prints the
resting heights (exact stacking: 0.5, 1.5, 2.5) and the residual speed.

Run:

    pixi run mojo run -I build examples/20_contact_solver_2d.mojo
"""

from geometry.vec import Real, Vec2
from physics.rigidbody import RigidBody
from physics.solver import ContactSolver, SequentialImpulse, Pbd, Xpbd
from physics.step import PhysicsWorld


def run[S: ContactSolver](name: String) raises -> Float64:
    var w = PhysicsWorld[2, S](Vec2(0, -10), 10)
    _ = w.add(RigidBody[2].static_box(Vec2(0, -1), Vec2(10, 1)))
    var ids = List[Int]()
    for k in range(3):
        ids.append(w.add(RigidBody[2].dynamic(Vec2(0, 0.6 + Real(k) * 1.1), Vec2(0.5, 0.5), 1.0)))
    for _ in range(240):
        w.step(1.0 / 60.0)
    var worst = Float64(0)
    var line = String("")
    for k in range(3):
        var b = w.body(ids[k])
        worst = max(worst, abs(Float64(b.pos[1]) - (0.5 + Float64(k))))
        line += String(b.pos[1]) + "  "
    var v = w.body(ids[2]).vel
    print(" ", name, " heights:", line, " top speed:", abs(Float64(v[1])))
    return worst


def main() raises:
    print("3-box stack after 4 s (want 0.5  1.5  2.5):")
    var a = run[SequentialImpulse]("SequentialImpulse")
    var b = run[Pbd]("Pbd              ")
    var c = run[Xpbd]("Xpbd             ")
    print("every solver stacks within 0.1 of exact:", "YES" if max(a, max(b, c)) < 0.1 else "NO")
