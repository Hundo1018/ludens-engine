# tier: component
"""Batched narrowphase (ROADMAP 17.17): the GPU kernel body run on the host.

2000 random pairs over every kind combination of box / sphere / capsule
(both orders, so the kind normalisation and normal flip are exercised),
random orientations, nonzero speculative margin and inflation, centres
close enough that most pairs touch. Every manifold from `NarrowBatch`
(flat records, `narrow_pair`) must equal `ColliderSet.pair_manifold`
bit-for-bit: hit, count, normal, points, depths. Hull colliders are refused.
"""

from std.math import sin, cos, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from collision.collider_set import ColliderSet, Pose3, SHAPE_BOX, SHAPE_SPHERE, SHAPE_CAPSULE
from collision.manifold import Axes3, ContactManifold
from collision.narrow_batch import NarrowBatch


struct Lcg:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64(self.s >> 11) / Float64(1 << 53))

    def range(mut self, lo: Real, hi: Real) -> Real:
        return lo + (hi - lo) * self.next()


def pose(mut r: Lcg) -> Pose3:
    var axis = Vec3(r.range(-1, 1), r.range(-1, 1), r.range(-1, 1), 0)
    var l = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]) + 1e-6
    var q = Quat.from_axis_angle(axis / l, r.range(0, 6.28))
    var ax = Axes3(fill=Vec3(0, 0, 0, 0))
    ax[0] = q.rotate(Vec3(1, 0, 0, 0))
    ax[1] = q.rotate(Vec3(0, 1, 0, 0))
    ax[2] = q.rotate(Vec3(0, 0, 1, 0))
    return Pose3(Vec3(r.range(-0.8, 0.8), r.range(-0.8, 0.8), r.range(-0.8, 0.8), 0), ax^)


def same(a: ContactManifold[3], b: ContactManifold[3]) -> Bool:
    if a.hit != b.hit or a.count != b.count:
        return False
    for c in range(3):
        if a.normal[c].to_bits() != b.normal[c].to_bits():
            return False
    for k in range(a.count):
        if a.depths[k].to_bits() != b.depths[k].to_bits():
            return False
        for c in range(3):
            if a.points[k][c].to_bits() != b.points[k][c].to_bits():
                return False
    return True


def main() raises:
    var s = Suite("narrow_batch")
    var cs = ColliderSet()
    var kinds = List[Int]()
    var r = Lcg(17)
    for i in range(60):
        var k = i % 3
        if k == SHAPE_BOX:
            _ = cs.add(Vec3(r.range(0.2, 0.7), r.range(0.2, 0.7), r.range(0.2, 0.7), 0))
        elif k == SHAPE_SPHERE:
            _ = cs.add_sphere(r.range(0.2, 0.6))
        else:
            _ = cs.add_capsule(r.range(0.15, 0.4), r.range(0.2, 0.6))
        kinds.append(k)
    var nb = NarrowBatch(2000)
    var pi = List[Int]()
    var pj = List[Int]()
    var poses_i = List[Pose3]()
    var poses_j = List[Pose3]()
    var mrs = List[Real]()
    var infls = List[Vec3]()
    var combos = List[Int](length=9, fill=0)
    for _ in range(2000):
        var i = Int(r.next() * 60) % 60
        var j = (i + 1 + Int(r.next() * 59)) % 60
        var a = pose(r)
        var b = pose(r)
        var mr = r.range(0, 0.05)
        var e = r.range(0, 0.02)
        var infl = Vec3(e, e, e, 0)
        nb.add_pair(cs, i, j, a, b, mr, infl)
        pi.append(i)
        pj.append(j)
        poses_i.append(a^)
        poses_j.append(b^)
        mrs.append(mr)
        infls.append(infl)
        combos[kinds[i] * 3 + kinds[j]] += 1
    nb.run_host()
    var hits = 0
    var diff = 0
    for k in range(nb.count):
        var want = cs.pair_manifold(pi[k], pj[k], poses_i[k], poses_j[k], mrs[k], infls[k])
        if want.hit:
            hits += 1
        if not same(nb.manifold(k), want):
            diff += 1
    var min_combo = 1 << 30
    for c in combos:
        min_combo = min(min_combo, c)
    print("  2000 pairs,", hits, "touching; fewest pairs of one ordered kind combination:", min_combo)
    s.check(min_combo >= 100, "all 9 ordered kind combinations exercised (>= 100 each)")
    s.check(hits > 600, "most pairs touch (" + String(hits) + ")")
    s.eqi(diff, 0, "batch manifold == ColliderSet.pair_manifold bit-for-bit (2000 pairs)")

    var hulls = ColliderSet()
    var pts = List[Real]()
    for v in [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]:
        pts.append(Real(v))
    _ = hulls.add_hull(pts^)
    _ = hulls.add(Vec3(0.5, 0.5, 0.5, 0))
    var refused = False
    try:
        nb.add_pair(hulls, 0, 1, pose(r), pose(r), 0, Vec3(0, 0, 0, 0))
    except:
        refused = True
    s.check(refused, "hull collider refused (stays on the CPU path)")
    s.finish()
