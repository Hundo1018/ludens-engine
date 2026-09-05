"""Example 09 — an XPBD soft body and two-way soft/rigid coupling.

`SoftBody.box_lattice` is an n^3 particle lattice with distance constraints over
the 13 unique neighbour directions, solved by XPBD inside `ContactScene6`'s
sub-stepped `step_soft`. Two vignettes:

  1. Drop a soft cube on the static ground. It must settle: no particle sinks
     through the floor (`bottom_y` >= 0) and the lattice comes to rest
     (`max_speed` -> 0).

  2. Zero gravity, lossless material (`damp = 1`): give the whole lattice an
     initial velocity toward a free-floating rigid box, step ~120 frames, and
     watch the rigid box pick up x-momentum. The soft body's lost momentum
     shows up on the box — the coupling is two-way and (within the solver's
     damping) conserving.

Run:

    pixi run mojo run -I build examples/09_softbody_coupling.mojo
"""

from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def main():
    # --- 1. drop a soft cube on the ground; it settles ---
    print("== soft cube dropped on the ground, 300 frames ==")
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    _ = sc.add_soft(
        SoftBody.box_lattice(Vec3(0, 1.0, 0, 0), Vec3(0.3, 0.3, 0.3, 0), 4, 2.0, 1e-6)
    )
    for _ in range(300):
        sc.step_soft(DT, G)
    var bot = Float64(sc.softs[0].bottom_y())
    var top = Float64(sc.softs[0].top_y())
    var spd = Float64(sc.softs[0].max_speed())
    print("  bottom_y =", bot, " top_y =", top, " height =", top - bot)
    print("  max_speed =", spd, "->", "SETTLED" if (spd < 0.1 and bot > -0.01) else "still moving")

    # --- 2. zero-g: a moving soft cube transfers momentum to a free rigid box ---
    print("== zero gravity: soft cube (v=+2 x) hits a free rigid box, 120 frames ==")
    var zg = ContactScene6[QuatBody6]()
    var box = zg.add(
        QuatBody6.at_rest(Vec3(1.0, 0, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    var cube = SoftBody.box_lattice(Vec3(-0.6, 0, 0, 0), Vec3(0.3, 0.3, 0.3, 0), 4, 2.0, 1e-6)
    cube.damp = 1.0  # lossless: isolates the coupling's conservation
    for i in range(len(cube.pts)):
        cube.pts[i].v = Vec3(2, 0, 0, 0)
    _ = zg.add_soft(cube^)

    var p_before = Float64(zg.softs[0].momentum()[0])  # box is at rest -> total = soft
    for _ in range(120):
        zg.step_soft(DT, Vec3(0, 0, 0, 0))
    var box_p = Float64(zg.bodies[box].vel[0]) * 2.0  # rigid box mass = 2
    var soft_p = Float64(zg.softs[0].momentum()[0])
    print("  x-momentum before:            ", p_before)
    print("  x-momentum after: soft =", soft_p, " + box =", box_p)
    print("  total after =", soft_p + box_p, " (rel. error", abs((soft_p + box_p) - p_before) / p_before, ")")
    print("  box picked up momentum:", "YES" if box_p > 0.3 else "NO")
