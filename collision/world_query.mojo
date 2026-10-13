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
from geometry.quat import Quat
from geometry.gjk_distance import ConvexDistance, convex_distance
from .manifold import Axes3
from .collider_set import (
    ColliderSet,
    Pose3,
    SHAPE_BOX,
    SHAPE_SPHERE,
    SHAPE_CAPSULE,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
    SHAPE_SDF,
)
from .trimesh import closest_point_on_triangle
from spatial.bvh import BVH
from geometry.ray import Ray

comptime _EPS: Real = 1e-6
comptime _SKIN: Real = 1e-4
comptime _MAX_ITERS = 96


struct QueryFilter(Copyable, ImplicitlyCopyable, Movable):
    """Which colliders a query sees: those whose category intersects `mask`,
    minus `ignore` (e.g. the querying body itself), sensors only if asked.
    `backfaces` False makes rays skip mesh triangles hit from behind
    (ROADMAP 17.53: a one-sided wall shot from its back is not hit)."""

    var mask: UInt32
    var ignore: Int
    var hit_sensors: Bool
    var backfaces: Bool

    def __init__(out self, mask: UInt32, ignore: Int, hit_sensors: Bool):
        self.mask = mask
        self.ignore = ignore
        self.hit_sensors = hit_sensors
        self.backfaces = True

    def one_sided(self) -> Self:
        var f = self
        f.backfaces = False
        return f

    @staticmethod
    def all() -> Self:
        return Self(0xFFFFFFFF, -1, False)

    @staticmethod
    def ignoring(i: Int) -> Self:
        return Self(0xFFFFFFFF, i, False)


struct Hit(Copyable, ImplicitlyCopyable, Movable):
    """A query result. `t` is the distance travelled along the (unit)
    direction; `normal` points out of the hit surface. `start_solid` marks a
    sweep that began already touching or penetrating (t == 0). For a mesh or
    heightfield hit, `feat` is the triangle index and `bary` the point's
    barycentric weights on the triangle's corners (ROADMAP 17.53); -1 / 0
    otherwise."""

    var hit: Bool
    var body: Int
    var t: Real
    var point: Vec3
    var normal: Vec3
    var start_solid: Bool
    var feat: Int
    var bary: Vec3

    def __init__(
        out self, hit: Bool, body: Int, t: Real, point: Vec3, normal: Vec3, start_solid: Bool,
        feat: Int = -1, bary: Vec3 = Vec3(0, 0, 0, 0),
    ):
        self.hit = hit
        self.body = body
        self.t = t
        self.point = point
        self.normal = normal
        self.start_solid = start_solid
        self.feat = feat
        self.bary = bary

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
    if k == SHAPE_SDF:  # ROADMAP 17.52: the grid's own trilinear distance
        ref g = cs.sdfs[cs.mesh_id[i]]
        var d = g.distance(p)
        var gr = g.gradient(p)
        var gl = length(gr)
        var n = gr / gl if gl > _EPS else Vec3(0, 1, 0, 0)
        return Probe(d, p - n * d, n)
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


