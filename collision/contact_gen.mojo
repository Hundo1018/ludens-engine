"""Contact generation over the `BroadPhase` seam (audit cluster 7, finding F2).

Two responsibilities, both narrowphase-shaped and both collision's (not
physics's) job:

  * candidate-pair enumeration through a `BroadPhase` instance -- rebuild it
    from this frame's fat AABBs, read its pairs, and reduce them to the exact
    canonical order the reference nested double loop visits pairs in
    (`i < j`, ascending), because that is what makes any backend swapped in
    bit-identical to the brute reference (`collect_bp_pairs`);
  * the per-pair / per-triangle narrowphase test against a `ColliderSet`,
    producing raw contact geometry (`try_pair`, `try_mesh_pair`).

What stays in physics: matching a new contact against last frame's
warm-start cache and preparing body-frame anchors / approach-speed prep for
restitution, because both need a `Body6` (`to_local`, `velocity_at`). This
module returns geometry only -- one manifold per touched feature, plus which
pairs were sensor overlaps -- so 17.13 scene queries and the 17.1 character
controller can call it without ever importing physics.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, length
from geometry.gjk import ConvexPoly
from geometry.aabb import AABB
from .collider_set import (
    ColliderSet, Pose3, SHAPE_TRIMESH, SHAPE_HEIGHTFIELD, SHAPE_SPHERE, SHAPE_CAPSULE, SHAPE_BOX, SHAPE_HULL,
    SHAPE_SDF, SHAPE_ELLIPSOID, SPEC_BASE, support_manifold,
)
from .broadphase import BroadPhase, BoxProxy, Pair
from .manifold import ContactManifold, _seg_seg_closest, spread4
from .trimesh import closest_point_on_triangle
from .hull import hull_manifold


@always_inline
def _is_mesh(k: Int) -> Bool:
    """Static triangle geometry (the `try_mesh_pair` kinds)."""
    return k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD


@fieldwise_init
struct RawContact(Copyable, ImplicitlyCopyable, Movable):
    """One manifold from the narrowphase: pair `(a, b)`, sub-feature `feat`
    (0 for shape-vs-shape, a triangle index for mesh contact), and the
    manifold itself -- geometry only, no accumulators, no anchors."""

    var a: Int
    var b: Int
    var feat: Int
    var m: ContactManifold[3]


def collect_bp_pairs[BP: BroadPhase](
    mut bp: BP, boxes: List[AABB[BP.dim]], statics: List[Bool], mut out: List[Pair]
) raises:
    """Rebuild `bp` from `boxes` (proxy == index into `boxes`, i.e. the body
    index), read its candidate pairs, and reduce them to the canonical order
    the nested double loop below would visit: each pair canonicalised to
    `a < b` (a `BroadPhase` backend is free to emit either order -- see
    `bp_sap.mojo`'s docstring), static-static pairs dropped, sorted ascending
    by `(a, b)`. This is the ONLY thing that makes swapping in any backend
    bit-identical to the brute reference: the Gauss-Seidel solve is order-
    dependent, so the pair sequence has to match exactly, not just the set."""
    var items = List[BoxProxy[BP.dim]]()
    for i in range(len(boxes)):
        items.append(BoxProxy[BP.dim](i, boxes[i]))
    bp.rebuild(items)
    var raw = List[Pair]()
    bp.pairs(raw)
    var keys = List[Int]()
    for c in range(len(raw)):
        var lo = min(raw[c].a, raw[c].b)
        var hi = max(raw[c].a, raw[c].b)
        if statics[lo] and statics[hi]:
            continue
        keys.append((lo << 32) | hi)
    sort(keys)
    for c in range(len(keys)):
        out.append(Pair(keys[c] >> 32, keys[c] & 0xFFFFFFFF))


def speculative_margin(
    vel_a: Vec3, vel_b: Vec3, spec_dt: Real, base: Real = SPEC_BASE
) -> Real:
    """The per-pair speculative margin (0 outside CCD): `base` (default
    `SPEC_BASE`; `SolverConfig.margin_base`, scaled by `UnitScale`, ROADMAP
    17.75) plus how far the pair could close together this step."""
    if spec_dt <= 0:
        return 0
    return base + (sqrt(dot(vel_a, vel_a)) + sqrt(dot(vel_b, vel_b))) * spec_dt


def _near_segment(p: Vec3, a: Vec3, b: Vec3, tol: Real) -> Bool:
    var ab = b - a
    var l2 = dot(ab, ab)
    var t = Real(0)
    if l2 > 0:
        t = min(max(dot(p - a, ab) / l2, 0), 1)
    var d = p - (a + ab * t)
    return dot(d, d) <= tol * tol


def _fix_inactive_edge_normal(
    mut m: ContactManifold[3], tri: ConvexPoly[3], face_n: Vec3, act: UInt8
):
    """Ghost-collision guard (ROADMAP 17.45, Jolt's active edges / Bullet's
    internal-edge utility): a body sliding over a flat seam between two
    coplanar triangles can be given the seam's EDGE normal (the hull
    narrowphase sees the triangle alone and does not know its neighbour
    continues the plane), which kicks the body upward and stops it. When the
    manifold normal is not the face normal and none of its points lies on an
    ACTIVE edge (a real crease or a boundary) of this triangle, the face
    normal replaces it and each depth becomes its component along the face
    normal."""
    var want = -face_n  # manifold normals point body -> mesh
    var c = dot(m.normal, want)
    if c >= Real(0.9999):
        return
    var v0 = tri.points[0]
    var v1 = tri.points[1]
    var v2 = tri.points[2]
    var scale = max(length(v1 - v0), max(length(v2 - v1), length(v0 - v2)))
    var tol = scale * Real(0.02)
    for k in range(m.count):
        var p = m.points[k]
        if (act & 1) and _near_segment(p, v0, v1, tol):
            return
        if (act & 2) and _near_segment(p, v1, v2, tol):
            return
        if (act & 4) and _near_segment(p, v2, v0, tol):
            return
    m.normal = want
    var proj = max(c, Real(0))
    for k in range(m.count):
        m.depths[k] = m.depths[k] * proj


def sphere_triangle_manifold(
    c: Vec3, r: Real, margin: Real, v0: Vec3, v1: Vec3, v2: Vec3, face_n: Vec3
) -> ContactManifold[3]:
    """Analytic sphere vs one mesh triangle (ROADMAP 17.45): the closest point
    on the triangle, normal from the centre toward it (body -> mesh), depth
    r - distance (negative within `margin`: speculative). Single-sided like
    the rest of the mesh: a centre behind the triangle's plane is a miss."""
    if dot(c - v0, face_n) < 0:
        return ContactManifold[3].miss()
    var q = closest_point_on_triangle(c, v0, v1, v2)
    var dv = q - c
    var d2 = dot(dv, dv)
    var reach = r + margin
    if d2 > reach * reach:
        return ContactManifold[3].miss()
    var d = sqrt(d2)
    var n = dv / d if d > 1e-9 else -face_n
    var m = ContactManifold[3].hit_along(n)
    m.add(q, r - d)
    return m


