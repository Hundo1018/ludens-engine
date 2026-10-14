"""Two-way contact between a reduced-coordinate `Chain` and the bodies of a
`ContactScene6` (ROADMAP 17.51).

`Chain.resolve_contacts` treats the world as static: a foot pushes on a
`ColliderSet` and nothing pushes back. Here a chain contact point that
touches a DYNAMIC body of the scene exchanges an impulse with it: the
effective mass of the pair is the chain's J H^-1 J^T plus the body's
1/m + (r x n) . I^-1 (r x n), the chain gets +n lambda through H^-1 J^T and
the body -n lambda at the contact point -- equal and opposite, so the pair's
momentum along n is conserved. Static and kinematic scene bodies act as the
static world did. Friction (mu > 0) adds two tangent rows per contact,
capped by mu times the accumulated normal impulse.

The position repair (penetration) moves only the chain, on a pseudo-velocity
as in `resolve_contacts`; the scene's bodies are moved by its own solver.
Call order per frame: `Chain.step`, `couple_contacts`, `ContactScene6.step`.
"""

from geometry.vec import Real, Vec3, dot, tangent_basis
from collision.world_query import nearest_surface, QueryFilter
from collision.collider_set import Pose3
from numerics.dense import cholesky, cholesky_solve, solve_dense
from .chain import Chain
from .rigid6 import Body6
from .solver6 import ContactScene6


def _pair_row[B: Body6](
    mut ch: Chain, mut sc: ContactScene6[B], l: List[Real], chol: Bool, h: List[Real],
    i: Int, local: Vec3, pw: Vec3, body: Int, dyn: Bool, dir: Vec3,
    target: Real, lo: Real, hi: Real, mut acc: Real,
) raises -> Real:
    """One row along `dir` between chain point (i, local) and scene body
    `body`: the impulse that brings their relative velocity along `dir` to
    `target`, with the accumulated total kept in [lo, hi]. Returns the
    impulse applied this call (chain side +dir, body side -dir)."""
    var n = len(ch.links)
    var j = ch.point_jacobian(i, local, dir)
    var hinv = cholesky_solve(l, j, n) if chol else solve_dense(h.copy(), j.copy(), n)
    var w = Real(0)
    var vc = Real(0)
    for k in range(n):
        w += j[k] * hinv[k]
        vc += j[k] * ch.qd[k]
    var vb = Real(0)
    if dyn:
        ref bd = sc.bset.bodies[body]
        w += bd.inv_mass() + bd.angular_factor(pw - bd.position(), dir)
        vb = dot(bd.velocity_at(pw), dir)
    elif sc.bset.moves(body):
        vb = dot(sc.bset.bodies[body].velocity_at(pw), dir)
    if w < 1e-12:
        return 0
    var na = min(max(acc + (target - (vc - vb)) / w, lo), hi)
    var dl = na - acc
    acc = na
    if dl == 0:
        return 0
    for k in range(n):
        ch.qd[k] += hinv[k] * dl
    if dyn:
        sc.bset.bodies[body].apply_impulse(dir * (-dl), pw)
        sc.bset.sleeping[body] = False
        sc.bset.sleep_timer[body] = 0
    return dl


def couple_contacts[B: Body6](
    mut ch: Chain,
    mut sc: ContactScene6[B],
    contacts: List[Int],
    locals: List[Vec3],
    dt: Real,
    mu: Real = 0,
    iters: Int = 8,
) raises -> Tuple[Int, Vec3]:
    """Contact between chain points (link `contacts[c]`, offset `locals[c]`)
    and the scene's colliders. Returns (contacts active on entry, total
    linear impulse given to the scene's dynamic bodies this call)."""
    var n = len(ch.links)
    var poses = sc.query_poses()
    var filt = QueryFilter.all()
    var nc = len(contacts)
    var hit_body = List[Int](length=nc, fill=-1)
    var normal = List[Vec3](length=nc, fill=Vec3(0, 1, 0, 0))
    var depth = List[Real](length=nc, fill=0)
    var active = 0
    for c in range(nc):
        var pw = ch.point_world(contacts[c], locals[c])
        var hit = nearest_surface(sc.colliders, poses, pw, filt)
        if hit[0] >= 0 and hit[1].dist <= 0 and not sc.bset.is_removed(hit[0]):
            hit_body[c] = hit[0]
            normal[c] = hit[1].normal
            depth[c] = -hit[1].dist
            active += 1
    var given = Vec3(0, 0, 0, 0)
    if active == 0:
        return (0, given)
    var h1 = ch.mass_matrix()
    var f1 = cholesky(h1, n)
    var acc_n = List[Real](length=nc, fill=0)
    var acc_t1 = List[Real](length=nc, fill=0)
    var acc_t2 = List[Real](length=nc, fill=0)
    for _ in range(iters):
        for c in range(nc):
            var b = hit_body[c]
            if b < 0:
                continue
            var i = contacts[c]
            var pw = ch.point_world(i, locals[c])
            var nrm = normal[c]
            var dyn = sc.bset.is_dynamic(b)
            # normal: stop the approach (no restitution)
            var dl = _pair_row(ch, sc, f1[0], f1[1], h1, i, locals[c], pw, b, dyn, nrm, 0, 0, Real(1e30), acc_n[c])
            if dyn:
                given = given - nrm * dl
            if mu > 0 and acc_n[c] > 0:
                var tb = tangent_basis(nrm)
                var cap = mu * acc_n[c]
                var d1 = _pair_row(ch, sc, f1[0], f1[1], h1, i, locals[c], pw, b, dyn, tb[0], 0, -cap, cap, acc_t1[c])
                var d2 = _pair_row(ch, sc, f1[0], f1[1], h1, i, locals[c], pw, b, dyn, tb[1], 0, -cap, cap, acc_t2[c])
                if dyn:
                    given = given - tb[0] * d1 - tb[1] * d2
    # position: the chain alone, on a pseudo-velocity
    var saved = ch.qd.copy()
    var h2 = ch.mass_matrix()
    var f2 = cholesky(h2, n)
    for k in range(n):
        ch.qd[k] = 0
    for _ in range(iters):
        for c in range(nc):
            if hit_body[c] < 0:
                continue
            var i = contacts[c]
            var pw = ch.point_world(i, locals[c])
            var hit = nearest_surface(sc.colliders, poses, pw, filt)
            if hit[0] < 0:
                continue
            var pen = -hit[1].dist
            if pen <= 0:
                continue
            var vn = ch.point_velocity(i, locals[c], hit[1].normal)
            var want = pen / dt - vn
            if want <= 0:
                continue
            _ = ch.apply_impulse_chol(f2[0], i, locals[c], hit[1].normal, want) if f2[1] else ch.apply_impulse_with(h2, i, locals[c], hit[1].normal, want)
    for k in range(n):
        ch.q[k] += ch.qd[k] * dt
        ch.qd[k] = saved[k]
    if len(ch.balls) > 0:
        ch.fold_balls()
    return (active, given)