def _ray_triangle_uv(o: Vec3, d: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Tuple[Real, Real, Real]:
    """Moller-Trumbore: (t, u, v) with the hit at a + u (b - a) + v (c - a);
    t = -1 for a miss."""
    var e1 = b - a
    var e2 = c - a
    var pv = cross(d, e2)
    var det = dot(e1, pv)
    if abs(det) < 1e-12:
        return (Real(-1), Real(0), Real(0))
    var inv = 1 / det
    var tv = o - a
    var u = dot(tv, pv) * inv
    if u < 0 or u > 1:
        return (Real(-1), Real(0), Real(0))
    var qv = cross(tv, e1)
    var v = dot(d, qv) * inv
    if v < 0 or u + v > 1:
        return (Real(-1), Real(0), Real(0))
    var t = dot(e2, qv) * inv
    return (t if t >= 0 else Real(-1), u, v)


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


def _ray_mesh(
    cs: ColliderSet, i: Int, o: Vec3, d: Vec3, max_t: Real, backfaces: Bool,
    mut all: List[Hit], collect: Bool,
) -> Hit:
    """Triangles of mesh / heightfield `i` along the ray (BVH descent / grid
    DDA, `ColliderSet.mesh_ray_candidates`). Returns the nearest hit; with
    `collect`, also appends every triangle hit to `all`. Ties at equal `t`
    keep the lowest triangle index, so the answer does not depend on the
    order candidates arrive in."""
    var tris = List[Int]()
    cs.mesh_ray_candidates(i, o, d, max_t, tris)
    var best = Hit.miss()
    best.t = max_t
    for c in range(len(tris)):
        var tri = cs.mesh_tri(i, tris[c])
        var a = tri.points[0]
        var b = tri.points[1]
        var cc = tri.points[2]
        var r = _ray_triangle_uv(o, d, a, b, cc)
        var t = r[0]
        if t < 0 or t > max_t:
            continue
        var fnrm = cross(b - a, cc - a)
        if dot(fnrm, fnrm) < _EPS * _EPS:
            continue
        var n = _unit_or_up(fnrm)
        if dot(n, d) > 0:
            if not backfaces:
                continue
            n = -n
        var h = Hit(True, i, t, o + d * t, n, False, tris[c], Vec3(1 - r[1] - r[2], r[1], r[2], 0))
        if collect:
            all.append(h)
        if t < best.t or (t == best.t and best.hit and tris[c] < best.feat) or (t == best.t and not best.hit):
            best = h
    return best if best.hit else Hit.miss()


def _ray_one(
    cs: ColliderSet, i: Int, pose: Pose3, o: Vec3, d: Vec3, max_t: Real,
    backfaces: Bool = True,
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
        var none = List[Hit]()
        return _ray_mesh(cs, i, o, d, max_t, backfaces, none, False)
    if k == SHAPE_SDF:
        # sphere tracing on the grid (17.52); the trilinear distance is not
        # exactly 1-Lipschitz, so steps are taken at 0.9 of it
        var t = Real(0)
        for it in range(_MAX_ITERS * 4):
            var pr = point_distance(cs, i, pose, o + d * t)
            if pr.dist <= _SKIN:
                return Hit(True, i, t, o + d * t, pr.normal, it == 0 and pr.dist < 0)
            t += max(pr.dist * 0.9, _SKIN)
            if t > max_t:
                break
        return Hit.miss()
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


def _ray_from(
    cs: ColliderSet, poses: List[Pose3], cands: List[Int], origin: Vec3, d: Vec3,
    max_t: Real, f: QueryFilter,
) -> Hit:
    var best = Hit.miss()
    best.t = max_t
    for c in range(len(cands)):
        var i = cands[c]
        var h = _ray_one(cs, i, poses[i], origin, d, best.t, f.backfaces)
        if h.hit and h.t <= best.t:
            best = h
    return best if best.hit else Hit.miss()


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
    return _ray_from(cs, poses, _candidates(cs, poses, _box_around(origin, origin + d * max_t, 0), f), origin, d, max_t, f)


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


# ------------------------------------------------------------ multi-hit rays (17.53)


def _hit_before(a: Hit, b: Hit) -> Bool:
    """Total order for multi-hit results: t, then body, then triangle."""
    if a.t != b.t:
        return a.t < b.t
    if a.body != b.body:
        return a.body < b.body
    return a.feat < b.feat


def ray_cast_all(
    cs: ColliderSet,
    poses: List[Pose3],
    origin: Vec3,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
    max_hits: Int = 64,
) -> List[Hit]:
    """Every surface the ray enters within `max_t`, nearest first (one entry
    per convex collider, one per triangle for meshes), at most `max_hits`
    (the nearest ones). Ordered by (t, body, triangle), so the list is the
    same whichever order candidates are visited in."""
    var d = _unit_or_up(dir)
    var all = List[Hit]()
    for i in _candidates(cs, poses, _box_around(origin, origin + d * max_t, 0), f):
        var k = cs.shape[i]
        if k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD:
            _ = _ray_mesh(cs, i, origin, d, max_t, f.backfaces, all, True)
        else:
            var h = _ray_one(cs, i, poses[i], origin, d, max_t, f.backfaces)
            if h.hit:
                all.append(h)
    # insertion sort: hit lists are short
    for a in range(1, len(all)):
        var x = all[a]
        var b = a - 1
        while b >= 0 and _hit_before(x, all[b]):
            all[b + 1] = all[b]
            b -= 1
        all[b + 1] = x
    var out = List[Hit](capacity=min(len(all), max_hits))
    for a in range(min(len(all), max_hits)):
        out.append(all[a])
    return out^


def ray_cast_any(
    cs: ColliderSet,
    poses: List[Pose3],
    origin: Vec3,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
) -> Bool:
    """Is anything hit within `max_t`? Returns at the first hit found
    (line-of-sight checks need no nearest answer)."""
    var d = _unit_or_up(dir)
    for i in _candidates(cs, poses, _box_around(origin, origin + d * max_t, 0), f):
        if _ray_one(cs, i, poses[i], origin, d, max_t, f.backfaces).hit:
            return True
    return False


# ------------------------------------------------------------ convex shapes (17.53)


def pose3_of(position: Vec3, q: Quat) -> Pose3:
    """A `Pose3` from a position and a rotation (for query shapes)."""
    var ax = Axes3(fill=Vec3(0, 0, 0, 0))
    ax[0] = q.rotate(Vec3(1, 0, 0, 0))
    ax[1] = q.rotate(Vec3(0, 1, 0, 0))
    ax[2] = q.rotate(Vec3(0, 0, 1, 0))
    return Pose3(position, ax^)


struct QueryShape(Copyable, Movable):
    """A convex query shape in its own frame: a box (half extents), sphere,
    capsule (local-y axis) or hull (vertices). Same conventions as the
    collider kinds."""

    var kind: Int
    var half: Vec3  # box half extents; sphere / capsule: (r, half length, r)
    var verts: List[Vec3]  # hull vertices (local)

    def __init__(out self, kind: Int, half: Vec3, var verts: List[Vec3]):
        self.kind = kind
        self.half = half
        self.verts = verts^

    @staticmethod
    def box(half: Vec3) -> Self:
        return Self(SHAPE_BOX, half, List[Vec3]())

    @staticmethod
    def sphere(r: Real) -> Self:
        return Self(SHAPE_SPHERE, Vec3(r, 0, r, 0), List[Vec3]())

    @staticmethod
    def capsule(r: Real, half_len: Real) -> Self:
        return Self(SHAPE_CAPSULE, Vec3(r, half_len, r, 0), List[Vec3]())

    @staticmethod
    def hull(var verts: List[Vec3]) -> Self:
        return Self(SHAPE_HULL, Vec3(0, 0, 0, 0), verts^)

    def core(self, pose: Pose3) -> Tuple[List[Vec3], Real]:
        """World core points and radius (see `geometry.gjk_distance`)."""
        var pts = List[Vec3]()
        if self.kind == SHAPE_SPHERE:
            pts.append(pose.position)
            return (pts^, self.half[0])
        if self.kind == SHAPE_CAPSULE:
            pts.append(pose.position - pose.axes[1] * self.half[1])
            pts.append(pose.position + pose.axes[1] * self.half[1])
            return (pts^, self.half[0])
        if self.kind == SHAPE_BOX:
            for c in range(8):
                var lx = self.half[0] if (c & 1) else -self.half[0]
                var ly = self.half[1] if (c & 2) else -self.half[1]
                var lz = self.half[2] if (c & 4) else -self.half[2]
                pts.append(_world(pose, Vec3(lx, ly, lz, 0)))
            return (pts^, Real(0))
        for v in range(len(self.verts)):
            pts.append(_world(pose, self.verts[v]))
        return (pts^, Real(0))


def _collider_core(cs: ColliderSet, i: Int, pose: Pose3) -> Tuple[List[Vec3], Real]:
    """Core points + radius of a CONVEX collider (box, sphere, capsule, hull)."""
    var k = cs.shape[i]
    if k == SHAPE_HULL:
        ref hs = cs.hulls[cs.hull_id[i]]
        var pts = List[Vec3](capacity=hs.nv())
        for v in range(hs.nv()):
            pts.append(_world(pose, hs.vert(v)))
        return (pts^, Real(0))
    var q = QueryShape(k, cs.half[i], List[Vec3]())
    return q.core(pose)


def _cloud_box(pts: List[Vec3], r: Real) -> AABB[3]:
    var lo = pts[0]
    var hi = pts[0]
    for i in range(1, len(pts)):
        for k in range(3):
            lo[k] = min(lo[k], pts[i][k])
            hi[k] = max(hi[k], pts[i][k])
    var w = Vec3(r, r, r, 0)
    return AABB[3](lo - w, hi + w)


def _tri_core(cs: ColliderSet, i: Int, t: Int) -> List[Vec3]:
    var tri = cs.mesh_tri(i, t)
    var out = List[Vec3](capacity=3)
    out.append(tri.points[0])
    out.append(tri.points[1])
    out.append(tri.points[2])
    return out^


def _tri_ok(cs: ColliderSet, i: Int, t: Int) -> Bool:
    var tri = cs.mesh_tri(i, t)
    var n = cross(tri.points[1] - tri.points[0], tri.points[2] - tri.points[0])
    return dot(n, n) >= _EPS * _EPS


def shape_distance(
    cs: ColliderSet, i: Int, pose: Pose3, pts: List[Vec3], r: Real, search: Real = 1e30
) -> Tuple[ConvexDistance, Int]:
    """Distance from a convex core cloud `pts` (+ radius r) to collider `i`
    (A = the query, B = the collider): exact for convex colliders, the
    nearest candidate triangle within `search` for meshes (then also the
    triangle index; -1 otherwise)."""
    var k = cs.shape[i]
    if k == SHAPE_SDF:
        # the query's core points against the grid: a lower bound for a
        # sphere / capsule core, the vertex distance for a box or hull
        var best = ConvexDistance(Real(1e30), pts[0], pts[0], Vec3(0, 1, 0, 0), False)
        for q in range(len(pts)):
            var pr = point_distance(cs, i, pose, pts[q])
            var dd = pr.dist - r
            if dd < best.dist:
                best = ConvexDistance(dd, pts[q] - pr.normal * r, pr.point, -pr.normal, dd <= 0)
        return (best, -1)
    if k != SHAPE_TRIMESH and k != SHAPE_HEIGHTFIELD:
        var c = _collider_core(cs, i, pose)
        return (convex_distance(pts, r, c[0], c[1]), -1)
    var rr = min(search, Real(1e6))
    var box = _cloud_box(pts, r + rr)
    var tris = List[Int]()
    cs.mesh_candidates(i, box, tris)
    var best = ConvexDistance(Real(1e30), pts[0], pts[0], Vec3(0, 1, 0, 0), False)
    var bt = -1
    for c in range(len(tris)):
        if not _tri_ok(cs, i, tris[c]):
            continue
        var dd = convex_distance(pts, r, _tri_core(cs, i, tris[c]), 0)
        if dd.dist < best.dist or (dd.dist == best.dist and tris[c] < bt):
            best = dd
            bt = tris[c]
    return (best, bt)


def closest_points(
    cs: ColliderSet, poses: List[Pose3], i: Int, j: Int, search: Real = 1e30
) -> ConvexDistance:
    """Separation distance and closest points between colliders `i` and `j`
    (`pa` on i, `pb` on j, `normal` from i toward j). Convex-convex is exact
    (GJK); one side a mesh uses its nearest candidate triangle within
    `search`. Two meshes are not supported: distance 1e30."""
    var ki = cs.shape[i]
    if ki == SHAPE_TRIMESH or ki == SHAPE_HEIGHTFIELD or ki == SHAPE_SDF:
        var kj = cs.shape[j]
        if kj == SHAPE_TRIMESH or kj == SHAPE_HEIGHTFIELD or kj == SHAPE_SDF:
            return ConvexDistance(Real(1e30), poses[i].position, poses[j].position, Vec3(0, 1, 0, 0), False)
        var rev = closest_points(cs, poses, j, i, search)
        return ConvexDistance(rev.dist, rev.pb, rev.pa, -rev.normal, rev.overlap)
    var c = _collider_core(cs, i, poses[i])
    return shape_distance(cs, j, poses[j], c[0], c[1], search)[0]


def overlap_shape(
    cs: ColliderSet, poses: List[Pose3], shape: QueryShape, pose: Pose3, f: QueryFilter
) -> List[Int]:
    """Colliders the convex `shape` at `pose` touches or overlaps."""
    var core = shape.core(pose)
    var out = List[Int]()
    for i in _candidates(cs, poses, _cloud_box(core[0], core[1] + _SKIN), f):
        if shape_distance(cs, i, poses[i], core[0], core[1], core[1] + _SKIN)[0].dist <= 0:
            out.append(i)
    return out^


def _cast_convex(
    a_pts: List[Vec3], ra: Real, b_pts: List[Vec3], rb: Real, u: Vec3, max_t: Real
) -> Tuple[Real, ConvexDistance]:
    """Time of first contact of cloud a moving along unit `u` against b, by
    Newton steps on the distance d(t): for convex sets in translation d is
    convex in t, so d(t) + d'(t) dt never overshoots the root (d' = -u.n).
    Returns t = -1 for no contact within `max_t`."""
    var t = Real(0)
    var moved = a_pts.copy()
    for _ in range(_MAX_ITERS):
        for k in range(len(moved)):
            moved[k] = a_pts[k] + u * t
        var dd = convex_distance(moved, ra, b_pts, rb)
        if dd.dist <= _SKIN:
            return (t, dd)
        var rate = dot(u, dd.normal)
        if rate <= 1e-9:
            return (Real(-1), dd)
        # aim half a skin short of the root: the stop is then just outside,
        # where the separating normal is defined (at exact touch it is not)
        t += (dd.dist - _SKIN * 0.5) / rate
        if t > max_t:
            return (Real(-1), dd)
    return (Real(-1), ConvexDistance(Real(1e30), a_pts[0], a_pts[0], Vec3(0, 1, 0, 0), False))


def shape_cast(
    cs: ColliderSet,
    poses: List[Pose3],
    shape: QueryShape,
    pose: Pose3,
    dir: Vec3,
    max_t: Real,
    f: QueryFilter,
) -> Hit:
    """First contact of the convex `shape` (box, sphere, capsule, hull) moved
    from `pose` along unit `dir` for up to `max_t`. Per candidate collider
    (per candidate triangle on meshes) a Newton time-of-impact
    (`_cast_convex`), then the earliest; `normal` points out of the hit
    surface, `point` is on it, `start_solid` when touching at t = 0."""
    var u = _unit_or_up(dir)
    var core = shape.core(pose)
    var moved = List[Vec3](capacity=len(core[0]))
    for k in range(len(core[0])):
        moved.append(core[0][k] + u * max_t)
    var sweep = _cloud_box(core[0], core[1] + _SKIN).merge(_cloud_box(moved, core[1] + _SKIN))
    var best = Hit.miss()
    best.t = max_t
    for i in _candidates(cs, poses, sweep, f):
        var k = cs.shape[i]
        if k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD:
            var tris = List[Int]()
            cs.mesh_candidates(i, sweep, tris)
            for c in range(len(tris)):
                if not _tri_ok(cs, i, tris[c]):
                    continue
                var r = _cast_convex(core[0], core[1], _tri_core(cs, i, tris[c]), 0, u, best.t)
                if r[0] >= 0 and (r[0] < best.t or not best.hit):
                    best = Hit(True, i, r[0], r[1].pb, -r[1].normal, r[0] == 0, tris[c])
        elif k == SHAPE_SDF:
            # not convex: conservative advancement by the sampled distance
            var t = Real(0)
            for it in range(_MAX_ITERS):
                var mv = core[0].copy()
                for q in range(len(mv)):
                    mv[q] = core[0][q] + u * t
                var dd = shape_distance(cs, i, poses[i], mv, core[1])[0]
                if dd.dist <= _SKIN:
                    if t < best.t or not best.hit:
                        best = Hit(True, i, t, dd.pb, -dd.normal, it == 0)
                    break
                t += dd.dist
                if t > best.t:
                    break
        else:
            var cc = _collider_core(cs, i, poses[i])
            var r = _cast_convex(core[0], core[1], cc[0], cc[1], u, best.t)
            if r[0] >= 0 and (r[0] < best.t or not best.hit):
                best = Hit(True, i, r[0], r[1].pb, -r[1].normal, r[0] == 0)
    return best if best.hit else Hit.miss()


# ------------------------------------------------------------ persistent prefilter (17.53)


struct QueryIndex(Movable):
    """The poses of one frame plus a BVH over every collider's world box:
    built once, then many queries take their candidates from a tree descent
    instead of the linear scan (`_candidates`). Candidate lists come back
    sorted by collider index -- the order the linear scan visits -- so an
    indexed query returns exactly what the linear one does."""

    var poses: List[Pose3]
    var bvh: BVH[3]

    def __init__(out self, cs: ColliderSet, var poses: List[Pose3]):
        self.poses = poses^
        self.bvh = BVH[3]()
        var boxes = List[AABB[3]](capacity=len(cs.shape))
        var ids = List[Int](capacity=len(cs.shape))
        for i in range(len(cs.shape)):
            boxes.append(_world_box(cs, i, self.poses[i]))
            ids.append(i)
        if len(boxes) > 0:
            self.bvh.build_boxes(boxes, ids, sah=True)

    def _finish(self, cs: ColliderSet, mut raw: List[Int], f: QueryFilter) -> List[Int]:
        sort(raw)
        var out = List[Int](capacity=len(raw))
        for k in range(len(raw)):
            if _passes(cs, raw[k], f):
                out.append(raw[k])
        return out^

    def candidates(self, cs: ColliderSet, box: AABB[3], f: QueryFilter) -> List[Int]:
        var raw = List[Int]()
        self.bvh.query_region(box, raw)
        return self._finish(cs, raw, f)

    def ray_candidates(self, cs: ColliderSet, o: Vec3, d: Vec3, max_t: Real, f: QueryFilter) -> List[Int]:
        var raw = List[Int]()
        self.bvh.ray_leaves(Ray[3](o, d, max_t), raw)
        return self._finish(cs, raw, f)


def ray_cast_indexed(
    cs: ColliderSet, idx: QueryIndex, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter
) -> Hit:
    """`ray_cast` with candidates from the index's BVH (same answer)."""
    var d = _unit_or_up(dir)
    return _ray_from(cs, idx.poses, idx.ray_candidates(cs, origin, d, max_t, f), origin, d, max_t, f)