def capsule_triangle_manifold(
    p0: Vec3, p1: Vec3, r: Real, margin: Real, v0: Vec3, v1: Vec3, v2: Vec3, face_n: Vec3
) -> ContactManifold[3]:
    """Analytic capsule (segment p0-p1, radius r) vs one mesh triangle: up to
    two points -- the segment's endpoints when they reach the triangle (a
    capsule lying on a face rests on both), otherwise the closest segment /
    triangle pair (segment vs each edge, or the segment piercing the face).
    One normal for the manifold, from the deepest pair."""
    var reach = r + margin
    var ss = List[Vec3]()
    var qs = List[Vec3]()
    var ds = List[Real]()
    for e in range(2):
        var p = p0 if e == 0 else p1
        if dot(p - v0, face_n) < 0:
            continue
        var q = closest_point_on_triangle(p, v0, v1, v2)
        var dd = length(q - p)
        if dd <= reach:
            ss.append(p)
            qs.append(q)
            ds.append(dd)
    if len(ss) < 2:
        # the segment's own closest approach: vs the three edges, and the
        # point where it pierces the face (distance 0) if it does
        var best_s = p0
        var best_q = p0
        var best_d = Real(1e30)
        for k in range(3):
            var ea = v0 if k == 0 else (v1 if k == 1 else v2)
            var eb = v1 if k == 0 else (v2 if k == 1 else v0)
            var pr = _seg_seg_closest(p0, p1, ea, eb)
            var dd = length(pr[1] - pr[0])
            if dd < best_d:
                best_d = dd
                best_s = pr[0]
                best_q = pr[1]
        var s0 = dot(p0 - v0, face_n)
        var s1 = dot(p1 - v0, face_n)
        if s0 * s1 < 0:
            var x = p0 + (p1 - p0) * (s0 / (s0 - s1))
            var on = closest_point_on_triangle(x, v0, v1, v2)
            if length(on - x) < 1e-6:
                best_s = x
                best_q = x
                best_d = 0
        if best_d <= reach and dot(best_s - v0, face_n) >= -r:
            var dup = False
            for k in range(len(ss)):
                if length(ss[k] - best_s) < r * 0.2:
                    dup = True
            if not dup:
                ss.append(best_s)
                qs.append(best_q)
                ds.append(best_d)
    if len(ss) == 0:
        return ContactManifold[3].miss()
    var deep = 0
    for k in range(len(ds)):
        if ds[k] < ds[deep]:
            deep = k
    var dv = qs[deep] - ss[deep]
    var n = dv / ds[deep] if ds[deep] > 1e-9 else -face_n
    var m = ContactManifold[3].hit_along(n)
    m.add(qs[deep], r - ds[deep])
    for k in range(len(ss)):
        if k != deep and m.count < 2:
            m.add(qs[k], r - ds[k])
    return m


