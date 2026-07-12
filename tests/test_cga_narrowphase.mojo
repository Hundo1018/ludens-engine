"""CGA narrowphase parity (G4 promotion): `CgaSphereNarrowPhase` must agree
with analytic sphere-sphere geometry on hit/miss, penetration depth, and
normal — including the containment case the dual-pencil test alone would miss —
and must run inside `CollisionPipeline` like any other narrowphase (the seam
contract)."""

from std.math import sqrt
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, length
from geometry.shape import Sphere
from geometry.aabb import AABB
from geometry.cga import up, sphere_dual, inner, sphere_dist_sq
from collision.narrowphase import CgaSphereNarrowPhase
from collision.broadphase import BruteForce, BoxProxy
from collision.pipeline import CollisionPipeline


def main() raises:
    var s = Suite("cga_narrowphase")
    var rng = SplitMix64.seeded(17)

    # --- algebraic distance == euclidean distance (random spheres) ---
    var np = CgaSphereNarrowPhase()
    var spheres = List[Sphere]()
    for _ in range(12):
        var sp = Sphere(
            Vec3(
                Real(rng.next_f32()) * 4 - 2,
                Real(rng.next_f32()) * 4 - 2,
                Real(rng.next_f32()) * 4 - 2,
            ),
            Real(rng.next_f32()) * 1.2 + 0.3,
        )
        spheres.append(sp)
        _ = np.add(sp)

    var hits_alg = 0
    var hits_euc = 0
    for i in range(len(spheres)):
        for j in range(i + 1, len(spheres)):
            var c = np.test(i, j)
            var d = length(spheres[j].center - spheres[i].center)
            var rsum = spheres[i].radius + spheres[j].radius
            var euc_hit = d <= rsum
            s.check(c.hit == euc_hit, "hit/miss parity")
            if c.hit:
                hits_alg += 1
                s.almost(Float64(c.depth), Float64(rsum - d), "depth parity", 1e-3)
            if euc_hit:
                hits_euc += 1
    s.eqi(hits_alg, hits_euc, "same hit count over all pairs")
    s.check(hits_euc > 0, "scene actually has contacts")

    # --- containment: one sphere inside another still reports a hit ---
    var np2 = CgaSphereNarrowPhase()
    _ = np2.add(Sphere(Vec3(0, 0, 0), 3.0))
    _ = np2.add(Sphere(Vec3(0.5, 0, 0), 0.5))
    var cc = np2.test(0, 1)
    s.check(cc.hit, "containment counts as overlap")
    s.almost(Float64(cc.depth), 3.0, "containment depth = rsum - d", 1e-3)

    # --- concentric spheres: degenerate normal falls back cleanly ---
    var np3 = CgaSphereNarrowPhase()
    _ = np3.add(Sphere(Vec3(0, 0, 0), 1.0))
    _ = np3.add(Sphere(Vec3(0, 0, 0), 0.5))
    var c0 = np3.test(0, 1)
    s.check(c0.hit, "concentric hit")
    s.almost(Float64(length(c0.normal)), 1.0, "unit fallback normal")

    # --- seam contract: runs inside CollisionPipeline like any narrowphase ---
    var npp = CgaSphereNarrowPhase()
    var items = List[BoxProxy[3]]()
    var setup = [
        (Vec3(0, 0, 0), Real(1.0)),
        (Vec3(1.5, 0, 0), Real(1.0)),  # overlaps 0
        (Vec3(9, 9, 9), Real(1.0)),    # far away
    ]
    for k in range(len(setup)):
        var sp = Sphere(setup[k][0], setup[k][1])
        var id = npp.add(sp)
        var r = Vec3(sp.radius, sp.radius, sp.radius)
        items.append(BoxProxy[3](id, AABB[3](sp.center - r, sp.center + r)))
    var pipe = CollisionPipeline(BruteForce[3](), npp^)
    var manifolds = pipe.step(items)
    s.eqi(len(manifolds), 1, "pipeline: exactly the overlapping pair")
    s.almost(
        Float64(manifolds[0].contact.depth), 0.5, "pipeline: depth via algebra", 1e-3
    )

    s.finish()
