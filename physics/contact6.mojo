"""Contact constraints and their sequential-impulse solve (audit F11, cluster
1 + 8): the constraint record, its prep from raw collision geometry, warm
starting, the soft (Box2D v3 / Solver2D) normal + Coulomb friction solve, the
graph-coloured and colour-parallel sweeps, and the restitution pass.

Every function here is a free function over a `BodySet` view plus a slice of
`ContactConstraint`s -- nothing reads a `ContactScene6`. That is the shape the
Wave B items need: a GPU contact solver (17.17) and a batched world layout
(17.18) swap the body storage, and a differentiable solve (17.20) swaps the
scalar ring, without rewriting a 2 800-line scene. `ContactScene6` in
`physics/solver6.mojo` now only composes these calls; the arithmetic, and
therefore every result, is unchanged (the golden test output is the identity
gate for the move).
"""

from std.math import sqrt
from scheduler.dispatch import Dispatch, Task, dispatch_for
from geometry.vec import Real, Vec3, dot, tangent_basis
from collision.manifold import ContactManifold
from collision.contact_gen import RawContact
from collision.contact_events import pack_key
from collision.collider_set import ColliderSet, SHAPE_SPHERE, SHAPE_CAPSULE
from .rigid6 import Body6
from .body_set import BodySet
from .material import combine

comptime _BETA: Real = 0.2  # Baumgarte position-correction gain
comptime _SLOP: Real = 0.005  # allowed penetration