def _round_on_flat_seam(
    mut m: ContactManifold[3], tri: ConvexPoly[3], face_n: Vec3, act: UInt8, c: Vec3, r: Real
):
    """A sphere whose closest point on this triangle is an INACTIVE edge or
    vertex (a flat seam to a coplanar neighbour) gets the face normal and its
    height above the plane instead of the tilted centre-to-edge normal. With
    the tilted normal, the neighbour ahead of a rolling ball becomes a
    speculative contact the ball approaches along a forward-down direction,
    and the solver brakes it there (measured: a ball rolling at 3 m/s over a
    400-quad floor lost 1 m/s and hopped at 0.56 m/s)."""
    var want = -face_n
    if dot(m.normal, want) >= Real(0.9999):
        return
    var v0 = tri.points[0]
    var v1 = tri.points[1]
    var v2 = tri.points[2]
    var scale = max(length(v1 - v0), max(length(v2 - v1), length(v0 - v2)))
    var tol = scale * Real(0.02)
    var p = m.points[0]
    if (act & 1) and _near_segment(p, v0, v1, tol):
        return
    if (act & 2) and _near_segment(p, v1, v2, tol):
        return
    if (act & 4) and _near_segment(p, v2, v0, tol):
        return
    var h = dot(c - v0, face_n)
    m.normal = want
    m.points[0] = c - face_n * h
    m.depths[0] = r - h


