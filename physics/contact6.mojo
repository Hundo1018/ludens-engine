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
from max.algorithm import parallelize
from geometry.vec import Real, Vec3, dot, tangent_basis
from collision.manifold import ContactManifold
from collision.contact_gen import RawContact
from collision.contact_events import pack_key
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
        self.vn0 = copy.vn0.copy()
        self.racc = copy.racc.copy()
        self.vsurf = copy.vsurf
        self.mu_override = copy.mu_override


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
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
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


def make_contact[B: Body6](
    bset: BodySet[B],
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
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
    )
    for k in range(rc.m.count):
        pr.ra[k] = bset.bodies[rc.a].to_local(rc.m.points[k])
        pr.rb[k] = bset.bodies[rc.b].to_local(rc.m.points[k])
        var va0 = Vec3(0, 0, 0, 0)
        var vb0 = Vec3(0, 0, 0, 0)
        if not bset.is_static(rc.a):
            va0 = bset.bodies[rc.a].velocity_at(rc.m.points[k])
        if not bset.is_static(rc.b):
            vb0 = bset.bodies[rc.b].velocity_at(rc.m.points[k])
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
                pr.acc = old.acc.copy()
                pr.acc_t1 = old.acc_t1.copy()
                pr.acc_t2 = old.acc_t2.copy()
                break
    return pr^


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
                    -j, bset.bodies[pr.a].act(pr.ra[k])
                )
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_impulse(
                    j, bset.bodies[pr.b].act(pr.rb[k])
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
):
    """Gauss-Seidel sweeps with Solver2D soft coefficients. Separation is
    re-derived per point from the CURRENT poses via body-frame anchors, so
    rotation shows up as differential depth (restoring torque)."""
    for _ in range(iters):
        for c in range(lo, hi):
            solve_contact(bset,
                pairs, c, h, bias_rate, mass_scale, impulse_scale,
                use_bias, mu,
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
                    mass_scale, impulse_scale, use_bias, mu, workers,
                )
            else:
                for c in range(clo[col], chi[col]):
                    solve_contact(bset,
                        pairs, c, h, bias_rate, mass_scale,
                        impulse_scale, use_bias, mu,
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
        var pwa = bset.bodies[pr.a].act(pr.ra[k])
        var pwb = bset.bodies[pr.b].act(pr.rb[k])
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
            bias = max(-bias_rate * d, Real(-4))
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
                var pwa = bset.bodies[pr.a].act(pr.ra[k])
                var pwb = bset.bodies[pr.b].act(pr.rb[k])
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
):
    """Solve one color's pairs on worker threads (free function + capture-list
    closure, the scheduler's entity-actor precedent). Same-color pairs share
    no dynamic body, so the writes are disjoint and the result is
    bit-identical to solving the color serially."""

    def pair_work(k: Int) {mut bset, mut pairs2, imm lo, imm h, imm bias_rate, imm mass_scale, imm impulse_scale, imm use_bias, imm mu}:
        solve_contact(
            bset, pairs2, lo + k, h, bias_rate, mass_scale, impulse_scale,
            use_bias, mu,
        )

    if workers > 0:
        parallelize(pair_work, hi - lo, workers)
    else:
        parallelize(pair_work, hi - lo)


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
