# tier: integration
"""Query extensions (ROADMAP 17.53): convex shape casts / overlaps, closest
points, multi-hit and any-hit rays, hit metadata, one-sided meshes, ray
traversal of meshes and heightfields, the persistent prefilter and parallel
batches.

  1. Ordinary:
     - a 0.5 m box swept along +x into a hull step face at x = 3 stops at
       t = 3 - 0.25 - start (analytic), normal -x; swept down onto the step's
       top (y = 0.3) it stops at the analytic height;
     - three walls at x = 2, 5, 9: `ray_cast_all` returns them in order at
       t = 2 - r, 5 - r, 9 - r; `max_hits = 2` keeps the first two;
       `ray_cast_any` agrees with `ray_cast(...).hit`;
     - a ray onto a mesh triangle reports that triangle's index, barycentric
       weights summing to 1 that rebuild the hit point;
     - `closest_points` of two spheres is |c1 - c2| - r1 - r2 with witnesses
       on the surfaces; of a box and a mesh, the box's height over it.
  2. Integration:
     - 300 random rays into a 1250-triangle mesh and a 48 x 48 heightfield:
       the BVH / DDA traversal finds the same nearest triangle as a
       brute-force test of every triangle, t within 1e-5 relative (the
       test's own Moller-Trumbore copy is compiled apart from the package
       and rounds differently in the last bits);
     - 400 random rays over 300 random colliders: `ray_cast_indexed` (BVH
       prefilter) == `ray_cast` (linear scan), bit for bit;
     - `ray_cast_batch` with the parallel dispatcher == serial, bit for bit;
       `ray_cast_batch_in` reusing one index for two batches, and an index
       built with SAH instead of the default LBVH, give the same hits.
  3. Extreme: one-sided filter skips a triangle hit from behind; a shape cast
     starting in contact is `start_solid` at t = 0; zero-length cast; a cast
     with nothing in the way misses; `overlap_shape` finds exactly the boxes
     a query box touches; `shape_penetrations` of a rounded box 0.05 into a
     face gives that face's normal and 0.05.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot, cross, normalize
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.world_query import (
    QueryFilter, QueryShape, Hit, pose3_of, ray_cast, ray_cast_indexed, QueryIndex,
)
from scheduler.dispatch import Dispatch
from scheduler.rng import SplitMix64

comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _ray_tri(o: Vec3, d: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Real:
    var e1 = b - a
    var e2 = c - a
    var pv = cross(d, e2)
    var det = dot(e1, pv)
    if abs(det) < 1e-12:
        return -1
    var inv = 1 / det
    var tv = o - a
    var u = dot(tv, pv) * inv
    if u < 0 or u > 1:
        return -1
    var qv = cross(tv, e1)
    var v = dot(d, qv) * inv
    if v < 0 or u + v > 1:
        return -1
    var t = dot(e2, qv) * inv
    return t if t >= 0 else Real(-1)


def _rand_dir(mut rng: SplitMix64) -> Vec3:
    var v = Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0)
    var l = length(v)
    return v / l if l > 1e-3 else Vec3(0, -1, 0, 0)


def main() raises:
    var s = Suite("query_ext")

    # ---- shape cast against a hull step ---------------------------------
    var sc = ContactScene6[QuatBody6]()
    var step: List[Real] = [3, 0, -1, 5, 0, -1, 3, 0.3, -1, 5, 0.3, -1, 3, 0, 1, 5, 0, 1, 3, 0.3, 1, 5, 0.3, 1]
    var hid = sc.add_hull(_st(Vec3(0, 0, 0, 0)), step^, True)
    var box = QueryShape.box(Vec3(0.25, 0.25, 0.25, 0))
    var h1 = sc.shape_cast(box, pose3_of(Vec3(0, 0.2, 0, 0), Quat.identity()), Vec3(1, 0, 0, 0), 10, ALL)
    print("  box swept +x into the step face: t", h1.t, " normal", h1.normal[0], h1.normal[1], h1.normal[2])
    s.check(h1.hit and h1.body == hid.index() and abs(h1.t - 2.75) < 2e-3, "box sweep: t = 3 - 0.25 (analytic)")
    s.check(abs(h1.normal[0] + 1) < 1e-3, "box sweep: normal -x out of the step face")
    var h2 = sc.shape_cast(box, pose3_of(Vec3(4, 2, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0.3)), Vec3(0, -1, 0, 0), 10, ALL)
    print("  turned box dropped onto the step top: t", h2.t)
    s.check(h2.hit and abs(h2.t - (2 - 0.3 - 0.25)) < 2e-3, "box dropped onto the step top: t = 2 - 0.3 - 0.25")
    var miss = sc.shape_cast(box, pose3_of(Vec3(0, 3, 0, 0), Quat.identity()), Vec3(1, 0, 0, 0), 10, ALL)
    s.check(not miss.hit, "a cast with nothing in the way misses")
    var solid = sc.shape_cast(box, pose3_of(Vec3(2.76, 0.2, 0, 0), Quat.identity()), Vec3(1, 0, 0, 0), 1, ALL)
    s.check(solid.hit and solid.t == 0 and solid.start_solid, "a cast starting in contact: start_solid at t = 0")
    var zero = sc.shape_cast(box, pose3_of(Vec3(0, 0.2, 0, 0), Quat.identity()), Vec3(1, 0, 0, 0), 0, ALL)
    s.check(not zero.hit, "zero-length cast clear of everything misses")
    var sph = sc.shape_cast(QueryShape.sphere(0.5), pose3_of(Vec3(0, 0.2, 0, 0), Quat.identity()), Vec3(1, 0, 0, 0), 10, ALL)
    var ref_sph = sc.sphere_cast(Vec3(0, 0.2, 0, 0), 0.5, Vec3(1, 0, 0, 0), 10, ALL)
    s.check(abs(sph.t - ref_sph.t) < 2e-3, "sphere through shape_cast == sphere_cast")

    # ---- walls: all-hits / any-hit -------------------------------------
    var sw = ContactScene6[QuatBody6]()
    for x in [2, 5, 9]:
        _ = sw.add(_st(Vec3(Real(x) + 0.1, 0, 0, 0)), Vec3(0.1, 3, 3, 0), True)
    var all = sw.ray_cast_all(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 20, ALL)
    print("  ray through three walls: hits", len(all), " t", all[0].t if len(all) > 0 else -1, all[1].t if len(all) > 1 else -1, all[2].t if len(all) > 2 else -1)
    s.check(len(all) == 3 and abs(all[0].t - 2) < 1e-5 and abs(all[1].t - 5) < 1e-5 and abs(all[2].t - 9) < 1e-5, "ray_cast_all: three walls in order at 2, 5, 9")
    var two = sw.ray_cast_all(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 20, ALL, 2)
    s.check(len(two) == 2 and two[1].t < 6, "max_hits = 2 keeps the nearest two")
    s.check(sw.ray_cast_any(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 20, ALL) and not sw.ray_cast_any(Vec3(0, 0, 0, 0), Vec3(-1, 0, 0, 0), 20, ALL), "ray_cast_any agrees with ray_cast")

    # ---- mesh metadata, one-sided, traversal parity --------------------
    var mv = List[Real]()
    var mi = List[Int]()
    var n = 25
    for j in range(n + 1):
        for i in range(n + 1):
            var x = Real(i) * 0.8 - 10
            var z = Real(j) * 0.8 - 10
            mv.append(x)
            mv.append(0.4 * Real(((i * 7 + j * 3) % 5)) / 5)
            mv.append(z)
    for j in range(n):
        for i in range(n):
            var a = j * (n + 1) + i
            mi.append(a); mi.append(a + n + 1); mi.append(a + 1)
            mi.append(a + 1); mi.append(a + n + 1); mi.append(a + n + 2)
    var sm = ContactScene6[QuatBody6]()
    _ = sm.add_trimesh(_st(Vec3(0, 0, 0, 0)), mv, mi)
    var hm = sm.ray_cast(Vec3(0.3, 5, 0.2, 0), Vec3(0, -1, 0, 0), 20, ALL)
    var t0 = hm.feat
    var pa = Vec3(mv[3 * mi[3 * t0]], mv[3 * mi[3 * t0] + 1], mv[3 * mi[3 * t0] + 2], 0)
    var pb = Vec3(mv[3 * mi[3 * t0 + 1]], mv[3 * mi[3 * t0 + 1] + 1], mv[3 * mi[3 * t0 + 1] + 2], 0)
    var pc = Vec3(mv[3 * mi[3 * t0 + 2]], mv[3 * mi[3 * t0 + 2] + 1], mv[3 * mi[3 * t0 + 2] + 2], 0)
    var rebuilt = pa * hm.bary[0] + pb * hm.bary[1] + pc * hm.bary[2]
    s.check(hm.hit and t0 >= 0 and abs(hm.bary[0] + hm.bary[1] + hm.bary[2] - 1) < 1e-5 and length(rebuilt - hm.point) < 1e-4, "mesh hit: triangle index + barycentric weights rebuild the point")
    var below = sm.ray_cast(Vec3(0.3, -5, 0.2, 0), Vec3(0, 1, 0, 0), 20, ALL)
    var below1 = sm.ray_cast(Vec3(0.3, -5, 0.2, 0), Vec3(0, 1, 0, 0), 20, ALL.one_sided())
    s.check(below.hit and not below1.hit, "one-sided filter: the floor shot from below is skipped")

    var rng = SplitMix64.seeded(1753)
    var mesh_ok = 0
    for _ in range(300):
        var o = Vec3(Real(rng.next_f32()) * 24 - 12, Real(rng.next_f32()) * 6 + 0.5, Real(rng.next_f32()) * 24 - 12, 0)
        var d = _rand_dir(rng)
        if d[1] > -0.05:
            d = normalize(Vec3(d[0], -0.3 - Real(rng.next_f32()), d[2], 0))
        var h = sm.ray_cast(o, d, 40, ALL)
        var bt = Real(40)
        var btri = -1
        for t in range(len(mi) // 3):
            var a = Vec3(mv[3 * mi[3 * t]], mv[3 * mi[3 * t] + 1], mv[3 * mi[3 * t] + 2], 0)
            var b = Vec3(mv[3 * mi[3 * t + 1]], mv[3 * mi[3 * t + 1] + 1], mv[3 * mi[3 * t + 1] + 2], 0)
            var c = Vec3(mv[3 * mi[3 * t + 2]], mv[3 * mi[3 * t + 2] + 1], mv[3 * mi[3 * t + 2] + 2], 0)
            var tt = _ray_tri(o, d, a, b, c)
            if tt >= 0 and (tt < bt or (tt == bt and t < btri)):
                bt = tt
                btri = t
        if (btri < 0 and not h.hit) or (h.hit and h.feat == btri and abs(h.t - bt) <= 1e-5 * max(Real(1), bt)):
            mesh_ok += 1
    print("  mesh BVH traversal vs brute force:", mesh_ok, "/ 300 rays agree")
    s.eqi(mesh_ok, 300, "mesh: BVH ray traversal finds the brute-force triangle (300 rays)")

    var hh = List[Real]()
    var hn = 48
    for j in range(hn):
        for i in range(hn):
            hh.append(Real(0.5) * Real(((i * 13 + j * 7) % 11)) / 11)
    var sh = ContactScene6[QuatBody6]()
    var hfid = sh.add_heightfield(_st(Vec3(0, 0, 0, 0)), hh, hn, hn, 0.5, -12, -12)
    var hf_ok = 0
    for _ in range(300):
        var o = Vec3(Real(rng.next_f32()) * 30 - 15, Real(rng.next_f32()) * 4 + 0.6, Real(rng.next_f32()) * 30 - 15, 0)
        var d = _rand_dir(rng)
        if d[1] > -0.02:
            d = normalize(Vec3(d[0], -0.05 - 0.5 * Real(rng.next_f32()), d[2], 0))
        var h = sh.ray_cast(o, d, 60, ALL)
        var bt = Real(60)
        var btri = -1
        var nt = (hn - 1) * (hn - 1) * 2
        for t in range(nt):
            var tri = sh.colliders.mesh_tri(hfid.index(), t)
            var tt = _ray_tri(o, d, tri.points[0], tri.points[1], tri.points[2])
            if tt >= 0 and (tt < bt or (tt == bt and t < btri)):
                bt = tt
                btri = t
        if (btri < 0 and not h.hit) or (h.hit and h.feat == btri and abs(h.t - bt) <= 1e-5 * max(Real(1), bt)):
            hf_ok += 1
    print("  heightfield DDA vs brute force:", hf_ok, "/ 300 rays agree")
    s.eqi(hf_ok, 300, "heightfield: DDA traversal finds the brute-force triangle (300 rays)")

    # ---- closest points ------------------------------------------------
    var cp = ContactScene6[QuatBody6]()
    var s1 = cp.add_sphere(_st(Vec3(0, 0, 0, 0)), 0.5, True)
    var s2 = cp.add_sphere(_st(Vec3(3, 4, 0, 0)), 1.0, True)
    var dd = cp.closest_points(s1, s2)
    print("  two spheres: distance", dd.dist, " witnesses", dd.pa[0], dd.pa[1], " /", dd.pb[0], dd.pb[1])
    s.check(abs(dd.dist - 3.5) < 1e-5 and abs(length(dd.pa) - 0.5) < 1e-5 and abs(length(dd.pb - Vec3(3, 4, 0, 0)) - 1) < 1e-5, "closest_points: spheres |c1 - c2| - r1 - r2, witnesses on the surfaces")
    var bm = sm.add(_st(Vec3(0.3, 2, 0.2, 0)), Vec3(0.25, 0.25, 0.25, 0), True)
    var dm = sm.closest_points(bm, sm.bset.id_of(0), 5)
    var hdown = sm.ray_cast(Vec3(0.3, 1.74, 0.2, 0), Vec3(0, -1, 0, 0), 5, QueryFilter.ignoring(bm.index()))
    print("  box over the mesh: distance", dd.dist, dm.dist, " ray below the box centre", hdown.t)
    s.check(dm.dist > 0 and dm.dist <= hdown.t + 1e-4, "closest_points box-mesh: no farther than the surface straight below")

    # ---- overlap_shape -------------------------------------------------
    var so = ContactScene6[QuatBody6]()
    var o0 = so.add(_st(Vec3(0, 0, 0, 0)), Vec3(0.5, 0.5, 0.5, 0), True)
    var o1 = so.add(_st(Vec3(1.4, 0, 0, 0)), Vec3(0.5, 0.5, 0.5, 0), True)
    var o2 = so.add(_st(Vec3(3, 0, 0, 0)), Vec3(0.5, 0.5, 0.5, 0), True)
    var ov = so.overlap_shape(QueryShape.box(Vec3(0.3, 0.3, 0.3, 0)), pose3_of(Vec3(0.7, 0, 0, 0), Quat.identity()), ALL)
    s.check(len(ov) == 2 and ov[0] == o0.index() and ov[1] == o1.index(), "overlap_shape: exactly the two boxes the query box touches")
    # a rounded box (half 0.3, rounding 0.1) 0.05 into the third box's -x face: push -x by 0.05
    var pen = so.shape_penetrations(QueryShape.rounded_box(Vec3(0.3, 0.3, 0.3, 0), 0.1), pose3_of(Vec3(2.25, 0, 0, 0), Quat.identity()), ALL)
    print("  shape_penetrations: rounded box 0.05 into a face ->", len(pen), "entries, normal", pen[0].normal[0], pen[0].normal[1], pen[0].normal[2], " depth", pen[0].depth)
    s.check(len(pen) == 1 and pen[0].body == o2.index() and abs(pen[0].normal[0] + 1) < 1e-5 and abs(pen[0].depth - 0.05) < 1e-5, "shape_penetrations: rounded box 0.05 into a face -> -x, 0.05")

    # ---- prefilter parity and parallel batch ---------------------------
    var big = ContactScene6[QuatBody6]()
    for k in range(300):
        var p = Vec3(Real(rng.next_f32()) * 40 - 20, Real(rng.next_f32()) * 10, Real(rng.next_f32()) * 40 - 20, 0)
        var kind = k % 3
        if kind == 0:
            _ = big.add(_st(p), Vec3(0.2 + Real(rng.next_f32()), 0.3, 0.5, 0), True)
        elif kind == 1:
            _ = big.add_sphere(_st(p), 0.3 + Real(rng.next_f32()), True)
        else:
            _ = big.add_capsule(_st(p), 0.3, 0.8, True)
    var idx = big.query_index()
    var poses = big.query_poses()
    var same = 0
    var origins = List[Vec3]()
    var dirs = List[Vec3]()
    for _ in range(400):
        var o = Vec3(Real(rng.next_f32()) * 50 - 25, Real(rng.next_f32()) * 12 - 1, Real(rng.next_f32()) * 50 - 25, 0)
        var d = _rand_dir(rng)
        origins.append(o)
        dirs.append(d)
        var a = ray_cast(big.colliders, poses, o, d, 60, ALL)
        var b = ray_cast_indexed(big.colliders, idx, o, d, 60, ALL)
        if a.hit == b.hit and a.body == b.body and a.t == b.t:
            same += 1
    print("  BVH prefilter vs linear scan:", same, "/ 400 rays identical")
    s.eqi(same, 400, "ray_cast_indexed == ray_cast (400 rays, 300 colliders)")
    var ser = big.ray_cast_batch(origins, dirs, 60, ALL)
    var par = big.ray_cast_batch(origins, dirs, 60, ALL, Dispatch.parallel())
    var bsame = len(ser) == len(par)
    var nhit = 0
    for k in range(min(len(ser), len(par))):
        if ser[k].hit != par[k].hit or ser[k].body != par[k].body or ser[k].t != par[k].t:
            bsame = False
        if ser[k].hit:
            nhit += 1
    print("  batch of 400:", nhit, "hits; parallel == serial", bsame)
    s.check(bsame and nhit > 20, "ray_cast_batch: parallel dispatch == serial, bit for bit")
    # one index reused for two batches (parallel), and a SAH-built index: same hits
    var pre = big.query_index()
    var r1 = big.ray_cast_batch_in(pre, origins, dirs, 60, ALL, Dispatch.parallel())
    var r2 = big.ray_cast_batch_in(pre, origins, dirs, 60, ALL, Dispatch.parallel())
    var sah = QueryIndex(big.colliders, big.query_poses(), True, False)
    var rsame = True
    for k in range(len(ser)):
        var c = ray_cast_indexed(big.colliders, sah, origins[k], dirs[k], 60, ALL)
        if r1[k].t != ser[k].t or r2[k].t != ser[k].t or r1[k].body != ser[k].body or c.t != ser[k].t or c.body != ser[k].body:
            rsame = False
    s.check(rsame, "a reused index (two batches) and a SAH-built index give the serial batch's hits, bit for bit")
    s.finish()
