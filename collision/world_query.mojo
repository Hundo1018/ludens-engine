"""World queries against the REAL collider geometry (ROADMAP 17.13).

`collision.queries.SceneQuery` answers raycast/overlap against broadphase
`BoxProxy` boxes, so a ray that crosses a sphere's bounding box "hits" the
sphere. Gameplay (the character controller, vehicles, AI line-of-sight) needs
the actual surfaces. Everything here works on a `ColliderSet` plus one `Pose3`
per collider, so it stays in the collision layer and never sees a `Body6`;
`physics.solver6.ContactScene6` has thin wrappers that supply the poses.

One primitive carries almost all of it: `point_distance(cs, i, pose, p)`, the
signed distance from a world point to collider `i`, with the closest surface
point and the outward normal. Box, sphere and capsule are exact; a hull uses
its face planes, which is exact inside and a lower bound outside (never larger
than the true distance); trimesh and heightfield use their triangle
candidates near `p` and report `search` when nothing is within it -- also a
lower bound. Because every answer is a lower bound on the true distance, the
sweeps below can use **conservative advancement**: step along the direction by
the current clearance; the step can never jump through a surface.

- `ray_cast`: exact per kind where a closed form is cheap (slabs for a box,
  quadratic for a sphere, plane clipping for a hull, Moller-Trumbore for mesh
  triangles); capsules use conservative advancement.
- `sphere_cast`, `capsule_cast`: conservative advancement of a point / a
  segment inflated by a radius. The segment's clearance to a convex collider
  is the minimum over the segment of a convex function, found by golden-section
  search.
- `overlap_sphere`, `overlap_capsule`: colliders within the radius.
- `capsule_penetrations`: every collider a capsule overlaps, with the push-out
  normal and depth -- the depenetration input of a kinematic controller.
- `ray_cast_batch`: many rays against the same world.

Candidates are prefiltered by each collider's world AABB against the query's
swept box (a linear scan: the queries answer "which surfaces", the broadphase
seam answers "which boxes", and wiring the persistent broadphase in as the
prefilter is the scale step, noted in docs/ROADMAP.md 17.13).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.aabb import AABB
from .collider_set import (
    ColliderSet,
    Pose3,
    SHAPE_BOX,
    SHAPE_SPHERE,
    SHAPE_CAPSULE,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
)
from .trimesh import closest_point_on_triangle

comptime _EPS: Real = 1e-6
comptime _SKIN: Real = 1e-4
comptime _MAX_ITERS = 96


@fieldwise_init
struct QueryFilter(Copyable, ImplicitlyCopyable, Movable):
    """Which colliders a query sees: those whose category intersects `mask`,
    minus `ignore` (e.g. the querying body itself), sensors only if asked."""

    var mask: UInt32
    var ignore: Int
    var hit_sensors: Bool

    @staticmethod
    def all() -> Self:
        return Self(0xFFFFFFFF, -1, False)

    @staticmethod
    def ignoring(i: Int) -> Self:
        return Self(0xFFFFFFFF, i, False)


@fieldwise_init
struct Hit(Copyable, ImplicitlyCopyable, Movable):
    """A query result. `t` is the distance travelled along the (unit)
    direction; `normal` points out of the hit surface. `start_solid` marks a
    sweep that began already touching or penetrating (t == 0)."""

    var hit: Bool
    var body: Int
    var t: Real
    var point: Vec3
    var normal: Vec3
    var start_solid: Bool

    @staticmethod
    def miss() -> Self:
        return Self(False, -1, 0, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0), False)


@fieldwise_init
struct Probe(Copyable, ImplicitlyCopyable, Movable):
    """Signed distance from a point to one collider: negative inside."""

    var dist: Real
    var point: Vec3
    var normal: Vec3


@fieldwise_init
struct Penetration(Copyable, ImplicitlyCopyable, Movable):
    var body: Int
    var normal: Vec3  # push the query shape along this to separate
    var depth: Real
    var point: Vec3


# ------------------------------------------------------------ helpers


@always_inline
def _local(pose: Pose3, p: Vec3) -> Vec3:
    var d = p - pose.position
    return Vec3(dot(d, pose.axes[0]), dot(d, pose.axes[1]), dot(d, pose.axes[2]), 0)


@always_inline
def _world_dir(pose: Pose3, v: Vec3) -> Vec3:
    return pose.axes[0] * v[0] + pose.axes[1] * v[1] + pose.axes[2] * v[2]


@always_inline
def _world(pose: Pose3, v: Vec3) -> Vec3:
    return pose.position + _world_dir(pose, v)


@always_inline
def _unit_or_up(v: Vec3) -> Vec3:
    var l = length(v)
    if l > _EPS:
        return v / l
    return Vec3(0, 1, 0, 0)


def _passes(cs: ColliderSet, i: Int, f: QueryFilter) -> Bool:
    if i == f.ignore:
        return False
    if cs.sensor[i] and not f.hit_sensors:
        return False
    return (cs.category[i] & f.mask) != 0


def _world_box(cs: ColliderSet, i: Int, pose: Pose3) -> AABB[3]:
    return cs.fat_aabb(i, pose, Vec3(0, 0, 0, 0), 0)


def _candidates(
    cs: ColliderSet, poses: List[Pose3], box: AABB[3], f: QueryFilter
) -> List[Int]:
    var out = List[Int]()
    for i in range(len(cs.shape)):
        if not _passes(cs, i, f):
            continue
        if _world_box(cs, i, poses[i]).overlaps(box):
            out.append(i)
    return out^


def _box_around(a: Vec3, b: Vec3, r: Real) -> AABB[3]:
    var lo = Vec3(min(a[0], b[0]), min(a[1], b[1]), min(a[2], b[2]), 0)
    var hi = Vec3(max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]), 0)
    var w = Vec3(r, r, r, 0)
    return AABB[3](lo - w, hi + w)


def _segment_closest(p: Vec3, a: Vec3, b: Vec3) -> Vec3:
    var ab = b - a
    var l2 = dot(ab, ab)
    if l2 < _EPS * _EPS:
        return a
    var s = dot(p - a, ab) / l2
    s = max(Real(0), min(Real(1), s))
    return a + ab * s


def _capsule_segment(cs: ColliderSet, i: Int, pose: Pose3) -> Tuple[Vec3, Vec3]:
    var hl = cs.half[i][1]
    return (pose.position - pose.axes[1] * hl, pose.position + pose.axes[1] * hl)


# ------------------------------------------------------------ point distance


def point_distance(
    cs: ColliderSet, i: Int, pose: Pose3, p: Vec3, search: Real = 1e30
) -> Probe:
    """Signed distance from world point `p` to collider `i` (see module doc
    for which kinds are exact and which are lower bounds)."""
    var k = cs.shape[i]
    if k == SHAPE_SPHERE:
        var v = p - pose.position
        var n = _unit_or_up(v)
        var r = cs.half[i][0]
        return Probe(length(v) - r, pose.position + n * r, n)
    if k == SHAPE_CAPSULE:
        var seg = _capsule_segment(cs, i, pose)
        var c = _segment_closest(p, seg[0], seg[1])
        var v = p - c
        var n = _unit_or_up(v)
        var r = cs.half[i][0]
        return Probe(length(v) - r, c + n * r, n)
    if k == SHAPE_BOX:
        var lp = _local(pose, p)
        var h = cs.half[i]
        var q = Vec3(abs(lp[0]) - h[0], abs(lp[1]) - h[1], abs(lp[2]) - h[2], 0)
        if q[0] > 0 or q[1] > 0 or q[2] > 0:
            var cp = Vec3(
                max(-h[0], min(h[0], lp[0])),
                max(-h[1], min(h[1], lp[1])),
                max(-h[2], min(h[2], lp[2])),
                0,
            )
            var diff = lp - cp
            var d = length(diff)
            return Probe(d, _world(pose, cp), _world_dir(pose, _unit_or_up(diff)))
        var ax = 0
        if q[1] > q[ax]:
            ax = 1
        if q[2] > q[ax]:
            ax = 2
        var sgn = Real(1) if lp[ax] >= 0 else Real(-1)
        var cp = lp
        cp[ax] = sgn * h[ax]
        var ln = Vec3(0, 0, 0, 0)
        ln[ax] = sgn
        return Probe(q[ax], _world(pose, cp), _world_dir(pose, ln))
    if k == SHAPE_HULL:
        ref hs = cs.hulls[cs.hull_id[i]]
        var lp = _local(pose, p)
        var best = Real(-1e30)
        var best_n = Vec3(0, 1, 0, 0)
        for f in range(hs.nf()):
            var n = hs.face(f)
            var raw = dot(lp, n) - hs.face_offset(f)
            if raw > best:
                best = raw
                best_n = n
        var cp = lp - best_n * best
        return Probe(best, _world(pose, cp), _world_dir(pose, best_n))
    # TRIMESH / HEIGHTFIELD: unsigned distance to the nearest candidate
    # triangle within `search` (static level geometry: vertices are world).
    var r = min(search, Real(1e6))
    var w = Vec3(r, r, r, 0)
    var tris = List[Int]()
    cs.mesh_candidates(i, AABB[3](p - w, p + w), tris)
    var best = Probe(r, p, Vec3(0, 1, 0, 0))
    for c in range(len(tris)):
        var tri = cs.mesh_tri(i, tris[c])
        var a = tri.points[0]
        var b = tri.points[1]
        var cc = tri.points[2]
        var fnrm = cross(b - a, cc - a)
        if dot(fnrm, fnrm) < _EPS * _EPS:
            continue
        var cp = closest_point_on_triangle(p, a, b, cc)
        var d = length(p - cp)
        if d < best.dist:
            var n = (p - cp) / d if d > _EPS else _unit_or_up(fnrm)
            best = Probe(d, cp, n)
    return best


def nearest_surface(
    cs: ColliderSet,
    poses: List[Pose3],
    p: Vec3,
    f: QueryFilter,
    search: Real = 1.0,
) -> Tuple[Int, Probe]:
    """The collider whose surface is closest to world point `p` (smallest
    signed distance, lowest index on a tie) among those `f` lets through,
    with the `point_distance` probe against it. When none qualifies the index is
    -1 and the probe has `dist = 1e30`.

    This is the contact query for a POINT that belongs to something else (an
    articulated chain's foot, a particle): `probe.dist <= 0` means the point
    touches or is inside, `-probe.dist` is the depth and `probe.normal` the
    direction that pushes it out. Box, sphere, capsule and hull report a
    signed distance, so depth is meaningful; trimesh and heightfield report an
    unsigned distance within `search`, so they register only on touch (see the
    module doc)."""
    var best_i = -1
    var best = Probe(Real(1e30), p, Vec3(0, 1, 0, 0))
    for i in range(len(cs.shape)):
        if not _passes(cs, i, f):
            continue
        var pr = point_distance(cs, i, poses[i], p, search)
        if best_i < 0 or pr.dist < best.dist:
            best_i = i
            best = pr
    return (best_i, best)


def segment_distance(
    cs: ColliderSet, i: Int, pose: Pose3, a: Vec3, b: Vec3, search: Real = 1e30
) -> Tuple[Probe, Vec3]:
    """Minimum over the segment a-b of `point_distance`, and the segment point
    that attains it. Distance to a convex set is convex along a line, so a
    golden-section search finds the minimum (meshes: each triangle is convex;
    the search still returns a local minimum along a short query segment)."""
    if dot(b - a, b - a) < _EPS * _EPS:
        return (point_distance(cs, i, pose, a, search), a)
    comptime gr: Real = 0.6180339887
    var lo = Real(0)
    var hi = Real(1)
    var x1 = hi - gr * (hi - lo)
    var x2 = lo + gr * (hi - lo)
    var f1 = point_distance(cs, i, pose, a + (b - a) * x1, search).dist
    var f2 = point_distance(cs, i, pose, a + (b - a) * x2, search).dist
    for _ in range(32):
        if f1 < f2:
            hi = x2
            x2 = x1
            f2 = f1
            x1 = hi - gr * (hi - lo)
            f1 = point_distance(cs, i, pose, a + (b - a) * x1, search).dist
        else:
            lo = x1
            x1 = x2
            f1 = f2
            x2 = lo + gr * (hi - lo)
            f2 = point_distance(cs, i, pose, a + (b - a) * x2, search).dist
    var s = (lo + hi) * 0.5
    var best_p = a + (b - a) * s
    var best = point_distance(cs, i, pose, best_p, search)
    # endpoints: the minimum of a convex function on [0,1] may sit there
    var pa = point_distance(cs, i, pose, a, search)
    if pa.dist < best.dist:
        best = pa
        best_p = a
    var pb = point_distance(cs, i, pose, b, search)
    if pb.dist < best.dist:
        best = pb
        best_p = b
    return (best, best_p)


# ------------------------------------------------------------ overlaps


def overlap_capsule(
    cs: ColliderSet, poses: List[Pose3], a: Vec3, b: Vec3, r: Real, f: QueryFilter
) -> List[Int]:
    var out = List[Int]()
    for i in _candidates(cs, poses, _box_around(a, b, r), f):
        if segment_distance(cs, i, poses[i], a, b, r + _SKIN)[0].dist <= r:
            out.append(i)
    return out^


def overlap_sphere(
    cs: ColliderSet, poses: List[Pose3], c: Vec3, r: Real, f: QueryFilter
) -> List[Int]:
    return overlap_capsule(cs, poses, c, c, r, f)


def capsule_penetrations(
    cs: ColliderSet, poses: List[Pose3], a: Vec3, b: Vec3, r: Real, f: QueryFilter
) -> List[Penetration]:
    """Every collider the capsule a-b (radius r) overlaps, with the direction
    that pushes the capsule out and by how much."""
    var out = List[Penetration]()
    for i in _candidates(cs, poses, _box_around(a, b, r), f):
        var res = segment_distance(cs, i, poses[i], a, b, r + _SKIN)
        ref pr = res[0]
        if pr.dist < r:
            out.append(Penetration(i, pr.normal, r - pr.dist, pr.point))
    return out^


# ------------------------------------------------------------ sweeps


def capsule_cast(
    cs: ColliderSet,
    poses: List[Pose3],
    a: Vec3,
    b: Vec3,
    r: Real,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
) -> Hit:
    """First contact of a capsule (segment a-b, radius r) moving along unit
    `dir` for up to `max_t`, by conservative advancement."""
    var u = _unit_or_up(dir)
    var cands = _candidates(
        cs, poses, _box_around(a, b, r).merge(_box_around(a + u * max_t, b + u * max_t, r)), f
    )
    if len(cands) == 0:
        return Hit.miss()
    var t = Real(0)
    for it in range(_MAX_ITERS):
        var off = u * t
        var best_d = Real(1e30)
        var best = Hit.miss()
        var search = max_t - t + r + _SKIN
        for c in range(len(cands)):
            var i = cands[c]
            var res = segment_distance(cs, i, poses[i], a + off, b + off, search)
            var d = res[0].dist - r
            if d < best_d:
                best_d = d
                best = Hit(True, i, t, res[0].point, res[0].normal, False)
        if best_d <= _SKIN:
            if it == 0:
                best.start_solid = True
            return best
        t += best_d
        if t > max_t:
            return Hit.miss()
    return Hit.miss()


def sphere_cast(
    cs: ColliderSet,
    poses: List[Pose3],
    c: Vec3,
    r: Real,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
) -> Hit:
    return capsule_cast(cs, poses, c, c, r, dir, max_t, f)


# ------------------------------------------------------------ rays


def _ray_box(o: Vec3, d: Vec3, h: Vec3) -> Tuple[Real, Int, Real]:
    """Local-frame slab test: (t_enter, axis, sign); t_enter < 0 = miss."""
    var t0 = Real(-1e30)
    var t1 = Real(1e30)
    var ax = -1
    var sg = Real(1)
    for k in range(3):
        if abs(d[k]) < _EPS:
            if o[k] < -h[k] or o[k] > h[k]:
                return (Real(-1), -1, Real(1))
            continue
        var a = (-h[k] - o[k]) / d[k]
        var b = (h[k] - o[k]) / d[k]
        var s = Real(-1)
        if a > b:
            var tmp = a
            a = b
            b = tmp
            s = Real(1)
        if a > t0:
            t0 = a
            ax = k
            sg = s
        t1 = min(t1, b)
    if t0 > t1 or t1 < 0 or ax < 0 or t0 < 0:
        return (Real(-1), -1, Real(1))
    return (t0, ax, sg)


def _ray_triangle(o: Vec3, d: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Real:
    """Moller-Trumbore; returns t >= 0 or -1."""
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


def _ray_one(
    cs: ColliderSet, i: Int, pose: Pose3, o: Vec3, d: Vec3, max_t: Real
) -> Hit:
    var k = cs.shape[i]
    if k == SHAPE_SPHERE:
        var r = cs.half[i][0]
        var m = o - pose.position
        var bq = dot(m, d)
        var cq = dot(m, m) - r * r
        if cq > 0 and bq > 0:
            return Hit.miss()
        var disc = bq * bq - cq
        if disc < 0:
            return Hit.miss()
        var t = max(Real(0), -bq - sqrt(disc))
        if t > max_t:
            return Hit.miss()
        var p = o + d * t
        return Hit(True, i, t, p, _unit_or_up(p - pose.position), cq <= 0)
    if k == SHAPE_BOX:
        var lo = _local(pose, o)
        var ld = Vec3(dot(d, pose.axes[0]), dot(d, pose.axes[1]), dot(d, pose.axes[2]), 0)
        var h = cs.half[i]
        if abs(lo[0]) <= h[0] and abs(lo[1]) <= h[1] and abs(lo[2]) <= h[2]:
            return Hit(True, i, 0, o, _unit_or_up(-d), True)
        var res = _ray_box(lo, ld, h)
        if res[0] < 0 or res[0] > max_t:
            return Hit.miss()
        var ln = Vec3(0, 0, 0, 0)
        ln[res[1]] = res[2]
        return Hit(True, i, res[0], o + d * res[0], _world_dir(pose, ln), False)
    if k == SHAPE_HULL:
        ref hs = cs.hulls[cs.hull_id[i]]
        var lo = _local(pose, o)
        var ld = Vec3(dot(d, pose.axes[0]), dot(d, pose.axes[1]), dot(d, pose.axes[2]), 0)
        var t0 = Real(0)
        var t1 = max_t
        var n_enter = Vec3(0, 1, 0, 0)
        var entered = False
        for fi in range(hs.nf()):
            var n = hs.face(fi)
            var dn = dot(ld, n)
            var dist = hs.face_offset(fi) - dot(lo, n)
            if abs(dn) < _EPS:
                if dist < 0:
                    return Hit.miss()
                continue
            var t = dist / dn
            if dn < 0:
                if t > t0:
                    t0 = t
                    n_enter = n
                    entered = True
            else:
                t1 = min(t1, t)
            if t0 > t1:
                return Hit.miss()
        return Hit(True, i, t0, o + d * t0, _world_dir(pose, n_enter), not entered)
    if k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD:
        var end = o + d * max_t
        var tris = List[Int]()
        cs.mesh_candidates(i, _box_around(o, end, _SKIN), tris)
        var best = Hit.miss()
        best.t = max_t
        for c in range(len(tris)):
            var tri = cs.mesh_tri(i, tris[c])
            var t = _ray_triangle(o, d, tri.points[0], tri.points[1], tri.points[2])
            if t >= 0 and t <= best.t:
                var n = _unit_or_up(cross(tri.points[1] - tri.points[0], tri.points[2] - tri.points[0]))
                if dot(n, d) > 0:
                    n = -n
                best = Hit(True, i, t, o + d * t, n, False)
        return best if best.hit else Hit.miss()
    # CAPSULE: conservative advancement on this one collider
    var t = Real(0)
    for it in range(_MAX_ITERS):
        var pr = point_distance(cs, i, pose, o + d * t)
        if pr.dist <= _SKIN:
            return Hit(True, i, t, pr.point, pr.normal, it == 0 and pr.dist < 0)
        t += pr.dist
        if t > max_t:
            break
    return Hit.miss()


def ray_cast(
    cs: ColliderSet,
    poses: List[Pose3],
    origin: Vec3,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
) -> Hit:
    """Closest surface hit along unit `dir` within `max_t`."""
    var d = _unit_or_up(dir)
    var best = Hit.miss()
    best.t = max_t
    for i in _candidates(cs, poses, _box_around(origin, origin + d * max_t, 0), f):
        var h = _ray_one(cs, i, poses[i], origin, d, best.t)
        if h.hit and h.t <= best.t:
            best = h
    return best if best.hit else Hit.miss()


def ray_cast_batch(
    cs: ColliderSet,
    poses: List[Pose3],
    origins: List[Vec3],
    dirs: List[Vec3],
    max_t: Real,
    f: QueryFilter,
) -> List[Hit]:
    var out = List[Hit](capacity=len(origins))
    for k in range(len(origins)):
        out.append(ray_cast(cs, poses, origins[k], dirs[k], max_t, f))
    return out^