def try_mesh_pair(
    colliders: ColliderSet, i: Int, j: Int,
    pose_i: Pose3, pose_j: Pose3, margin: Real, mut out: List[RawContact],
):
    """Contact against static level geometry.

    Unlike every other pair, this emits MORE THAN ONE manifold: a crate
    landing in a valley rests on several triangles, and collapsing them into
    one contact would pick a single normal for a surface that has two. Each
    triangle therefore becomes its own `RawContact`, keyed by triangle index
    so physics's warm-start cache stays per-triangle across frames."""
    var a = i  # the dynamic body
    var b = j  # the static mesh
    var pa = pose_i.copy()
    if _is_mesh(colliders.shape[i]):
        a = j
        b = i
        pa = pose_j.copy()
    if _is_mesh(colliders.shape[a]) or colliders.shape[a] == SHAPE_SDF:
        return  # mesh vs mesh / SDF: two static bodies, nothing to resolve

    # The speculative margin is split half-and-half between the two shapes
    # everywhere else, and the full margin is subtracted from the depth
    # afterwards. A triangle has no thickness to inflate, so the dynamic body
    # carries the WHOLE margin here (see `physics.solver6`'s original note:
    # inflating it by half instead leaves the body resting margin/2 too deep).
    var mr = margin
    var wide = Vec3(margin, margin, margin, 0)

    var box = colliders.fat_aabb(a, pa, Vec3(0, 0, 0, 0), 0)
    var lo = box.min - wide
    var hi = box.max + wide
    var tris = List[Int]()
    colliders.mesh_candidates(b, AABB[3](lo, hi), tris)
    if len(tris) == 0:
        return

    # ROADMAP 17.52: an ellipsoid meets each triangle through its exact
    # support mapping (one point per triangle, like the sphere)
    var ka = colliders.shape[a]
    if ka == SHAPE_ELLIPSOID:
        var se = colliders.support_ellipsoid(a, pa)
        for c in range(len(tris)):
            var t = tris[c]
            var tf = colliders.mesh_tri_faces(b, t)
            if len(tf) < 3:
                continue
            var tri = colliders.mesh_tri(b, t)
            var m = support_manifold(se, tri, margin)
            if not m.hit:
                continue
            for k in range(m.count):
                m.depths[k] -= margin
            var act = colliders.mesh_active(b, t)
            if act != 7:
                _fix_inactive_edge_normal(m, tri, Vec3(tf[0], tf[1], tf[2], 0), act)
            out.append(RawContact(a, b, t, m))
        return

    # ROADMAP 17.45: spheres and capsules meet triangles analytically (they
    # used to go through `as_hull` as a box, so a ball sat on a slope like a
    # cube instead of rolling down it).
    if ka == SHAPE_SPHERE or ka == SHAPE_CAPSULE:
        var r = colliders.half[a][0]
        var hl = colliders.half[a][1]
        var axis = pa.axes[1]
        for c in range(len(tris)):
            var t = tris[c]
            var tf = colliders.mesh_tri_faces(b, t)
            if len(tf) < 3:
                continue
            var tri = colliders.mesh_tri(b, t)
            var fnrm = Vec3(tf[0], tf[1], tf[2], 0)
            var m: ContactManifold[3]
            if ka == SHAPE_SPHERE:
                m = sphere_triangle_manifold(pa.position, r, margin, tri.points[0], tri.points[1], tri.points[2], fnrm)
            else:
                m = capsule_triangle_manifold(
                    pa.position - axis * hl, pa.position + axis * hl, r, margin,
                    tri.points[0], tri.points[1], tri.points[2], fnrm,
                )
            if not m.hit:
                continue
            var act = colliders.mesh_active(b, t)
            if act != 7:
                if ka == SHAPE_SPHERE:
                    _round_on_flat_seam(m, tri, fnrm, act, pa.position, r)
                else:
                    _fix_inactive_edge_normal(m, tri, fnrm, act)
            out.append(RawContact(a, b, t, m))
        return

    # a HULL body is not inflated (see `hull_manifold`): the whole margin goes
    # to the narrowphase as its speculative distance instead
    var a_is_hull = colliders.hull_is_bent_by_inflation(a)
    var zero = Vec3(0, 0, 0, 0)
    var spec = margin if a_is_hull else Real(0)
    var poly_a = colliders.as_hull(a, pa, zero if a_is_hull else wide, Real(0) if a_is_hull else mr)
    var faces_a = colliders.hull_faces(a, pa, zero if a_is_hull else wide, Real(0) if a_is_hull else mr)
    for c in range(len(tris)):
        var t = tris[c]
        var tf = colliders.mesh_tri_faces(b, t)
        if len(tf) < 3:
            continue  # degenerate triangle: no normal, no contact
        var tri = colliders.mesh_tri(b, t)
        var m = hull_manifold(poly_a, tri, faces_a, tf, spec)
        if not m.hit:
            continue
        var act = colliders.mesh_active(b, t)
        if act != 7:
            _fix_inactive_edge_normal(m, tri, Vec3(tf[0], tf[1], tf[2], 0), act)
        if spec > 0:
            for k in range(m.count):
                m.depths[k] += spec
        if margin > 0:
            for k in range(m.count):
                m.depths[k] -= margin
        out.append(RawContact(a, b, t, m))


