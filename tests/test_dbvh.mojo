from harness.runner import Suite
from geometry.vec import Real, Vec2, Vec3
from geometry.aabb import AABB, AABB3
from scheduler.rng import Pcg32, Rng
from collision.broadphase import BroadPhase, BruteForce, Pair, BoxProxy
from collision.bp_dbvh import DbvhBroadPhase


def _rf(mut rng: Pcg32, lo: Real, hi: Real) -> Real:
    return lo + (hi - lo) * Real(rng.next_f32())


def _same_pairs(a: List[Pair], b: List[Pair]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        var pa = min(a[i].a, a[i].b)
        var pb = max(a[i].a, a[i].b)
        var found = False
        for j in range(len(b)):
            if min(b[j].a, b[j].b) == pa and max(b[j].a, b[j].b) == pb:
                found = True
                break
        if not found:
            return False
    return True


def main() raises:
    var s = Suite("dbvh")
    comptime N = 200
    var rng = Pcg32.seeded(7)

    # random boxes in a 20-cube, then 30 frames of jitter random-walk;
    # the incremental tree must reproduce BruteForce's pair set every frame.
    # (coordinates kept as three scalar lists: bare List[SIMD3] is hazardous)
    var cx = List[Real]()
    var cy = List[Real]()
    var cz = List[Real]()
    for _ in range(N):
        cx.append(_rf(rng, -10, 10))
        cy.append(_rf(rng, -10, 10))
        cz.append(_rf(rng, -10, 10))

    var dbvh = DbvhBroadPhase[3]()
    var brute = BruteForce[3]()
    var all_match = True
    var region_match = True
    for _ in range(30):
        var items = List[BoxProxy[3]]()
        for i in range(N):
            cx[i] += _rf(rng, -0.05, 0.05)
            cy[i] += _rf(rng, -0.05, 0.05)
            cz[i] += _rf(rng, -0.05, 0.05)
            var half = Vec3(0.6, 0.6, 0.6)
            items.append(
                BoxProxy[3](
                    i,
                    AABB[3].from_center(Vec3(cx[i], cy[i], cz[i]), half),
                )
            )
        dbvh.rebuild(items)
        brute.rebuild(items)
        var pd = List[Pair]()
        var pb = List[Pair]()
        dbvh.pairs(pd)
        brute.pairs(pb)
        if not _same_pairs(pd, pb):
            all_match = False
            print("  pair mismatch: dbvh", len(pd), "brute", len(pb))
        var probe = AABB3(Vec3(-2, -2, -2), Vec3(2, 2, 2))
        var qd = List[Int]()
        var qb = List[Int]()
        dbvh.query_region(probe, qd)
        brute.query_region(probe, qb)
        if len(qd) != len(qb):
            region_match = False
    s.check(all_match, "30 jitter frames: pair-set parity with BruteForce")
    s.check(region_match, "query_region parity")

    # teleport a box far away and back: pairs stay exact through big moves
    var items2 = List[BoxProxy[3]]()
    for i in range(N):
        var c = Vec3(cx[i], cy[i], cz[i])
        if i == 0:
            c = Vec3(100, 100, 100)
        items2.append(BoxProxy[3](i, AABB[3].from_center(c, Vec3(0.6, 0.6, 0.6))))
    dbvh.rebuild(items2)
    brute.rebuild(items2)
    var pd2 = List[Pair]()
    var pb2 = List[Pair]()
    dbvh.pairs(pd2)
    brute.pairs(pb2)
    s.check(_same_pairs(pd2, pb2), "teleport out: parity holds")

    s.finish()
