"""Particles to surface (ROADMAP 17.60): what the splat and the extraction
cost on a ball of 7232 particles (radius 0.3 m, spacing 2.5 cm), splatted
to a 73^3 node grid with R = 5 cm: the isotropic poly6 splat, the
anisotropic one (Yu & Turk 2013: neighbourhood covariance, eigen
decomposition, ellipsoid kernels), and marching tetrahedra on the result.

Run with: `mojo run -I build benchmarks/bench_isosurface.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from geometry.isosurface import splat_particles, splat_particles_anisotropic, marching_tetrahedra
from harness.bench import BenchTable, now


def ball() -> List[Vec3]:
    var out = List[Vec3]()
    for k in range(28):
        for j in range(28):
            for i in range(28):
                var p = Vec3(Real(i) * 0.025 - 0.3375, Real(j) * 0.025 - 0.3375, Real(k) * 0.025 - 0.3375, 0)
                if p[0] * p[0] + p[1] * p[1] + p[2] * p[2] < 0.09:
                    out.append(p)
    return out^


def main() raises:
    var t = BenchTable("Particles to surface: splat and marching tetrahedra (17.60)")
    var pts = ball()
    var o = Vec3(-0.45, -0.45, -0.45, 0)
    var t0 = now()
    var gi = splat_particles(pts, 0.05, o, 0.0125, 73, 73, 73)
    var t1 = now()
    t.add("isotropic splat", len(pts), "particle", t1 - t0, len(pts))
    var t2 = now()
    var ga = splat_particles_anisotropic(pts, 0.05, o, 0.0125, 73, 73, 73, 0.1)
    var t3 = now()
    t.add("anisotropic splat (neighbours, covariance, eigen)", len(pts), "particle", t3 - t2, len(pts))
    var t4 = now()
    var m = marching_tetrahedra(gi, 0.5 * gi.v[gi.idx(36, 36, 36)])
    var t5 = now()
    keep(ga.v[100])
    t.add("marching tetrahedra 73^3 (" + String(m.triangles()) + " triangles)", 72 * 72 * 72, "cell", t5 - t4, 72 * 72 * 72)
    t.print_report()