def _sdf_samples(colliders: ColliderSet, i: Int, pose: Pose3) -> Tuple[List[Vec3], Real]:
    """World sample points (and the radius around each) at which a convex
    collider meets an SDF (ROADMAP 17.52): a sphere's centre; five points
    along a capsule's segment; a box's 8 corners, 12 edge midpoints and 6
    face centres; a hull's vertices. Empty for static mesh kinds."""
    var k = colliders.shape[i]
    var out = List[Vec3]()
    var h = colliders.half[i]
    if k == SHAPE_SPHERE:
        out.append(pose.position)
        return (out^, h[0])
    if k == SHAPE_CAPSULE:
        for s in range(5):
            var t = Real(s) / 4 * 2 - 1
            out.append(pose.position + pose.axes[1] * (h[1] * t))
        return (out^, h[0])
    if k == SHAPE_BOX:
        for x in range(3):
            for y in range(3):
                for z in range(3):
                    if x == 1 and y == 1 and z == 1:
                        continue
                    var nz = Int(x != 1) + Int(y != 1) + Int(z != 1)
                    if nz < 1:
                        continue
                    var l = Vec3(Real(x - 1) * h[0], Real(y - 1) * h[1], Real(z - 1) * h[2], 0)
                    out.append(pose.position + pose.axes[0] * l[0] + pose.axes[1] * l[1] + pose.axes[2] * l[2])
        return (out^, Real(0))
    if k == SHAPE_HULL:
        ref hs = colliders.hulls[colliders.hull_id[i]]
        for v in range(hs.nv()):
            var l = hs.vert(v)
            out.append(pose.position + pose.axes[0] * l[0] + pose.axes[1] * l[1] + pose.axes[2] * l[2])
        return (out^, Real(0))
    return (out^, Real(0))


def try_sdf_pair(
    colliders: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3,
    margin: Real, mut out: List[RawContact],
):
    """Convex collider vs static SDF (ROADMAP 17.52): every sample point of
    the convex side (`_sdf_samples`) closer to the grid's surface than its
    radius + `margin` is a candidate (depth = radius - distance, positive
    when penetrating); up to four are kept with the same spread rule as the
    hull path (`hull.spread4`), and the manifold normal is the depth-weighted
    mean of their grid gradients. So the patch follows the field: a box
    resting on a flat SDF gets four corner contacts whatever the grid's
    resolution. Two SDFs, or an SDF and a mesh, never pair (both static)."""
    var si = i if colliders.shape[i] == SHAPE_SDF else j
    var di = j if si == i else i
    var dk = colliders.shape[di]
    if _is_mesh(dk) or dk == SHAPE_SDF:
        return
    ref g = colliders.sdfs[colliders.mesh_id[si]]
    var dpose = pose_j.copy() if di == j else pose_i.copy()
    var smp = _sdf_samples(colliders, di, dpose)
    var pts = smp[0].copy()
    if dk == SHAPE_ELLIPSOID:
        # one point: the ellipsoid's support against the field gradient,
        # refined once at the point it lands on (17.52)
        var se = colliders.support_ellipsoid(di, dpose)
        var gc = g.gradient(dpose.position)
        var gl0 = sqrt(dot(gc, gc))
        var n0 = gc / gl0 if gl0 > 1e-12 else Vec3(0, 1, 0, 0)
        var q = se.support_point(-n0)
        var gq = g.gradient(q)
        var gl1 = sqrt(dot(gq, gq))
        if gl1 > 1e-12:
            q = se.support_point(-(gq / gl1))
        pts.append(q)
    var r = smp[1]
    var cand = List[Vec3]()
    var cdep = List[Real]()
    var nsum = Vec3(0, 0, 0, 0)
    for k in range(len(pts)):
        var p = pts[k]
        var d = g.distance(p)
        if d >= r + margin:
            continue
        var gr = g.gradient(p)
        var gl = sqrt(dot(gr, gr))
        if gl < 1e-12:
            continue
        var n = gr / gl  # out of the SDF, toward the convex body
        var depth = r - d
        cand.append(p - n * (r - depth * 0.5))  # midway between the two surfaces
        cdep.append(depth)
        nsum = nsum + n * max(depth + margin, Real(1e-6))
    if len(cand) == 0:
        return
    var nl = sqrt(dot(nsum, nsum))
    if nl < 1e-12:
        return
    var n_out = nsum / nl
    # manifold normal points from a to b: toward the SDF when a is the convex side
    var n_ab = n_out if si == i else -n_out
    var pick = spread4(cand, cdep, n_out)
    var m = ContactManifold[3].hit_along(n_ab)
    for k in range(len(pick)):
        m.add(cand[pick[k]], cdep[pick[k]])
    out.append(RawContact(i, j, 0, m))


