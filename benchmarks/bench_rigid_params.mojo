"""ROADMAP 17.48: per-step cost of the per-body parameter pass.

N spheres falling freely (no contacts, so the step is integration plus
broadphase and the extra pass is as visible as it gets). Variants:
  - default: no setter ever called (`any_props` False, the old path);
  - props, defaults: every body given its default values (`any_props` True,
    both passes walk the bodies but change nothing);
  - damping: linear + angular damping on every body;
  - all: damping, gravity scale, 2.5D locks and speed caps on every body;
  - forces: `add_force` on every body every step (accumulator consumed).
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 20


def _scene(n: Int, variant: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var side = 1
    while side * side < n:
        side += 1
    for i in range(n):
        var b = QuatBody6.at_rest(Vec3(Real(i % side) * 2, 100, Real(i // side) * 2, 0), Inertia3.sphere(1, 0.5))
        var id = sc.add_sphere(b^, 0.5, False)
        sc.set_can_sleep(id, False)
        if variant == 1:
            sc.set_damping(id, 0, 0)
        elif variant == 2:
            sc.set_damping(id, 0.5, 0.5)
        elif variant >= 3:
            sc.set_damping(id, 0.5, 0.5)
            sc.set_gravity_scale(id, 0.8)
            sc.set_axis_locks(id, False, False, True, True, True, False)
            sc.set_max_velocity(id, 50, 20)
    return sc^


def _run(mut sc: ContactScene6[QuatBody6], forces: Bool) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        if forces:
            for i in range(len(sc.bset.bodies)):
                sc.add_force(sc.bset.id_of(i), Vec3(1, 0, 0, 0))
        sc.step_soft(DT, G, broadphase=True)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("Per-body parameters (17.48): step cost, free-falling spheres")
    for n in [1000, 10000]:
        var a = _scene(n, 0)
        t.add("default (no setter)", n, "step", _run(a, False), STEPS)
        var b = _scene(n, 1)
        t.add("props on, default values", n, "step", _run(b, False), STEPS)
        var c = _scene(n, 2)
        t.add("damping", n, "step", _run(c, False), STEPS)
        var d = _scene(n, 3)
        t.add("damping + scale + locks + caps", n, "step", _run(d, False), STEPS)
        var e = _scene(n, 3)
        t.add("all + add_force every body every step", n, "step", _run(e, True), STEPS)
    t.print_report()
