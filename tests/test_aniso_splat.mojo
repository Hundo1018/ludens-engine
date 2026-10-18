# tier: unit
"""Anisotropic particle kernels for the surface (ROADMAP 17.60,
`geometry.isosurface.splat_particles_anisotropic`, Yu & Turk 2013).

  1. Ordinary: a jittered particle slab (1 x 0.1 x 1 m, spacing 2.5 cm,
     jitter +-8 mm, R = 5 cm): the top surface's height spread (standard
     deviation of the vertices away from the edges) is under half the
     isotropic splat's.
  2. Integration: a jittered particle ball (radius 0.3 m): the surface's
     sphericity A^3 / (36 pi V^2) is no further from 1 than the isotropic
     one's (both printed), and the mesh is closed.
  3. Extreme: a lone particle (fewer than min_neighbors) splats exactly the
     isotropic kernel.
"""

from std.math import sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.isosurface import splat_particles, splat_particles_anisotropic, marching_tetrahedra, ScalarGrid
from scheduler.rng import SplitMix64

comptime SP: Real = 0.025
comptime R: Real = 0.05


def jitter(mut rng: SplitMix64) -> Real:
    return (Real(rng.next_f32()) - 0.5) * 0.016


def top_spread(g: ScalarGrid, iso: Real) raises -> Real:
    var m = marching_tetrahedra(g, iso)
    var ys = List[Real]()
    for v in m.verts:
        if v[1] > 0.25 and v[0] > 0.2 and v[0] < 0.8 and v[2] > 0.2 and v[2] < 0.8:
            ys.append(v[1])
    var mean = Real(0)
    for y in ys:
        mean += y
    mean /= Real(len(ys))
    var var_ = Real(0)
    for y in ys:
        var_ += (y - mean) * (y - mean)
    return sqrt(var_ / Real(len(ys)))


def main() raises:
    var s = Suite("aniso_splat")
    var rng = SplitMix64.seeded(3)
    var slab = List[Vec3]()
    for k in range(40):
        for j in range(4):
            for i in range(40):
                slab.append(Vec3(0.0125 + Real(i) * SP + jitter(rng), 0.2125 + Real(j) * SP + jitter(rng), 0.0125 + Real(k) * SP + jitter(rng), 0))
    var o = Vec3(-0.1, 0.0, -0.1, 0)
    var gi = splat_particles(slab, R, o, 0.0125, 97, 40, 97)
    var ga = splat_particles_anisotropic(slab, R, o, 0.0125, 97, 40, 97, 2 * R)
    var ci = gi.v[gi.idx(48, 20, 48)]
    var ca = ga.v[ga.idx(48, 20, 48)]
    var si = top_spread(gi, 0.5 * ci)
    var sa = top_spread(ga, 0.5 * ca)
    print("slab top surface height spread: isotropic", si, " anisotropic", sa)
    s.check(sa < 0.5 * si, "anisotropic kernels flatten the slab's top (spread under half)")

    var ball = List[Vec3]()
    for k in range(28):
        for j in range(28):
            for i in range(28):
                var p = Vec3(Real(i) * SP - 0.3375 + jitter(rng), Real(j) * SP - 0.3375 + jitter(rng), Real(k) * SP - 0.3375 + jitter(rng), 0)
                if p[0] * p[0] + p[1] * p[1] + p[2] * p[2] < 0.09:
                    ball.append(p)
    var ob = Vec3(-0.45, -0.45, -0.45, 0)
    var bi = splat_particles(ball, R, ob, 0.0125, 73, 73, 73)
    var ba = splat_particles_anisotropic(ball, R, ob, 0.0125, 73, 73, 73, 2 * R)
    var mi = marching_tetrahedra(bi, 0.5 * bi.v[bi.idx(36, 36, 36)])
    var ma = marching_tetrahedra(ba, 0.5 * ba.v[ba.idx(36, 36, 36)])
    var sph_i = mi.area() ** 3 / (36 * Real(pi) * mi.volume() ** 2)
    var sph_a = ma.area() ** 3 / (36 * Real(pi) * ma.volume() ** 2)
    print("ball of", len(ball), "particles: sphericity isotropic", sph_i, " anisotropic", sph_a, ";  open edges", mi.open_edges(), ma.open_edges())
    s.check(abs(sph_a - 1) <= abs(sph_i - 1) and ma.open_edges() == 0, "the ball stays as round (or rounder) and closed")

    var one: List[Vec3] = [Vec3(0.5, 0.5, 0.5, 0)]
    var g1 = splat_particles(one, R, Vec3(0, 0, 0, 0), 0.0125, 81, 81, 81)
    var g2 = splat_particles_anisotropic(one, R, Vec3(0, 0, 0, 0), 0.0125, 81, 81, 81, 2 * R)
    var same = True
    for k in range(len(g1.v)):
        same = same and g1.v[k] == g2.v[k]
    s.check(same, "a lone particle splats the isotropic kernel exactly")
    s.finish()
