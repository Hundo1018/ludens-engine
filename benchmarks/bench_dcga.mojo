"""DCGA spike: what the uniform quartic incidence test costs.

The claim being priced is not speed, it is REACH. A torus is a quartic, so
`Cl(4,1)` cannot represent it at all; the doubled algebra can, and turns the
incidence test into a single inner product that also covers planes and spheres
with nothing changed but the coefficients (`test_dcga`). The rows show what
that uniformity costs against each surface's hand-written test.

Read the plane and sphere rows as the price of generality — the DCGA path
evaluates all 15 monomials whether the surface needs them or not — and the
torus row as the interesting one, since there the comparison is against a
formula that has a square root in it rather than against nothing.
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, dot, normalize
from geometry.dcga import (
    dcga_point, dcga_incidence, dcga_plane, dcga_sphere, dcga_torus,
    torus_analytic,
)


def main() raises:
    comptime N = 4096
    var rng = SplitMix64.seeded(71)
    var px = List[Real]()
    var py = List[Real]()
    var pz = List[Real]()
    for _ in range(N):
        px.append(Real(rng.next_f32()) * 8 - 4)
        py.append(Real(rng.next_f32()) * 8 - 4)
        pz.append(Real(rng.next_f32()) * 8 - 4)

    comptime R: Real = 2.0
    comptime r: Real = 0.6
    var tor = dcga_torus(R, r)
    var sph = dcga_sphere(Vec3(0.4, -0.3, 0.9), 1.7)
    var nrm = normalize(Vec3(0.3, 0.8, -0.5))
    var pl = dcga_plane(nrm, 1.25)

    var t = BenchTable("DCGA: one uniform incidence test vs hand-written surfaces")

    @parameter
    def torus_dcga():
        var acc = Real(0)
        for i in range(N):
            acc += dcga_incidence(
                dcga_point(Vec3(px[i], py[i], pz[i])), tor
            )
        keep(acc)

    @parameter
    def torus_hand():
        var acc = Real(0)
        for i in range(N):
            acc += torus_analytic(R, r, Vec3(px[i], py[i], pz[i]))
        keep(acc)

    @parameter
    def sphere_dcga():
        var acc = Real(0)
        for i in range(N):
            acc += dcga_incidence(
                dcga_point(Vec3(px[i], py[i], pz[i])), sph
            )
        keep(acc)

    @parameter
    def sphere_hand():
        var acc = Real(0)
        var c = Vec3(0.4, -0.3, 0.9)
        for i in range(N):
            var d = Vec3(px[i], py[i], pz[i]) - c
            acc += dot(d, d) - 1.7 * 1.7
        keep(acc)

    @parameter
    def plane_dcga():
        var acc = Real(0)
        for i in range(N):
            acc += dcga_incidence(dcga_point(Vec3(px[i], py[i], pz[i])), pl)
        keep(acc)

    @parameter
    def plane_hand():
        var acc = Real(0)
        for i in range(N):
            acc += dot(Vec3(px[i], py[i], pz[i]), nrm) - 1.25
        keep(acc)

    t.add("torus  dcga (uniform)", N, "test", measure[torus_dcga](3, 20), N)
    t.add("torus  hand-written", N, "test", measure[torus_hand](3, 20), N)
    t.add("sphere dcga (uniform)", N, "test", measure[sphere_dcga](3, 20), N)
    t.add("sphere hand-written", N, "test", measure[sphere_hand](3, 20), N)
    t.add("plane  dcga (uniform)", N, "test", measure[plane_dcga](3, 20), N)
    t.add("plane  hand-written", N, "test", measure[plane_hand](3, 20), N)
    t.print_report()