@fieldwise_init
struct ContactConstraint(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    # Sub-key within the pair. Zero for shape-vs-shape, which produces one
    # manifold; for static mesh contact it is the triangle index, because one
    # crate resting on a level touches several triangles at once and each is a
    # separate manifold. Without it every one of them would inherit the first
    # cached entry's impulses and warm-starting would fight itself.
    var feat: Int
    var m: ContactManifold[3]
    var acc: Array[Real, 4]  # per-point accumulated normal impulse
    var acc_t1: Array[Real, 4]  # accumulated friction impulses
    var acc_t2: Array[Real, 4]
    # Body-frame contact anchors (Box2D scheme): both coincide with the
    # manifold point at prep; per-substep world separation is re-derived from
    # the CURRENT poses, so tilting a body deepens its near edge and the bias
    # produces a restoring torque (frozen depths cannot — towers slowly tip).
    var ra: Array[Vec3, 4]
    var rb: Array[Vec3, 4]
    # ROADMAP 17.19: round shapes (sphere, capsule). For them `ra` / `rb` is
    # the closest point on the shape's CORE (sphere centre, capsule segment)
    # in the body frame, and `oa` / `ob` the world-frame offset from that core
    # point to the contact point, which does NOT turn with the body. A rolling
    # ball's contact stays under its centre; with a body-frame anchor the
    # point rotated forward each substep, friction acted ahead of the true
    # contact and braked the roll, and the anchor's lift sank the ball. Zero
    # for every other shape, where the anchor is the body-frame point as before.
    var oa: Array[Vec3, 4]
    var ob: Array[Vec3, 4]
    # Restitution (Box2D v3 scheme): the approach speed captured at prep time
    # drives a dedicated post-substep pass toward v_target = -e·vn0. Neither
    # field is warm-start-inherited — both are per-frame.
    var vn0: Array[Real, 4]
    var racc: Array[Real, 4]
    # Contact modification (ROADMAP 17.26), set per frame by a
    # `ContactRule` and never inherited from the cache: the tangential
    # velocity of b's surface relative to a's that friction should match (a
    # conveyor belt), and a friction coefficient replacing the combined one
    # (< 0 = none).
    var vsurf: Vec3
    var mu_override: Real
    # ROADMAP 17.49 report: this step's normal impulse per point (restitution
    # included), the summed friction impulse vector, and the time they cover.
    # Built by `accumulate_step_impulse` / `add_restitution_impulse`, never
    # inherited from the cache.
    var jn: Array[Real, 4]
    var jf: Vec3
    var span: Real

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` is not `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one gets no synthesised copy."""
        self.a = copy.a
        self.b = copy.b
        self.feat = copy.feat
        self.m = copy.m.copy()
        self.acc = copy.acc.copy()
        self.acc_t1 = copy.acc_t1.copy()
        self.acc_t2 = copy.acc_t2.copy()
        self.ra = copy.ra.copy()
        self.rb = copy.rb.copy()
        self.oa = copy.oa.copy()
        self.ob = copy.ob.copy()
        self.vn0 = copy.vn0.copy()
        self.racc = copy.racc.copy()
        self.vsurf = copy.vsurf
        self.mu_override = copy.mu_override
        self.jn = copy.jn.copy()
        self.jf = copy.jf
        self.span = copy.span


def contact_island[B: Body6](bset: BodySet[B], pr: ContactConstraint) -> Int:
    """The island a contact belongs to: its dynamic side's label."""
    return bset.island[pr.a] if bset.is_dynamic(pr.a) else bset.island[pr.b]


def make_sensor_contact(rc: RawContact) -> ContactConstraint:
    """Wrap a sensor overlap: all-zero accumulators/anchors, matching the
    original inline construction exactly -- a sensor never receives an
    impulse, so it never needs an anchor or an approach-speed prep."""
    return ContactConstraint(
        rc.a, rc.b, rc.feat, rc.m,
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
    )


def cache_index(cache: List[ContactConstraint]) -> Dict[Int, Int]:
    """First cache position of each (a, b, feat) key -- built once per frame
    so the warm-start match is a lookup instead of a scan per new contact
    (audit F22: that scan made collection O(pairs x cache))."""
    var idx = Dict[Int, Int]()
    for c in range(len(cache)):
        var k = pack_key(cache[c].a, cache[c].b, cache[c].feat)
        if k not in idx:
            idx[k] = c
    return idx^


def round_core[B: Body6](
    bset: BodySet[B], colliders: ColliderSet, i: Int, p: Vec3, n: Vec3 = Vec3(0, 0, 0, 0)
) -> Optional[Vec3]:
    """Body-frame core point of a round collider nearest to world point
    `p` -- the sphere's centre, or the clamped point on a capsule's local-y
    segment -- or None for any other shape (ROADMAP 17.19). A cylinder
    (17.52) counts as round when the contact normal `n` is across its axis
    (a side contact), not on its flat end caps."""
    var k = colliders.shape[i]
    var rr = colliders.round_radius(i)
    if rr > 0:
        var o = bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var axis = bset.bodies[i].act(Vec3(0, 1, 0, 0)) - o
        if abs(dot(n, axis)) >= 0.5:
            return None
        var hl = colliders.half[i][1]
        var y = bset.bodies[i].to_local(p)[1]
        return Vec3(0, min(max(y, -hl), hl), 0, 0)
    if k == SHAPE_SPHERE:
        return Vec3(0, 0, 0, 0)
    if k == SHAPE_CAPSULE:
        var hl = colliders.half[i][1]
        var y = bset.bodies[i].to_local(p)[1]
        return Vec3(0, min(max(y, -hl), hl), 0, 0)
    return None


def anchor_world[B: Body6](
    bset: BodySet[B], i: Int, r: Vec3, o: Vec3
) -> Vec3:
    """World position of a contact anchor: body-frame point `r` under the
    current pose, plus the world-frame round-shape offset `o` (zero for
    non-round shapes, so this is `act(r)` exactly)."""
    return bset.bodies[i].act(r) + o


def make_contact[B: Body6](
    bset: BodySet[B],
    colliders: ColliderSet,
    cache: List[ContactConstraint],
    cidx: Dict[Int, Int],
    rc: RawContact,
    warm: Bool,
) -> ContactConstraint:
    """Wrap raw contact geometry (`collision.contact_gen.RawContact`)
    into a solved `ContactConstraint`: body-frame anchors and approach-speed prep
    (need `Body6.to_local`/`velocity_at`), then a warm-start match
    against last frame's cache (need `cache`) -- the two things
    `contact_gen` cannot do without seeing physics.

    For a mesh contact `rc.b` is always static, so `vb0` below is always
    the zero it starts as -- the same value the old mesh-specific path
    got from `dot(-va0, normal)`, just via the shared formula."""
    var pr = ContactConstraint(
        rc.a, rc.b, rc.feat, rc.m,
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
    )
    for k in range(rc.m.count):
        var p = rc.m.points[k]
        var ca = round_core(bset, colliders, rc.a, p, rc.m.normal)
        var cb = round_core(bset, colliders, rc.b, p, rc.m.normal)
        # A round side's lever arm must reach its real surface: the
        # narrowphase puts e.g. a sphere-on-box point on the margin-inflated
        # face, half a speculative margin inside the ball, and friction
        # there makes a ball roll at omega * (r - margin/2) == v. Slide the
        # point along the normal (both anchors together, so separation is
        # unchanged) to the round surface, or midway between two of them.
        if ca or cb:
            var n = rc.m.normal
            var target = Real(0)
            if ca:
                target = dot(bset.bodies[rc.a].act(ca.value()), n) + colliders.half[rc.a][0]
            if cb:
                var sb = dot(bset.bodies[rc.b].act(cb.value()), n) - colliders.half[rc.b][0]
                target = (target + sb) * 0.5 if ca else sb
            p = p + n * (target - dot(p, n))
        if ca:
            pr.ra[k] = ca.value()
            pr.oa[k] = p - bset.bodies[rc.a].act(ca.value())
        else:
            pr.ra[k] = bset.bodies[rc.a].to_local(p)
        if cb:
            pr.rb[k] = cb.value()
            pr.ob[k] = p - bset.bodies[rc.b].act(cb.value())
        else:
            pr.rb[k] = bset.bodies[rc.b].to_local(p)
        var va0 = Vec3(0, 0, 0, 0)
        var vb0 = Vec3(0, 0, 0, 0)
        if not bset.is_static(rc.a):
            va0 = bset.bodies[rc.a].velocity_at(p)
        if not bset.is_static(rc.b):
            vb0 = bset.bodies[rc.b].velocity_at(p)
        pr.vn0[k] = dot(vb0 - va0, rc.m.normal)
    if warm:
        # Start at the first entry with this key (`cache_index`); the scan
        # from there keeps the old first-match rule exactly, count included.
        var start = cidx.get(pack_key(rc.a, rc.b, rc.feat), len(cache))
        for c in range(start, len(cache)):
            var old = cache[c]
            if (
                old.a == rc.a
                and old.b == rc.b
                and old.feat == rc.feat
                and old.m.count == rc.m.count
            ):
                # Match each point to the nearest unused cached point, not
                # by index: `box_box_manifold` returns the same four corners
                # of a resting box in a different order from step to step,
                # and index matching handed every corner another corner's
                # friction -- a 3-box stack built up that torsion until it
                # kicked (1.24 N sideways on the top box, ARM runner).
                # Distance in body `a`'s frame (a sliding box's corners stay
                # put there), and only within 5 cm. A point with no cached
                # point that close keeps the old rule -- the cached point of
                # the same index, if not taken: points that moved further
                # (a box sliding over small triangles, a bullet in the step
                # after its impact) have no reliable partner either way, and
                # forcing the nearest one kicked the sliding box up at the
                # seams (|vy| 0.023) while starting cold raised the bullet's
                # rebound from 2.4 to 3.5 m/s.
                var used = Array[Bool, 4](fill=False)
                var src = Array[Int, 4](fill=-1)
                for k in range(rc.m.count):
                    var best = -1
                    var bd = Real(2.5e-3)
                    for q in range(old.m.count):
                        if used[q]:
                            continue
                        var dv = old.ra[q] - pr.ra[k]
                        var d2 = dot(dv, dv)
                        if d2 <= bd:
                            bd = d2
                            best = q
                    if best >= 0:
                        used[best] = True
                        src[k] = best
                for k in range(rc.m.count):
                    if src[k] < 0 and not used[k]:
                        used[k] = True
                        src[k] = k
                for k in range(rc.m.count):
                    if src[k] >= 0:
                        pr.acc[k] = old.acc[src[k]]
                        pr.acc_t1[k] = old.acc_t1[src[k]]
                        pr.acc_t2[k] = old.acc_t2[src[k]]
                break
    return pr^


def accumulate_step_impulse[B: Body6](
    bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int, scale: Real, h: Real
):
    """After a substep's relax sweep: each point's `acc` is exactly the
    normal impulse that substep applied (the warm start applied the old
    `acc`, the sweeps applied the increments), likewise `acc_t1 / acc_t2`
    for friction. Add them (times `scale`) to the step totals. A pair the
    solver skipped (both sides impulse-inert: static or asleep) applied
    nothing -- its `acc` is only kept for the next warm start -- so it adds
    nothing."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var tb = tangent_basis(pr.m.normal)
        for k in range(pr.m.count):
            pr.jn[k] += pr.acc[k] * scale
            pr.jf = pr.jf + (tb[0] * pr.acc_t1[k] + tb[1] * pr.acc_t2[k]) * scale
        pr.span += h * scale


def add_restitution_impulse[B: Body6](
    bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int
):
    """Fold the restitution pass's normal impulses into the step totals."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        for k in range(pr.m.count):
            pr.jn[k] += pr.racc[k]


def warm_start_contacts[B: Body6](
    mut bset: BodySet[B], pairs: List[ContactConstraint], lo: Int, hi: Int
):
    """Apply the accumulated impulses at each anchor (Box2D v3 scheme: the
    soft solve's `-impulseScale·acc` term is what balances this out)."""
    for c in range(lo, hi):
        var pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var n = pr.m.normal
        var tb = tangent_basis(n)
        for k in range(pr.m.count):
            var j = (
                n * pr.acc[k]
                + tb[0] * pr.acc_t1[k]
                + tb[1] * pr.acc_t2[k]
            )
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_impulse(
                    -j, anchor_world(bset, pr.a, pr.ra[k], pr.oa[k])
                )
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_impulse(
                    j, anchor_world(bset, pr.b, pr.rb[k], pr.ob[k])
                )


def solve_point[B: Body6](
    mut bset: BodySet[B],
    ia: Int,
    ib: Int,
    n: Vec3,
    p: Vec3,
    depth: Real,
    dt: Real,
    acc: Real,
) -> Real:
    """One accumulated-impulse Gauss-Seidel update; returns the new
    accumulated normal impulse (clamped >= 0, so later sweeps can remove
    an earlier over-push — without this the solve order injects a net
    torque and resting boxes slowly rotate)."""
    # `moves` (velocity read: dynamic OR kinematic) vs `is_dynamic` (mass
    # term + impulse: dynamic only) -- ROADMAP 17.24's whole solver-side
    # split, see `BodySet.moves`'s docstring. A zero-velocity kinematic
    # body takes the exact same `moves=True, is_dynamic=False` branches a
    # static body takes `moves=False`, both landing on `va=0, ka=0` --
    # the bit-identity the KEY PARITY TEST requires.
    var va = Vec3(0, 0, 0, 0)
    var ka = Real(0)
    if bset.moves(ia):
        va = bset.bodies[ia].velocity_at(p)
    if bset.is_dynamic(ia):
        ka = bset.bodies[ia].inv_mass() + bset.bodies[ia].angular_factor(
            p - bset.bodies[ia].position(), n
        )
    var vb = Vec3(0, 0, 0, 0)
    var kb = Real(0)
    if bset.moves(ib):
        vb = bset.bodies[ib].velocity_at(p)
    if bset.is_dynamic(ib):
        kb = bset.bodies[ib].inv_mass() + bset.bodies[ib].angular_factor(
            p - bset.bodies[ib].position(), n
        )
    var denom = ka + kb
    if denom <= 0:
        return acc
    var vn = dot(vb - va, n)  # >0 means separating (n points a -> b)
    var bias = _BETA / dt * max(depth - _SLOP, 0)
    var new_acc = max(acc + (bias - vn) / denom, 0)
    var dl = new_acc - acc
    if dl == 0:
        return acc
    var j = n * dl
    if bset.is_dynamic(ia):
        bset.bodies[ia].apply_impulse(-j, p)
    if bset.is_dynamic(ib):
        bset.bodies[ib].apply_impulse(j, p)
    return new_acc


def soft_sweep[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    iters: Int,
    mu: Real,
    max_push: Real = 4,
):
    """Gauss-Seidel sweeps with Solver2D soft coefficients. `max_push` caps
    the soft push-out speed (m/s, `SolverConfig.max_push_speed`). Separation is
    re-derived per point from the CURRENT poses via body-frame anchors, so
    rotation shows up as differential depth (restoring torque)."""
    for _ in range(iters):
        for c in range(lo, hi):
            solve_contact(bset,
                pairs, c, h, bias_rate, mass_scale, impulse_scale,
                use_bias, mu, max_push,
            )


def sweep_colored[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    clo: List[Int],
    chi: List[Int],
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    iters: Int,
    mu: Real,
    par: Bool,
    workers: Int = 0,
    dispatch: Dispatch = Dispatch.parallel(),
    max_push: Real = 4,
):
    """Graph-colored sweeps: pairs in one color share no DYNAMIC body
    (statics are excluded from adjacency and never written), so a color
    solves in parallel — Jacobi within the color, Gauss-Seidel across
    colors. The schedule is fixed and same-color writes are disjoint, so
    par=True is bit-identical to par=False (and to any `workers` count)."""
    for _ in range(iters):
        for col in range(len(clo)):
            if par and chi[col] - clo[col] >= 8:
                solve_color_parallel(
                    bset, pairs, clo[col], chi[col], h, bias_rate,
                    mass_scale, impulse_scale, use_bias, mu, workers, dispatch, max_push,
                )
            else:
                for c in range(clo[col], chi[col]):
                    solve_contact(bset,
                        pairs, c, h, bias_rate, mass_scale,
                        impulse_scale, use_bias, mu, max_push,
                    )


def solve_contact[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    c: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    mu: Real,
    max_push: Real = 4,
):
    """One pair's normal + friction solve (the body of `_soft_sweep`,
    extracted so the colored sweep can schedule it per pair)."""
    var pr = pairs[c]
    if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
        return
    var n = pr.m.normal
    # ROADMAP 17.23: the pair's combined friction, computed ONCE per pair
    # (not per point/substep) since it depends only on (a, b), not on the
    # contact geometry -- "cheap per contact" per the spec. `mu` here is
    # `cfg.default_friction`, substituted for either body's coefficient
    # when it never called `set_friction` (`eff_friction`'s docstring);
    # with both bodies unset and the default `COMBINE_AVERAGE` mode,
    # `combine(mu, mu, AVERAGE, AVERAGE) == mu` bit-exactly, so an
    # all-default scene is unchanged from before this existed.
    var pair_mu = combine(
        bset.eff_friction(pr.a, mu),
        bset.eff_friction(pr.b, mu),
        bset.friction_combine[pr.a],
        bset.friction_combine[pr.b],
    )
    if pr.mu_override >= 0:
        pair_mu = pr.mu_override
    var conveyor = pr.vsurf[0] != 0 or pr.vsurf[1] != 0 or pr.vsurf[2] != 0
    for k in range(pr.m.count):
        var pwa = anchor_world(bset, pr.a, pr.ra[k], pr.oa[k])
        var pwb = anchor_world(bset, pr.b, pr.rb[k], pr.ob[k])
        # anchors coincided at prep with depth d0; separation since
        # then is the anchor drift along the normal
        var d = pr.m.depths[k] - dot(pwb - pwa, n)
        var va = Vec3(0, 0, 0, 0)
        var ka = Real(0)
        if bset.moves(pr.a):
            va = bset.bodies[pr.a].velocity_at(pwa)
        if bset.is_dynamic(pr.a):
            ka = bset.bodies[pr.a].inv_mass() + bset.bodies[
                pr.a
            ].angular_factor(pwa - bset.bodies[pr.a].position(), n)
        var vb = Vec3(0, 0, 0, 0)
        var kb = Real(0)
        if bset.moves(pr.b):
            vb = bset.bodies[pr.b].velocity_at(pwb)
        if bset.is_dynamic(pr.b):
            kb = bset.bodies[pr.b].inv_mass() + bset.bodies[
                pr.b
            ].angular_factor(pwb - bset.bodies[pr.b].position(), n)
        var denom = ka + kb
        if denom <= 0:
            continue
        var vn = dot(vb - va, n)
        # Box2D sign convention: separation s = -d (negative when
        # penetrating), bias <= 0 pulls vn upward past zero.
        var bias = Real(0)
        var ms = Real(1)
        var isc = Real(0)
        if d < 0:
            bias = -d / h  # speculative: match approach speed
        elif use_bias:
            bias = max(-bias_rate * d, -max_push)
            ms = mass_scale
            isc = impulse_scale
        var raw = -ms * (vn + bias) / denom - isc * pr.acc[k]
        var new_acc = max(pr.acc[k] + raw, 0)
        var dl = new_acc - pr.acc[k]
        pr.acc[k] = new_acc
        if dl != 0:
            var j = n * dl
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_impulse(-j, pwa)
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_impulse(j, pwb)
        # Coulomb friction: tangent impulses clamped to pair_mu * lambda_n.
        var tb = tangent_basis(n)
        var cap = pair_mu * pr.acc[k]
        for ti in range(2):
            var t = tb[0] if ti == 0 else tb[1]
            var vat = Vec3(0, 0, 0, 0)
            var kat = Real(0)
            if bset.moves(pr.a):
                vat = bset.bodies[pr.a].velocity_at(pwa)
            if bset.is_dynamic(pr.a):
                kat = bset.bodies[pr.a].inv_mass() + bset.bodies[
                    pr.a
                ].angular_factor(
                    pwa - bset.bodies[pr.a].position(), t
                )
            var vbt = Vec3(0, 0, 0, 0)
            var kbt = Real(0)
            if bset.moves(pr.b):
                vbt = bset.bodies[pr.b].velocity_at(pwb)
            if bset.is_dynamic(pr.b):
                kbt = bset.bodies[pr.b].inv_mass() + bset.bodies[
                    pr.b
                ].angular_factor(
                    pwb - bset.bodies[pr.b].position(), t
                )
            var dent = kat + kbt
            if dent <= 0:
                continue
            var vt = dot(vbt - vat, t)
            if conveyor:
                vt += dot(pr.vsurf, t)
            var acc_t = pr.acc_t1[k] if ti == 0 else pr.acc_t2[k]
            var new_t = acc_t - vt / dent
            if new_t > cap:
                new_t = cap
            elif new_t < -cap:
                new_t = -cap
            var dtl = new_t - acc_t
            if ti == 0:
                pr.acc_t1[k] = new_t
            else:
                pr.acc_t2[k] = new_t
            if dtl != 0:
                var jt = t * dtl
                if bset.is_dynamic(pr.a):
                    bset.bodies[pr.a].apply_impulse(-jt, pwa)
                if bset.is_dynamic(pr.b):
                    bset.bodies[pr.b].apply_impulse(jt, pwb)
    pairs[c] = pr


def restitution_pass[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    lo: Int,
    hi: Int,
    iters: Int,
    threshold: Real = 1.0,  # m/s approach speed to trigger (SolverConfig
    # .restitution_threshold; default matches the old comptime REST_THRESH)
):
    """Box2D v3 restitution: after the substeps have resolved penetration,
    push each point that arrived faster than the threshold back toward
    `vn = -e·vn0` (its own clamped accumulator, so sweeps can correct)."""
    for _ in range(iters):
        for c in range(lo, hi):
            var pr = pairs[c]
            # ROADMAP 17.23: combined via each body's own
            # `restitution_combine` (default `COMBINE_MAX` for every
            # body -- `combine`'s docstring), so an all-default scene's
            # `max(a, b)` is bit-identical to before this existed.
            var e = combine(
                bset.restitution[pr.a], bset.restitution[pr.b],
                bset.restitution_combine[pr.a],
                bset.restitution_combine[pr.b],
            )
            if e <= 0:
                continue
            var n = pr.m.normal
            for k in range(pr.m.count):
                if pr.vn0[k] >= -threshold:
                    continue
                var pwa = anchor_world(bset, pr.a, pr.ra[k], pr.oa[k])
                var pwb = anchor_world(bset, pr.b, pr.rb[k], pr.ob[k])
                var va = Vec3(0, 0, 0, 0)
                var ka = Real(0)
                if bset.moves(pr.a):
                    va = bset.bodies[pr.a].velocity_at(pwa)
                if bset.is_dynamic(pr.a):
                    ka = bset.bodies[pr.a].inv_mass() + bset.bodies[
                        pr.a
                    ].angular_factor(pwa - bset.bodies[pr.a].position(), n)
                var vb = Vec3(0, 0, 0, 0)
                var kb = Real(0)
                if bset.moves(pr.b):
                    vb = bset.bodies[pr.b].velocity_at(pwb)
                if bset.is_dynamic(pr.b):
                    kb = bset.bodies[pr.b].inv_mass() + bset.bodies[
                        pr.b
                    ].angular_factor(pwb - bset.bodies[pr.b].position(), n)
                var denom = ka + kb
                if denom <= 0:
                    continue
                var vn = dot(vb - va, n)
                var target = -e * pr.vn0[k]
                var new_acc = max(pr.racc[k] + (target - vn) / denom, 0)
                var dl = new_acc - pr.racc[k]
                pr.racc[k] = new_acc
                if dl != 0:
                    var j = n * dl
                    if bset.is_dynamic(pr.a):
                        bset.bodies[pr.a].apply_impulse(-j, pwa)
                    if bset.is_dynamic(pr.b):
                        bset.bodies[pr.b].apply_impulse(j, pwb)
            pairs[c] = pr


struct _ColorTask[B: Body6](Task):
    """One same-colour pair per item: no two share a dynamic body."""

    var bset: Pointer[BodySet[Self.B], MutUntrackedOrigin]
    var pairs2: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var lo: Int
    var h: Real
    var bias_rate: Real
    var mass_scale: Real
    var impulse_scale: Real
    var use_bias: Bool
    var mu: Real
    var max_push: Real

    def __init__(
        out self, mut bset: BodySet[Self.B], mut pairs2: List[ContactConstraint], lo: Int,
        h: Real, bias_rate: Real, mass_scale: Real, impulse_scale: Real, use_bias: Bool, mu: Real,
        max_push: Real,
    ):
        self.bset = Pointer(to=bset).unsafe_origin_cast[MutUntrackedOrigin]()
        self.pairs2 = Pointer(to=pairs2).unsafe_origin_cast[MutUntrackedOrigin]()
        self.lo = lo
        self.h = h
        self.bias_rate = bias_rate
        self.mass_scale = mass_scale
        self.impulse_scale = impulse_scale
        self.use_bias = use_bias
        self.mu = mu
        self.max_push = max_push

    def run(self, k: Int):
        solve_contact(
            self.bset[], self.pairs2[], self.lo + k, self.h, self.bias_rate, self.mass_scale,
            self.impulse_scale, self.use_bias, self.mu, self.max_push,
        )


def solve_color_parallel[B: Body6](
    mut bset: BodySet[B],
    mut pairs2: List[ContactConstraint],
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    mu: Real,
    workers: Int = 0,
    dispatch: Dispatch = Dispatch.parallel(),
    max_push: Real = 4,
):
    """Solve one color's pairs as `_ColorTask` items run by `dispatch`
    (ROADMAP 17.75). Same-color pairs share no dynamic body, so the writes
    are disjoint and the result is bit-identical to solving the color
    serially, whoever runs the items."""
    var task = _ColorTask[B](bset, pairs2, lo, h, bias_rate, mass_scale, impulse_scale, use_bias, mu, max_push)
    dispatch_for(dispatch, task, hi - lo, workers)


# ------------------------------------------------------ contact modification

comptime RULE_ONE_WAY = 0  # body passes through from the far side of `dir`
comptime RULE_CONVEYOR = 1  # body's surface moves at `dir` (m/s)
comptime RULE_FRICTION = 2  # contacts of body use friction `value`


@fieldwise_init
struct ContactRule(Copyable, ImplicitlyCopyable, Movable):
    """A per-contact rule on one body, applied to that frame's contacts
    after collection (ROADMAP 17.26). ONE_WAY: a contact with `body` counts
    only when its normal toward the other body is within 60 degrees of
    `dir`, the other body is not moving along `dir` faster than 0.1 m/s,
    and it has not sunk deeper than `value` into the platform -- so a body
    passes up through it and lands on it from above. CONVEYOR: friction
    drags toward `body`'s surface moving at `dir`. FRICTION: contacts of
    `body` use coefficient `value` instead of the combined one."""

    var kind: Int
    var body: Int
    var dir: Vec3
    var value: Real


def apply_rules[B: Body6](
    bset: BodySet[B], rules: List[ContactRule], mut pairs: List[ContactConstraint]
):
    """Drop or modify this frame's contacts according to `rules`. With no
    rules nothing is touched (the parity with the unmodified solver)."""
    if len(rules) == 0:
        return
    var kept = List[ContactConstraint](capacity=len(pairs))
    for c in range(len(pairs)):
        var pr = pairs[c]
        var keep = True
        for r in range(len(rules)):
            ref ru = rules[r]
            var on_a = pr.a == ru.body
            var on_b = pr.b == ru.body
            if not on_a and not on_b:
                continue
            if ru.kind == RULE_ONE_WAY:
                # normal from the platform toward the other body
                var n = pr.m.normal if on_a else -pr.m.normal
                var other = pr.b if on_a else pr.a
                var up_v = Real(0)
                if bset.moves(other):
                    up_v = dot(bset.bodies[other].linear_velocity(), ru.dir)
                var deepest = Real(0)
                for k in range(pr.m.count):
                    deepest = max(deepest, pr.m.depths[k])
                if dot(n, ru.dir) < 0.5 or up_v > 0.1 or deepest > ru.value:
                    keep = False
            elif ru.kind == RULE_CONVEYOR:
                # relative surface velocity of b w.r.t. a, tangential part
                var u = ru.dir if on_b else -ru.dir
                var nn = pr.m.normal
                pr.vsurf = pr.vsurf + (u - nn * dot(u, nn))
            elif ru.kind == RULE_FRICTION:
                pr.mu_override = ru.value
        if keep:
            kept.append(pr)
    pairs = kept^
