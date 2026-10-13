"""ROADMAP 17.56: cost of mesh cloth per step.

A square sheet (n x n cells, two triangles each) pinned at two corners,
8 substeps x 4 iterations, 30 steps timed after 10. Columns: free (no
scene), over a static box with collision on (every vertex queries the
scene each substep), and the same with wind drag on. Microseconds per step
and nanoseconds per vertex-substep.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.cloth import MeshCloth, grid_mesh

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _time(n: Int, collide: Bool, wind: Bool) raises -> Int:
    var m = grid_mesh(n, n, 1, 1, Vec3(-0.5, 0.8, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2)
    c.pin(0)
    c.pin(n)
    if wind:
        c.wind = Vec3(0, 0, 3, 0)
        c.drag = 0.2
    var sc = ContactScene6[QuatBody6]()
    if collide:
        _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), True)
    for _ in range(10):
        c.step(sc, DT, G)
    var t0 = Int(perf_counter_ns())
    for _ in range(30):
        c.step(sc, DT, G)
    return (Int(perf_counter_ns()) - t0) // 30


def main() raises:
    print("### Mesh cloth (17.56): cost per step\n")
    print("| cells | vertices | free us | box collision us | collision + wind us | ns per vertex-substep (collision) |")
    print("|---:|---:|---:|---:|---:|---:|")
    for n in [16, 32, 100]:
        var nv = (n + 1) * (n + 1)
        var a = _time(n, False, False)
        var b = _time(n, True, False)
        var c = _time(n, True, True)
        print("|", n, "x", n, "|", nv, "|", a // 1000, "|", b // 1000, "|", c // 1000, "|", b // (nv * 8), "|")
    print("")
