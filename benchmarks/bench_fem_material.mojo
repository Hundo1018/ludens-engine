"""FEM constitutive models (ROADMAP 17.58): force evaluation cost per model.

One `material_forces[M]` pass over a bent 12 x 4 x 4 beam (960 tets), per
model, against `FemBody.elastic_forces` (the built-in corotational path the
seam's `Corotational` must equal). Corotational pays 12 Newton iterations of
the polar decomposition per element; Neo-Hookean and StVK need none.

Implicit step (17.58): one linearised backward-Euler step of a stiff
cantilever (12 x 2 x 2 cells, E = 1e7, dt = 1/60, first step from rest) with
the co-rotational tangent (`FemBody.step_implicit`, CG) and the stable
Neo-Hookean one (`step_implicit_nh`, MINRES); solver iterations in the row.

Run with: `mojo run -I build benchmarks/bench_fem_material.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real
from physics.fem import FemBody, make_beam
from physics.fem_material import Material, Corotational, StableNeoHookean, StVK, material_forces, step_implicit_nh
from geometry.vec import Vec3
from harness.bench import BenchTable, now


def bent() -> FemBody:
    var b = FemBody(1e5, 0.3)
    make_beam(b, 12, 4, 4, 0.1, 0.05)
    for i in range(b.node_count()):
        b.y[i] += 0.05 * b.x[i] * b.x[i]
    return b^


def row[M: Material](mut t: BenchTable, b: FemBody, reps: Int):
    var n = b.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    var t0 = now()
    for _ in range(reps):
        material_forces[M](b, fx, fy, fz)
    var t1 = now()
    keep(fx[n - 1])
    t.add(M.name(), len(b.tets), "tet", t1 - t0, reps * len(b.tets))


def cantilever() -> FemBody:
    var b = FemBody(1e7, 0.3, 6.0)
    make_beam(b, 12, 2, 2, 0.1, 0.05)
    for i in range(b.node_count()):
        if b.x[i] < 1e-6:
            b.pin(i)
    return b^


def implicit_rows(mut t: BenchTable):
    var reps = 20
    var it = 0
    var t0 = now()
    for _ in range(reps):
        var b = cantilever()
        it = b.step_implicit(1.0 / 60.0, Vec3(0, -9.8, 0, 0), -1e30, 1e-6, 400).iters
    var t1 = now()
    t.add("implicit corotational, CG (" + String(it) + " iterations)", 1, "step", t1 - t0, reps)
    t0 = now()
    for _ in range(reps):
        var b = cantilever()
        it = step_implicit_nh(b, 1.0 / 60.0, Vec3(0, -9.8, 0, 0), -1e30, 1e-4, 2000).iters
    t1 = now()
    t.add("implicit stable Neo-Hookean, MINRES (" + String(it) + " iterations)", 1, "step", t1 - t0, reps)


def main():
    var b = bent()
    var reps = 200
    var t = BenchTable("FEM constitutive models: elastic force pass (17.58)")
    var n = b.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    var t0 = now()
    for _ in range(reps):
        b.elastic_forces(fx, fy, fz)
    var t1 = now()
    keep(fx[n - 1])
    t.add("FemBody.elastic_forces (built-in corotational)", len(b.tets), "tet", t1 - t0, reps * len(b.tets))
    row[Corotational](t, b, reps)
    row[StableNeoHookean](t, b, reps)
    row[StVK](t, b, reps)
    t.print_report()
    var ti = BenchTable("Implicit FEM step: co-rotational vs stable Neo-Hookean tangent (E = 1e7 cantilever, 17.58)")
    implicit_rows(ti)
    ti.print_report()
