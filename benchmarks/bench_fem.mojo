"""Co-rotational FEM: mesh scaling, and what rotation-invariance costs.

Two things are measured. The first is ordinary: cost per tetrahedron as the
mesh grows, which is linear because every tet is independent.

The second is the trade that actually decides whether co-rotational FEM is
worth it. Linear elasticity measures strain from displacement, so it is only
valid for small DISPLACEMENTS — rotate an undeformed body and it reports
enormous spurious strain. Co-rotational FEM removes that by extracting the
rotation from the deformation gradient with a polar decomposition, which is
pure overhead at rest and the entire reason the method works under motion.
Running both variants over the same mesh prices that overhead directly, and
the accompanying error column shows what is bought: peak spurious force after
a 63-degree rigid rotation of an undeformed body, which should be zero.
"""

from std.math import sqrt, cos, sin
from std.time import perf_counter_ns
from std.benchmark import keep
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam

comptime REPS = 5


def _beam(nx: Int, ny: Int, nz: Int, coro: Bool) -> FemBody:
    var b = FemBody(young=5000.0, poisson=0.3)
    b.corotational = coro
    make_beam(b, nx, ny, nz, 0.1, 0.05)
    return b^


def _force_ns(mut b: FemBody) -> Int:
    var n = b.node_count()
    var best = Int.MAX
    for _ in range(REPS):
        var fx = List[Real]()
        var fy = List[Real]()
        var fz = List[Real]()
        for _ in range(n):
            fx.append(0)
            fy.append(0)
            fz.append(0)
        var t0 = Int(perf_counter_ns())
        b.elastic_forces(fx, fy, fz)
        var dt = Int(perf_counter_ns()) - t0
        keep(fx[0])
        if dt < best:
            best = dt
    return best


def _rotate(mut b: FemBody, ang: Real):
    var ca = Real(cos(Float64(ang)))
    var sa = Real(sin(Float64(ang)))
    for i in range(b.node_count()):
        var px = b.x[i]
        var py = b.y[i]
        b.x[i] = ca * px - sa * py
        b.y[i] = sa * px + ca * py


def _max_force(mut b: FemBody) -> Real:
    var n = b.node_count()
    var fx = List[Real]()
    var fy = List[Real]()
    var fz = List[Real]()
    for _ in range(n):
        fx.append(0)
        fy.append(0)
        fz.append(0)
    b.elastic_forces(fx, fy, fz)
    var m = Real(0)
    for i in range(n):
        var f = sqrt(fx[i] * fx[i] + fy[i] * fy[i] + fz[i] * fz[i])
        if f > m:
            m = f
    return m


def _fmt(v: Real) -> String:
    var x = Int(Float64(v) * 100.0 + 0.5)
    var frac = x % 100
    var fs = String(frac)
    if frac < 10:
        fs = "0" + fs
    return String(x // 100) + "." + fs


def _row(mut t: BenchTable, nx: Int, ny: Int, nz: Int, coro: Bool) raises:
    var b = _beam(nx, ny, nz, coro)
    var ntet = len(b.tets)
    var ns = _force_ns(b)
    # spurious force after a rigid rotation: the error this variant carries
    var r = _beam(nx, ny, nz, coro)
    _rotate(r, 1.1)
    var err = _max_force(r)
    var name = "corotational" if coro else "linear (R=I)"
    t.add(
        name + " " + String(nx) + "x" + String(ny) + "x" + String(nz)
        + " rot-err=" + _fmt(err),
        ntet, "tet", ns, ntet,
    )


def main() raises:
    var t = BenchTable("Co-rotational FEM: mesh scaling and the cost of rotation-invariance")
    _row(t, 4, 2, 2, True)
    _row(t, 4, 2, 2, False)
    _row(t, 8, 4, 4, True)
    _row(t, 8, 4, 4, False)
    _row(t, 12, 6, 6, True)
    _row(t, 12, 6, 6, False)
    t.print_report()
