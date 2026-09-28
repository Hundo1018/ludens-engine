"""Example 08 — a 6-DOF box stack dropped on static ground, solved sub-stepped.

`ContactScene6.step_soft` is the sub-stepped contact solver (the Box2D-v3 "soft
step" scheme: collide once, then per substep integrate velocities, solve with a
soft bias, integrate poses, and relax with a bias-free sweep so the push-out
energy never turns into bounce). Three dynamic boxes fall onto a static ground
box; after ~200 frames each box has a rest height and the scene has resolved
into contact islands.

`ContactScene6` is generic over the body representation. We run the SAME scene
twice: once with `QuatBody6` (world-frame omega + rotated inertia, the classical
path) and once with `ScrewBody6` (pose is a PGA `Motor3`, velocity is a
body-frame screw). Both must settle to the same rest heights — the seam contract
is parity by action, not by internal state.

Run:

    pixi run mojo run -I build examples/08_solver6_stack.mojo
"""

from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime FRAMES = 240


def _run_quat(frames: Int) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.30, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.82, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 1.34, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(frames):
        sc.step_soft(DT, G)
    return sc^


def _run_screw(frames: Int) -> ContactScene6[ScrewBody6]:
    var sc = ContactScene6[ScrewBody6]()
    _ = sc.add(
        ScrewBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, 0.30, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, 0.82, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(ScrewBody6.at_rest(Vec3(0, 1.34, 0, 0), bi), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(frames):
        sc.step_soft(DT, G)
    return sc^


def main():
    print("== 6-DOF box stack on static ground,", FRAMES, "frames of step_soft ==")

    var q = _run_quat(FRAMES)
    print("QuatBody6  rest heights:")
    for i in range(1, 4):
        print("  box", i, "y =", Float64(q.bset.bodies[i].position()[1]))
    print("  islands:", q.island_count())

    var w = _run_screw(FRAMES)
    print("ScrewBody6 rest heights:")
    for i in range(1, 4):
        print("  box", i, "y =", Float64(w.bset.bodies[i].position()[1]))
    print("  islands:", w.island_count())

    print("== parity: |quat - screw| rest height, tol 1e-2 ==")
    var worst = Float64(0)
    for i in range(1, 4):
        var d = abs(Float64(q.bset.bodies[i].position()[1]) - Float64(w.bset.bodies[i].position()[1]))
        if d > worst:
            worst = d
        print("  box", i, "delta =", d)
    print("  worst delta =", worst, "->", "MATCH" if worst < 1e-2 else "DIVERGED")