def try_pair(
    colliders: ColliderSet, i: Int, j: Int,
    pose_i: Pose3, pose_j: Pose3, vel_i: Vec3, vel_j: Vec3, spec_dt: Real,
    mut out: List[RawContact], mut sensors: List[RawContact],
    margin_base: Real = SPEC_BASE,
):
    """The per-pair body of the candidate enumeration: filtering, mesh vs
    non-mesh dispatch, sensor short-circuit, speculative manifold. Extracted
    so both the brute loop and the broadphase enumeration in physics feed the
    IDENTICAL logic (parity).

    The MESH check runs first, before the sensor short-circuit (17.0f / F4a):
    a sensor overlapping a static mesh/heightfield goes through the same
    triangle-candidate path (`try_mesh_pair`) as a solid body, just with zero
    margin and its raw contacts routed to `sensors` instead of `out` (no
    impulse, matching `set_sensor`'s contract) -- rather than reaching
    `pair_manifold` directly and falling into its capsule-capsule catch-all,
    which used to report overlap against the mesh's conservative bounding
    capsule instead of its real triangles."""
    if not colliders.should_collide(i, j):
        return
    var margin = speculative_margin(vel_i, vel_j, spec_dt, margin_base)
    var infl = Vec3(margin * 0.5, margin * 0.5, margin * 0.5, 0)
    var is_sensor_pair = colliders.is_sensor(i) or colliders.is_sensor(j)

    if colliders.shape[i] == SHAPE_SDF or colliders.shape[j] == SHAPE_SDF:
        if is_sensor_pair:
            try_sdf_pair(colliders, i, j, pose_i, pose_j, 0, sensors)
        else:
            try_sdf_pair(colliders, i, j, pose_i, pose_j, margin, out)
        return

    if _is_mesh(colliders.shape[i]) or _is_mesh(colliders.shape[j]):
        if is_sensor_pair:
            # No speculative margin, same reasoning as the non-mesh sensor
            # branch below: a trigger fires on actual overlap, not early.
            try_mesh_pair(colliders, i, j, pose_i, pose_j, 0, sensors)
        else:
            try_mesh_pair(colliders, i, j, pose_i, pose_j, margin, out)
        return

    if is_sensor_pair:
        # No speculative margin: a trigger should fire when the shapes
        # actually overlap, not a margin early, and there is no impulse for
        # the margin to smooth out anyway.
        var sm = colliders.pair_manifold(i, j, pose_i, pose_j, 0, Vec3(0, 0, 0, 0))
        if sm.hit:
            sensors.append(RawContact(i, j, 0, sm))
        return

    var m = colliders.pair_manifold(i, j, pose_i, pose_j, margin * 0.5, infl)
    if m.hit and margin > 0:
        for k in range(m.count):
            m.depths[k] -= margin
    if m.hit:
        out.append(RawContact(i, j, 0, m))
