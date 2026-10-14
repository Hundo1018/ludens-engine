"""Link shapes for reduced-coordinate contact (ROADMAP 17.51).

`Chain.resolve_contacts` contacts material POINTS: a foot touches where its
point touches, and the shin between two such points passes through a ledge
it should rest on. Here a link carries a capsule (segment a-b in its frame,
radius r): against the world each capsule's nearest surface point is found
with `collision.world_query.segment_distance`, and between two links that
are not parent and child (self-collision) from the closest points of their
segments. Each touching pair becomes one row through the point Jacobians
(J = J_i - J_j for a self pair), solved like `resolve_contacts`: a velocity
pass with accumulated non-negative impulses, then a pseudo-velocity pass
that moves q out of the penetration and is discarded.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, length
from collision.collider_set import ColliderSet, Pose3
from collision.world_query import segment_distance
from numerics.dense import cholesky, cholesky_solve, solve_dense
from .chain import Chain


@fieldwise_init
struct LinkCapsule(Copyable, ImplicitlyCopyable, Movable):
    """A capsule on link `link`: segment `a`-`b` in the link frame, radius
    `r`."""

    var link: Int
    var a: Vec3
    var b: Vec3
    var r: Real


@fieldwise_init
struct _Pair(Copyable, ImplicitlyCopyable, Movable):
    var i: Int  # link pushed along +n
    var li: Vec3  # contact point in link i's frame
    var j: Int  # second link (-1 = world)
    var lj: Vec3
    var n: Vec3  # world, from j (or the world) toward i
    var depth: Real


def _to_local(ch: Chain, link: Int, p: Vec3) -> Vec3:
    var qt = ch.fk()[link].to_quat_translation()
    return qt[0].conjugate().rotate(p - qt[1])


def _seg_closest(p1: Vec3, q1: Vec3, p2: Vec3, q2: Vec3) -> Tuple[Vec3, Vec3]:
    """Closest points of segments p1-q1 and p2-q2 (Ericson 5.1.9)."""
    var d1 = q1 - p1
    var d2 = q2 - p2
    var r = p1 - p2
    var a = dot(d1, d1)
    var e = dot(d2, d2)
    var f = dot(d2, r)
    var s = Real(0)
    var t = Real(0)
    if a <= 1e-12 and e <= 1e-12:
        return (p1, p2)
    if a <= 1e-12:
        t = min(max(f / e, Real(0)), Real(1))
    else:
        var c = dot(d1, r)
        if e <= 1e-12:
            s = min(max(-c / a, Real(0)), Real(1))
        else:
            var b = dot(d1, d2)
            var den = a * e - b * b
            if den > 1e-12:
                s = min(max((b * f - c * e) / den, Real(0)), Real(1))
            t = (b * s + f) / e
            if t < 0:
                t = 0
                s = min(max(-c / a, Real(0)), Real(1))
            elif t > 1:
                t = 1
                s = min(max((b - c) / a, Real(0)), Real(1))
    return (p1 + d1 * s, p2 + d2 * t)


def _pairs(ch: Chain, world: ColliderSet, poses: List[Pose3], shapes: List[LinkCapsule], self_collide: Bool) -> List[_Pair]:
    var out = List[_Pair]()
    var ends = List[Vec3]()
    for c in shapes:
        ends.append(ch.point_world(c.link, c.a))
        ends.append(ch.point_world(c.link, c.b))
    for s in range(len(shapes)):
        var cs = shapes[s]
        var pa = ends[2 * s]
        var pb = ends[2 * s + 1]
        for k in range(len(world.shape)):
            var res = segment_distance(world, k, poses[k], pa, pb, cs.r + 0.05)
            var pr = res[0]
            var d = pr.dist - cs.r
            if d <= 0:
                var p = res[1] - pr.normal * cs.r
                out.append(_Pair(cs.link, _to_local(ch, cs.link, p), -1, Vec3(0, 0, 0, 0), pr.normal, -d))
    if self_collide:
        for s in range(len(shapes)):
            for t in range(s + 1, len(shapes)):
                var i = shapes[s].link
                var j = shapes[t].link
                if i == j or ch.parent[i] == j or ch.parent[j] == i:
                    continue  # the same link, or joined: their joint owns that contact
                var cp = _seg_closest(ends[2 * s], ends[2 * s + 1], ends[2 * t], ends[2 * t + 1])
                var g = cp[0] - cp[1]
                var dist = length(g)
                var rr = shapes[s].r + shapes[t].r
                if dist >= rr or dist < 1e-9:
                    continue
                var n = g / dist
                out.append(_Pair(
                    i, _to_local(ch, i, cp[0] - n * shapes[s].r),
                    j, _to_local(ch, j, cp[1] + n * shapes[t].r), n, rr - dist,
                ))
    return out^


def _row(ch: Chain, p: _Pair) -> List[Real]:
    var j = ch.point_jacobian(p.i, p.li, p.n)
    if p.j >= 0:
        var jj = ch.point_jacobian(p.j, p.lj, p.n)
        for k in range(len(j)):
            j[k] -= jj[k]
    return j^


def _apply(mut ch: Chain, l: List[Real], ok: Bool, h: List[Real], j: List[Real], target: Real, mut acc: Real, clamp: Bool):
    var n = len(ch.links)
    var hinv = cholesky_solve(l, j, n) if ok else solve_dense(h.copy(), j.copy(), n)
    var w = Real(0)
    var v = Real(0)
    for k in range(n):
        w += j[k] * hinv[k]
        v += j[k] * ch.qd[k]
    if w < 1e-12:
        return
    var na = acc + (target - v) / w
    if clamp and na < 0:
        na = 0
    var dl = na - acc
    acc = na
    for k in range(n):
        ch.qd[k] += hinv[k] * dl


def resolve_shape_contacts(
    mut ch: Chain,
    world: ColliderSet,
    poses: List[Pose3],
    shapes: List[LinkCapsule],
    dt: Real,
    self_collide: Bool = True,
    iters: Int = 8,
) raises -> Int:
    """Capsule contacts of a chain's links with the world and (when
    `self_collide`) between links that are not parent and child. Call after
    `Chain.step`. Returns the touching pairs found."""
    var n = len(ch.links)
    var pairs = _pairs(ch, world, poses, shapes, self_collide)
    if len(pairs) == 0:
        return 0
    var rows = List[List[Real]]()
    for p in pairs:
        rows.append(_row(ch, p))
    var h1 = ch.mass_matrix()
    var f1 = cholesky(h1, n)
    var acc = List[Real](length=len(pairs), fill=0)
    for _ in range(iters):
        for c in range(len(pairs)):
            _apply(ch, f1[0], f1[1], h1, rows[c], 0, acc[c], True)
    # position: pseudo-velocity toward depth / dt, then discarded
    var saved = ch.qd.copy()
    for k in range(n):
        ch.qd[k] = 0
    var accp = List[Real](length=len(pairs), fill=0)
    for _ in range(iters):
        for c in range(len(pairs)):
            _apply(ch, f1[0], f1[1], h1, rows[c], pairs[c].depth / dt, accp[c], True)
    for k in range(n):
        ch.q[k] += ch.qd[k] * dt
        ch.qd[k] = saved[k]
    if len(ch.balls) > 0:
        ch.fold_balls()
    return len(pairs)
