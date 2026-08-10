"""3D SDF contact: what generality costs against the analytic pairs.

The engine already answers sphere-sphere and sphere-box in closed form. An SDF
answers them by ITERATING — driving the two fields to a common value — so it
must be slower on any pair that has a closed form. What it buys is that the
same code answers shapes that have no closed form at all: CSG combinations,
procedurally sculpted geometry, anything defined by a field rather than by a
primitive tag. Contact cost also stops depending on tessellation, since there
is no mesh.

Two axes. Iteration count is the accuracy/cost dial and shows where the
descent has actually converged (`test_sdf3` pins the converged answer against
the analytic pair to ~1e-7). Shape kind separates "same answer, more expensive"
from "an answer the analytic path cannot give at all" — the CSG row has no
analytic counterpart to put beside it, which IS the result.
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, length
from geometry.shape import Sphere
from geometry.sdf3 import Sdf3, sdf_contact, OP_SUBTRACT

comptime N = 512


def main() raises:
    var rng = SplitMix64.seeded(151)
    var ca = List[Real]()
    var cb = List[Real]()
    for _ in range(N * 6):
        ca.append(Real(rng.next_f32()) * 2 - 1)
    for _ in range(N * 6):
        cb.append(Real(rng.next_f32()) * 2 - 1)

    var t = BenchTable("3D SDF contact vs the analytic pairs")

    comptime for ii in range(3):
        comptime IT = 8 if ii == 0 else (16 if ii == 1 else 32)

        @parameter
        def sdf_pair():
            var acc = Real(0)
            for i in range(N):
                var pa = Vec3(ca[i * 3], ca[i * 3 + 1], ca[i * 3 + 2])
                var pb = Vec3(cb[i * 3], cb[i * 3 + 1], cb[i * 3 + 2]) + Vec3(1.2, 0, 0)
                var c = sdf_contact(
                    Sdf3.sphere(pa, 0.8), Sdf3.sphere(pb, 0.7),
                    (pa + pb) * 0.5, IT,
                )
                acc += c.depth
            keep(acc)

        t.add(
            "sdf sphere-sphere it=" + String(IT), N, "pair",
            measure[sdf_pair](3, 20), N,
        )

    @parameter
    def analytic_pair():
        var acc = Real(0)
        for i in range(N):
            var pa = Vec3(ca[i * 3], ca[i * 3 + 1], ca[i * 3 + 2])
            var pb = Vec3(cb[i * 3], cb[i * 3 + 1], cb[i * 3 + 2]) + Vec3(1.2, 0, 0)
            var d = length(pb - pa)
            var pen = 1.5 - d
            acc += pen if pen > 0 else Real(0)
        keep(acc)

    t.add("analytic sphere-sphere", N, "pair", measure[analytic_pair](3, 20), N)

    # CSG: a box with a sphere bitten out, against a probe sphere. There is no
    # analytic row to put beside this one — that absence is the capability.
    var bitten = Sdf3.box(Vec3(0, 0, 0), Vec3(1, 1, 1)).combined(
        OP_SUBTRACT, Sdf3.sphere(Vec3(1, 0, 0), 0.7)
    )

    @parameter
    def csg_pair():
        var acc = Real(0)
        for i in range(N):
            var pb = Vec3(ca[i * 3], ca[i * 3 + 1], ca[i * 3 + 2])
            var c = sdf_contact(bitten, Sdf3.sphere(pb, 0.3), pb, 32)
            acc += c.depth
        keep(acc)

    t.add(
        "sdf CSG(box minus sphere) vs sphere  [no analytic pair exists]",
        N, "pair", measure[csg_pair](3, 20), N,
    )
    t.print_report()
