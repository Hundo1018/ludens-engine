"""CGA plane primitives + heterogeneous narrowphase (E2): signed distances,
versor reflection, and sphere/plane contacts must all match analytic geometry;
the ground-plane-plus-balls scene must run through `CollisionPipeline` like any
other narrowphase."""

from std.math import sqrt
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, dot, normalize, length
from geometry.shape import Sphere
from geometry.aabb import AABB
from geometry.cga import (
    up, down, inner, plane_dual, reflect_point, Plane3, sphere_dual,
)
from collision.narrowphase import CgaShapeNarrowPhase
from collision.broadphase import BruteForce, BoxProxy
from collision.pipeline import CollisionPipeline


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("cga_plane")
    var rng = SplitMix64.seeded(41)

    # --- up/down round-trip ---
    for _ in range(4):
        var p = Vec3(
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
        )
        _near3(s, down(up(p)), p, "down(up(p)) == p")

    # --- signed distance: up(p)·π == p·n − d (analytic) ---
    for _ in range(6):
        var n = normalize(
            Vec3(
                Real(rng.next_f32()) + 0.1,
                Real(rng.next_f32()) + 0.2,
                Real(rng.next_f32()) + 0.3,
            )
        )
        var pl = Plane3(n, Real(rng.next_f32()) * 2 - 1)
        var p = Vec3(
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
            Real(rng.next_f32()) * 4 - 2,
        )
        var alg = inner(up(p), plane_dual(pl))
        var ana = dot(p, n) - pl.d
        s.almost(Float64(alg), Float64(ana), "P·π == signed distance", 1e-3)

        # sphere center distance too: S·π (n∞ parts annihilate)
        var r = Real(rng.next_f32()) + 0.2
        var alg_s = inner(sphere_dual(p, r), plane_dual(pl))
        s.almost(Float64(alg_s), Float64(ana), "S·π == center distance", 1e-3)

        # --- versor reflection == analytic mirror p − 2(p·n − d)n ---
        var want = p - n * (2 * ana)
        _near3(s, reflect_point(pl, p), want, "π P π == mirror")
        # reflection is an involution
        _near3(s, reflect_point(pl, reflect_point(pl, p)), p, "reflect twice = id")

    # --- heterogeneous narrowphase: ground plane + balls ---
    var np = CgaShapeNarrowPhase()
    var ground = Plane3(Vec3(0, 1, 0), 0)  # y = 0
    var ip = np.add_plane(ground)
    var touching = np.add(Sphere(Vec3(0, 0.5, 0), 1.0))    # penetrates 0.5
    var floating = np.add(Sphere(Vec3(5, 3.0, 0), 1.0))    # clear
    var s2 = np.add(Sphere(Vec3(0.2, 1.4, 0), 1.0))        # overlaps `touching`

    var c_tp = np.test(touching, ip)  # sphere vs plane
    s.check(c_tp.hit, "ball touches ground")
    s.almost(Float64(c_tp.depth), 0.5, "ground penetration depth", 1e-3)
    s.almost(Float64(c_tp.normal[1]), -1.0, "normal points ball→ground", 1e-3)

    var c_pt = np.test(ip, touching)  # plane vs sphere (flipped order)
    s.check(c_pt.hit, "order-independent hit")
    s.almost(Float64(c_pt.normal[1]), 1.0, "flipped normal a→b", 1e-3)

    s.check(not np.test(floating, ip).hit, "floating ball misses ground")
    s.check(np.test(touching, s2).hit, "sphere-sphere still works")
    s.check(not np.test(ip, ip).hit, "plane-plane is a miss")

    # --- the same scene through the pipeline seam ---
    var np2 = CgaShapeNarrowPhase()
    _ = np2.add_plane(ground)
    _ = np2.add(Sphere(Vec3(0, 0.5, 0), 1.0))
    _ = np2.add(Sphere(Vec3(5, 3.0, 0), 1.0))
    var items = List[BoxProxy[3]]()
    var big = Real(100)
    items.append(BoxProxy[3](0, AABB[3](Vec3(-big, -1, -big), Vec3(big, 0, big))))
    items.append(BoxProxy[3](1, AABB[3](Vec3(-1, -0.5, -1), Vec3(1, 1.5, 1))))
    items.append(BoxProxy[3](2, AABB[3](Vec3(4, 2, -1), Vec3(6, 4, 1))))
    var pipe = CollisionPipeline(BruteForce[3](), np2^)
    var manifolds = pipe.step(items)
    s.eqi(len(manifolds), 1, "pipeline: only the grounded ball")
    s.almost(
        Float64(manifolds[0].contact.depth), 0.5, "pipeline: depth via S·π", 1e-3
    )

    s.finish()
