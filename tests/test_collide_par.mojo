# tier: integration
"""Parallel narrowphase and contact prep (ROADMAP 17.54).

`SolverConfig.parallel_collision` fans `try_pair` and `make_contact` out
through `scheduler.dispatch`; the candidate order is kept, so every run
here compares a parallel scene with a serial one bit for bit (body state,
sleep flags and the contact cache).

Every scene has at least `NARROW_PAR_MIN` (256) candidate pairs, so the
parallel path really runs, except the extremes that test the cut-off.

  1. Ordinary: a 1024-box pile (columns of 1-4 boxes), workers 4.
  2. Integration: the same pile with island-parallel solve, colouring,
     CCD and the BVH broadphase all on; a heightfield terrain under hulls,
     spheres and boxes (uneven per-pair cost); every broadphase backend
     (its candidate list from the parallel query equals the serial one on
     1500 scattered boxes, and a 1090-body pile -- above `BP_PAR_MIN` --
     steps the same);
     the serial and reversed dispatchers (any execution order).
     200 CCD bullets at 40 m/s (above `CCD_PAR_MIN` fast movers) with the
     parallel, serial and reversed dispatchers.
  3. Extreme: 0 and 1 bodies, only statics, 40 boxes stacked on one point
     (780 candidate pairs in 49 chunks) run with 64 workers.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from scheduler.dispatch import Dispatch
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.body_set import BodyId
from physics.solver_config import SolverConfig
from collision.broadphase import BroadPhase, BruteForce
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase
from collision.bp_sap import SapBroadPhase
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_tree import OctreeBroadPhase
from collision.broadphase import Pair
from collision.contact_gen import collect_bp_pairs
from geometry.aabb import AABB
from physics.collide_par import pairs_parallel, BP_PAR_MIN

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _same[BP: BroadPhase](a: ContactScene6[QuatBody6, BP], b: ContactScene6[QuatBody6, BP]) -> Bool:
    if len(a.bset.bodies) != len(b.bset.bodies) or len(a.cache) != len(b.cache):
        return False
    for i in range(len(a.bset.bodies)):
        if (
            a.bset.bodies[i].pos != b.bset.bodies[i].pos
            or a.bset.bodies[i].vel != b.bset.bodies[i].vel
            or a.bset.bodies[i].omega != b.bset.bodies[i].omega
            or a.bset.bodies[i].q.x != b.bset.bodies[i].q.x
            or a.bset.bodies[i].q.y != b.bset.bodies[i].q.y
            or a.bset.bodies[i].q.z != b.bset.bodies[i].q.z
            or a.bset.bodies[i].q.w != b.bset.bodies[i].q.w
            or a.bset.sleeping[i] != b.bset.sleeping[i]
        ):
            return False
    for c in range(len(a.cache)):
        var p = a.cache[c]
        var q = b.cache[c]
        if p.a != q.a or p.b != q.b or p.feat != q.feat or p.m.count != q.m.count or p.m.normal != q.m.normal:
            return False
        for k in range(p.m.count):
            if p.acc[k] != q.acc[k] or p.acc_t1[k] != q.acc_t1[k] or p.m.depths[k] != q.m.depths[k]:
                return False
    return True


def _pile[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP], side: Int):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 40, 0.5, 40)), Vec3(40, 0.5, 40, 0), True)
    var k = 0
    var col = 0
    while k < side * side:
        var h = 1 + (col * 7) % 4
        var x = Real(col % side) * 0.55 - Real(side) * 0.275
        var z = Real(col // side) * 0.55 - Real(side) * 0.275
        for l in range(h):
            if k >= side * side:
                break
            _ = sc.add(QuatBody6.at_rest(Vec3(x, 0.25 + 0.52 * Real(l), z, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
            k += 1
        col += 1


def _cube(h: Real) -> List[Real]:
    var v = List[Real]()
    for c in range(8):
        v.append(h if c & 1 else -h)
        v.append(h if c & 2 else -h)
        v.append(h if c & 4 else -h)
    return v^


def _terrain[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP]) raises:
    var hs = List[Real]()
    for z in range(17):
        for x in range(17):
            hs.append(Real((x * 3 + z * 5) % 7) * 0.08)
    _ = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs, 17, 17, 1.0, -8, -8)
    for k in range(300):
        var p = Vec3(Real(k % 20) * 0.75 - 7.5, 1.2 + Real(k // 100) * 0.6, Real((k // 20) % 5) * 3 - 7.5 + Real(k // 100) * 0.4, 0)
        if k % 3 == 0:
            _ = sc.add_hull(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), _cube(0.2), False)
        elif k % 3 == 1:
            _ = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.2)), 0.2, False)
        else:
            _ = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)


def _shots(mut sc: ContactScene6[QuatBody6]) raises:
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.01, 0, 0), Inertia3.box(1, 20, 0.01, 20)), Vec3(20, 0.01, 20, 0), True)
    for k in range(200):
        var p = Vec3(Real(k % 20) * 0.9 - 9, 1.0 + Real(k // 20) * 0.3, Real((k * 7) % 20) * 0.9 - 9, 0)
        var id: BodyId
        if k % 3 == 0:
            id = sc.add_hull(QuatBody6.at_rest(p, Inertia3.box(1, 0.1, 0.1, 0.1)), _cube(0.1), False)
        elif k % 3 == 1:
            id = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.1)), 0.1, False)
        else:
            id = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
        sc.set_velocity(id, Vec3(0, -40, 0, 0), Vec3(0, 0, 0, 0))


def _cfg(par: Bool, workers: Int = 4) -> SolverConfig:
    var c = SolverConfig()
    c.parallel_collision = par
    c.workers = workers
    return c


def _run_pair[BP: BroadPhase](mut a: ContactScene6[QuatBody6, BP], mut b: ContactScene6[QuatBody6, BP], ca: SolverConfig, cb: SolverConfig, steps: Int) -> Bool:
    var ok = True
    for _ in range(steps):
        a.step(DT, G, ca)
        b.step(DT, G, cb)
        if not _same(a, b):
            ok = False
    return ok


def _boxes(n: Int) -> List[AABB[3]]:
    """n boxes of size 0.3-1.0 scattered in a 12 m cube (LCG), some coincident."""
    var out = List[AABB[3]]()
    var r = 12345
    for k in range(n):
        var v = List[Real]()
        for _ in range(4):
            r = (r * 1103515245 + 12345) % 2147483648
            v.append(Real(r % 10000) / 10000)
        var c = Vec3(v[0] * 12, v[1] * 12, v[2] * 12, 0) if k % 50 != 0 else Vec3(6, 6, 6, 0)
        var h = 0.15 + 0.35 * v[3]
        out.append(AABB[3](c - Vec3(h, h, h, 0), c + Vec3(h, h, h, 0)))
    return out^


def _backend[BP: BroadPhase](name: String, mut s: Suite) raises:
    # the candidate list itself: parallel query == serial `collect_bp_pairs`
    var b3 = _boxes(1500)
    var boxes = List[AABB[BP.dim]]()
    for k in range(len(b3)):
        boxes.append(rebind[AABB[BP.dim]](b3[k]))
    var st = List[Bool]()
    for k in range(1500):
        st.append(k % 7 == 0)
    var p1 = List[Pair]()
    var p2 = List[Pair]()
    var bp1 = BP()
    var bp2 = BP()
    collect_bp_pairs[BP](bp1, boxes, st, p1)
    pairs_parallel[BP](bp2, boxes, st, p2, 4, Dispatch.parallel())
    var same = len(p1) == len(p2)
    if same:
        for c in range(len(p1)):
            if p1[c].a != p2[c].a or p1[c].b != p2[c].b:
                same = False
    print("  " + name + ": 1500 boxes, candidate pairs serial", len(p1), " parallel", len(p2))
    s.check(same and len(p1) > 1000, name + " broadphase: parallel candidate list == serial (same pairs, same order)")
    # a whole scene above the cut-off (33 x 33 + floor = 1090 bodies)
    var a = ContactScene6[QuatBody6, BP]()
    var b = ContactScene6[QuatBody6, BP]()
    _pile(a, 33)
    _pile(b, 33)
    var ca = _cfg(False)
    ca.broadphase = True
    var cb = _cfg(True)
    cb.broadphase = True
    s.check(len(a.bset.bodies) >= BP_PAR_MIN and _run_pair(a, b, ca, cb, 10), name + " broadphase, 1090 bodies: parallel == serial")


def main() raises:
    var s = Suite("collide_par")

    var a = ContactScene6[QuatBody6]()
    var b = ContactScene6[QuatBody6]()
    _pile(a, 32)
    _pile(b, 32)
    s.check(_run_pair(a, b, _cfg(False), _cfg(True), 30), "1024-box pile, workers 4: parallel == serial (30 steps)")
    print("  1024-box pile: contacts", len(a.cache))

    var c = ContactScene6[QuatBody6]()
    var d = ContactScene6[QuatBody6]()
    _pile(c, 16)
    _pile(d, 16)
    var cc = _cfg(False)
    cc.parallel = True
    cc.colored = True
    cc.ccd = True
    cc.broadphase = True
    var cd = cc
    cd.parallel_collision = True
    s.check(_run_pair(c, d, cc, cd, 30), "island-parallel + coloured + CCD + BVH: parallel == serial")

    var t1 = ContactScene6[QuatBody6]()
    var t2 = ContactScene6[QuatBody6]()
    _terrain(t1)
    _terrain(t2)
    s.check(_run_pair(t1, t2, _cfg(False), _cfg(True), 60), "heightfield + 300 hulls / spheres / boxes: parallel == serial")
    print("  heightfield scene: contacts", len(t1.cache))

    # CCD: 200 bullets (boxes, spheres, hulls) at 40 m/s onto a 2 cm plate:
    # the fast movers' clamp fractions run through the dispatcher
    var bullets = List[Real]()
    for dk in range(3):
        var u = ContactScene6[QuatBody6]()
        var w = ContactScene6[QuatBody6]()
        _shots(u)
        _shots(w)
        var cu = _cfg(False)
        cu.ccd = True
        var cw = _cfg(True)
        cw.ccd = True
        if dk == 1:
            cw.dispatch = Dispatch.serial()
        elif dk == 2:
            cw.dispatch = Dispatch.reverse()
        s.check(_run_pair(u, w, cu, cw, 20), "200 CCD bullets through the dispatcher == serial (dispatch " + String(dk) + ")")
        if dk == 0:
            var lo = Real(9)
            for i in range(1, len(u.bset.bodies)):
                lo = min(lo, u.bset.bodies[i].pos[1])
            bullets.append(lo)
    print("  200 bullets at 40 m/s onto a 2 cm plate: lowest body y", bullets[0], "(plate top 0)")
    s.check(bullets[0] > -0.05, "no bullet tunnels the plate")

    _backend[BruteForce[3]]("brute", s)
    _backend[BVHBroadPhase[3]]("BVH", s)
    _backend[DbvhBroadPhase[3]]("DBVH", s)
    _backend[SapBroadPhase[3]]("SAP", s)
    _backend[SpatialHashBroadPhase[3]]("hash grid", s)
    _backend[OctreeBroadPhase]("octree", s)

    for dk in range(2):
        var e = ContactScene6[QuatBody6]()
        var f = ContactScene6[QuatBody6]()
        _pile(e, 18)
        _pile(f, 18)
        var cf = _cfg(True)
        cf.dispatch = Dispatch.serial() if dk == 0 else Dispatch.reverse()
        s.check(_run_pair(e, f, _cfg(False), cf, 20), ("serial" if dk == 0 else "reversed") + " dispatcher: == serial loop")

    # ---- extremes -------------------------------------------------------------
    var z1 = ContactScene6[QuatBody6]()
    var z2 = ContactScene6[QuatBody6]()
    s.check(_run_pair(z1, z2, _cfg(False), _cfg(True), 3), "no bodies")
    _ = z1.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    _ = z2.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    s.check(_run_pair(z1, z2, _cfg(False), _cfg(True), 3), "one body")
    var st1 = ContactScene6[QuatBody6]()
    var st2 = ContactScene6[QuatBody6]()
    for k in range(100):
        _ = st1.add(QuatBody6.at_rest(Vec3(Real(k) * 0.1, 0, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), True)
        _ = st2.add(QuatBody6.at_rest(Vec3(Real(k) * 0.1, 0, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), True)
    s.check(_run_pair(st1, st2, _cfg(False), _cfg(True), 3) and len(st1.cache) == 0, "only statics: no contacts either way")
    var p1 = ContactScene6[QuatBody6]()
    var p2 = ContactScene6[QuatBody6]()
    for k in range(40):
        var q = Vec3(Real(k) * 1e-3, 1, 0, 0)
        _ = p1.add(QuatBody6.at_rest(q, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        _ = p2.add(QuatBody6.at_rest(q, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    s.check(_run_pair(p1, p2, _cfg(False), _cfg(True, 64), 5), "40 boxes on one point (780 candidate pairs, 49 chunks) with 64 workers")
    s.finish()
