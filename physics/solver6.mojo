"""6-DOF contact solving: `ContactManifold` points -> sequential impulses.

This is the first angular contact response in the engine — the piece
`physics/rigidbody.mojo` explicitly deferred until the narrowphase produced
contact points. `ContactScene6[B]` is generic over the `Body6` representation
(quat+tensor or motor+screw), so the same scene is a parity gate between the
classical and the GA path.

Two step modes share the collision prep:

  * `step` — one-shot: gravity -> manifolds -> Gauss-Seidel accumulated
    normal impulses with a Baumgarte velocity bias -> pose integration.
  * `step_soft` — SUB-STEPPED SOFT-CONSTRAINT solver (Box2D v3 "Soft Step" /
    Small Steps): collide once per frame, then n substeps of {integrate
    velocities -> soft-biased impulse sweeps -> integrate poses -> a bias-free
    RELAX sweep that removes the bias energy}. Contact separation is updated
    across substeps from body translation along the normal (rotation term
    neglected — small per substep). Soft coefficients follow Solver2D:
    ω = 2π·hertz, biasRate = ω/(2ζ + hω), c = hω(2ζ + hω),
    massScale = c/(1+c), impulseScale = 1/(1+c).

`step_soft` also solves Coulomb friction (two tangent impulses per point,
clamped to μ·λₙ) — without it, box spin is undamped and, since the box
narrowphase is axis-aligned, geometrically unconstrained. Restitution is still
deferred (e = 0 scenes).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.aabb import AABB
from collision.manifold import ContactManifold, Axes3, box_box_manifold
from collision.toi import swept_box_toi
from .rigid6 import Body6

comptime _BETA: Real = 0.2  # Baumgarte position-correction gain
comptime _SLOP: Real = 0.005  # allowed penetration


@fieldwise_init
struct _CPair(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    var m: ContactManifold[3]
    var acc: InlineArray[Real, 4]  # per-point accumulated normal impulse
    var acc_t1: InlineArray[Real, 4]  # accumulated friction impulses
    var acc_t2: InlineArray[Real, 4]
    # Body-frame contact anchors (Box2D scheme): both coincide with the
    # manifold point at prep; per-substep world separation is re-derived from
    # the CURRENT poses, so tilting a body deepens its near edge and the bias
    # produces a restoring torque (frozen depths cannot — towers slowly tip).
    var ra: InlineArray[Vec3, 4]
    var rb: InlineArray[Vec3, 4]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _tangent_basis(n: Vec3) -> Tuple[Vec3, Vec3]:
    """Two unit tangents perpendicular to `n` (and each other)."""
    var seed = Vec3(0, 1, 0) if abs(n[0]) > 0.9 else Vec3(1, 0, 0)
    var t1 = _cross(seed, n)
    t1 = t1 / sqrt(max(dot(t1, t1), Real(1e-12)))
    return (t1, _cross(n, t1))


@fieldwise_init
struct _Half(Copyable, ImplicitlyCopyable, Movable):
    """Struct-wrapped Vec3: a bare `List[SIMD[_, 3]]` corrupts on realloc
    (documented nightly hazard, see geometry/gjk.mojo)."""

    var v: Vec3


comptime JOINT_BALL = 0
comptime JOINT_DISTANCE = 1
comptime JOINT_HINGE = 2


@fieldwise_init
struct Joint6(Copyable, ImplicitlyCopyable, Movable):
    """A two-body joint solved in the soft substep loop (equality constraints,
    no cone clamp). `kind`: ball (anchors coincide), distance (anchor gap =
    rest), hinge (ball + the two local axes stay aligned)."""

    var kind: Int
    var a: Int
    var b: Int
    var la: Vec3  # anchor in a's body frame
    var lb: Vec3
    var rest: Real  # distance joint rest length
    var axis_a: Vec3  # hinge axis in each body frame
    var axis_b: Vec3
    var acc: Vec3  # accumulated linear impulse (distance uses acc[0])
    var acc_ang: Vec3  # accumulated angular impulse (hinge tangents)

    @staticmethod
    def ball(a: Int, b: Int, la: Vec3, lb: Vec3) -> Self:
        return Self(
            JOINT_BALL, a, b, la, lb, 0,
            Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0),
        )

    @staticmethod
    def distance(a: Int, b: Int, la: Vec3, lb: Vec3, rest: Real) -> Self:
        return Self(
            JOINT_DISTANCE, a, b, la, lb, rest,
            Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0),
        )

    @staticmethod
    def hinge(a: Int, b: Int, la: Vec3, lb: Vec3, axis: Vec3) -> Self:
        return Self(
            JOINT_HINGE, a, b, la, lb, 0,
            axis, axis, Vec3(0, 0, 0), Vec3(0, 0, 0),
        )


struct ContactScene6[B: Body6](Movable, ImplicitlyDeletable):
    """Boxes (dynamic or static) under gravity with contact impulses."""

    var bodies: List[Self.B]
    var half: List[_Half]  # box half-extents, parallel to `bodies`
    var statics: List[Bool]
    var cache: List[_CPair]  # last frame's pairs (cross-frame warm starting)
    var joints: List[Joint6]
    var sleeping: List[Bool]
    var sleep_timer: List[Real]
    var island: List[Int]  # island label per body (last step; -1 = static)

    def __init__(out self):
        self.bodies = List[Self.B]()
        self.half = List[_Half]()
        self.statics = List[Bool]()
        self.cache = List[_CPair]()
        self.joints = List[Joint6]()
        self.sleeping = List[Bool]()
        self.sleep_timer = List[Real]()
        self.island = List[Int]()

    def add_joint(mut self, j: Joint6) -> Int:
        self.joints.append(j)
        return len(self.joints) - 1

    def island_count(self) -> Int:
        """Number of distinct dynamic islands from the last `step_soft`."""
        var seen = List[Int]()
        for i in range(len(self.island)):
            if self.island[i] < 0:
                continue
            var known = False
            for j in range(len(seen)):
                if seen[j] == self.island[i]:
                    known = True
                    break
            if not known:
                seen.append(self.island[i])
        return len(seen)

    def _find(self, mut parent: List[Int], i: Int) -> Int:
        var r = i
        while parent[r] != r:
            var pr = parent[r]
            var gp = parent[pr]  # path halving
            parent[r] = gp
            r = gp
        return r

    def _refresh_islands(mut self, pairs: List[_CPair]):
        """Union-find over the constraint graph (contacts + joints between
        dynamic bodies; statics do not merge islands), then the wake rule:
        an island with ANY awake member wakes entirely."""
        var n = len(self.bodies)
        var parent = List[Int]()
        for i in range(n):
            parent.append(i)
        for c in range(len(pairs)):
            var a = pairs[c].a
            var b = pairs[c].b
            if not self.statics[a] and not self.statics[b]:
                parent[self._find(parent, a)] = self._find(parent, b)
        for c in range(len(self.joints)):
            var a = self.joints[c].a
            var b = self.joints[c].b
            if not self.statics[a] and not self.statics[b]:
                parent[self._find(parent, a)] = self._find(parent, b)
        # labels + island-wide wake
        while len(self.island) < n:
            self.island.append(-1)
        for i in range(n):
            self.island[i] = -1 if self.statics[i] else self._find(parent, i)
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            # island member i is awake -> wake everyone sharing its label
            for j in range(n):
                if self.island[j] == self.island[i] and self.sleeping[j]:
                    self.sleeping[j] = False
                    self.sleep_timer[j] = 0

    def _update_sleep(mut self, dt: Real):
        """Advance per-body still-timers; a whole island sleeps together."""
        comptime LIN_TOL: Real = 0.01
        comptime ANG_TOL: Real = 0.05
        comptime SLEEP_TIME: Real = 0.5
        var n = len(self.bodies)
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            var v = self.bodies[i].linear_velocity()
            var w = self.bodies[i].omega_world()
            if dot(v, v) < LIN_TOL * LIN_TOL and dot(w, w) < ANG_TOL * ANG_TOL:
                self.sleep_timer[i] += dt
            else:
                self.sleep_timer[i] = 0
        # sleep islands whose every member has been still long enough
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            var all_still = True
            for j in range(n):
                if self.island[j] == self.island[i] and self.sleep_timer[
                    j
                ] < SLEEP_TIME:
                    all_still = False
                    break
            if all_still:
                for j in range(n):
                    if self.island[j] == self.island[i]:
                        self.sleeping[j] = True
                        self.bodies[j].halt()

    def add(mut self, var b: Self.B, half: Vec3, is_static: Bool) -> Int:
        self.bodies.append(b^)
        self.half.append(_Half(half))
        self.statics.append(is_static)
        self.sleeping.append(False)
        self.sleep_timer.append(0)
        self.island.append(-1)
        return len(self.bodies) - 1

    def _inactive(self, i: Int) -> Bool:
        return self.statics[i] or self.sleeping[i]

    def _solve_point(
        mut self,
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
        var va = Vec3(0, 0, 0)
        var ka = Real(0)
        if not self.statics[ia]:
            va = self.bodies[ia].velocity_at(p)
            ka = self.bodies[ia].inv_mass() + self.bodies[ia].angular_factor(
                p - self.bodies[ia].position(), n
            )
        var vb = Vec3(0, 0, 0)
        var kb = Real(0)
        if not self.statics[ib]:
            vb = self.bodies[ib].velocity_at(p)
            kb = self.bodies[ib].inv_mass() + self.bodies[ib].angular_factor(
                p - self.bodies[ib].position(), n
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
        if not self.statics[ia]:
            self.bodies[ia].apply_impulse(-j, p)
        if not self.statics[ib]:
            self.bodies[ib].apply_impulse(j, p)
        return new_acc

    def _axes(self, i: Int) -> Axes3:
        """World-frame box axes of body `i` (via `act`, representation-free)."""
        var o = self.bodies[i].act(Vec3(0, 0, 0))
        var out = InlineArray[Vec3, 3](fill=Vec3(0, 0, 0))
        out[0] = self.bodies[i].act(Vec3(1, 0, 0)) - o
        out[1] = self.bodies[i].act(Vec3(0, 1, 0)) - o
        out[2] = self.bodies[i].act(Vec3(0, 0, 1)) - o
        return out

    def _collect_pairs(mut self, warm: Bool, spec_dt: Real) -> List[_CPair]:
        """Manifolds at the current poses (brute-force pairs, ROTATED box-box
        manifold — tilted geometry produces restoring contacts). With `warm`,
        impulses are inherited from last frame's matching pair — point
        correspondence is by index (clipping emits points in a stable order
        while the pair's contact configuration persists).

        With `spec_dt > 0`, detection is SPECULATIVE (first-stage CCD, the
        Jolt/Box2D scheme): each pair's boxes are inflated by a margin scaled
        with how far the bodies can travel in one frame, and the margin is
        subtracted back from the depths — near-contacts enter the solver with
        NEGATIVE depth, and the `d < 0 -> bias = -d/h` branch stops fast
        movers AT the surface instead of letting them tunnel."""
        comptime SPEC_BASE: Real = 0.02
        var pairs = List[_CPair]()
        for i in range(len(self.bodies)):
            for j in range(i + 1, len(self.bodies)):
                if self.statics[i] and self.statics[j]:
                    continue
                var margin = Real(0)
                if spec_dt > 0:
                    var va = self.bodies[i].linear_velocity()
                    var vb = self.bodies[j].linear_velocity()
                    margin = SPEC_BASE + (
                        sqrt(dot(va, va)) + sqrt(dot(vb, vb))
                    ) * spec_dt
                var infl = Vec3(margin * 0.5, margin * 0.5, margin * 0.5)
                var m = box_box_manifold(
                    self.bodies[i].position(),
                    self._axes(i),
                    self.half[i].v + infl,
                    self.bodies[j].position(),
                    self._axes(j),
                    self.half[j].v + infl,
                )
                if m.hit and margin > 0:
                    for k in range(m.count):
                        m.depths[k] -= margin
                if m.hit:
                    var pr = _CPair(
                        i,
                        j,
                        m,
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                        InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                    )
                    for k in range(m.count):
                        pr.ra[k] = self.bodies[i].to_local(m.points[k])
                        pr.rb[k] = self.bodies[j].to_local(m.points[k])
                    if warm:
                        for c in range(len(self.cache)):
                            var old = self.cache[c]
                            if (
                                old.a == i
                                and old.b == j
                                and old.m.count == m.count
                            ):
                                pr.acc = old.acc
                                pr.acc_t1 = old.acc_t1
                                pr.acc_t2 = old.acc_t2
                                break
                    pairs.append(pr)
        return pairs^

    def _warm_start(mut self, pairs: List[_CPair]):
        """Apply the accumulated impulses at each anchor (Box2D v3 scheme: the
        soft solve's `-impulseScale·acc` term is what balances this out)."""
        for c in range(len(pairs)):
            var pr = pairs[c]
            if self._inactive(pr.a) and self._inactive(pr.b):
                continue
            var n = pr.m.normal
            var tb = _tangent_basis(n)
            for k in range(pr.m.count):
                var j = (
                    n * pr.acc[k]
                    + tb[0] * pr.acc_t1[k]
                    + tb[1] * pr.acc_t2[k]
                )
                if not self.statics[pr.a]:
                    self.bodies[pr.a].apply_impulse(
                        -j, self.bodies[pr.a].act(pr.ra[k])
                    )
                if not self.statics[pr.b]:
                    self.bodies[pr.b].apply_impulse(
                        j, self.bodies[pr.b].act(pr.rb[k])
                    )

    def step(mut self, dt: Real, gravity: Vec3, iters: Int = 8):
        # 1. Gravity on dynamic bodies (velocity level).
        for i in range(len(self.bodies)):
            if not self.statics[i]:
                var f = gravity / self.bodies[i].inv_mass()  # force = m·g
                self.bodies[i].integrate_force(dt, f, Vec3(0, 0, 0))
        # 2. Contact manifolds at the pre-solve poses.
        var pairs = self._collect_pairs(False, 0)
        # 3. Gauss-Seidel sweeps of accumulated per-point normal impulses.
        for _ in range(iters):
            for c in range(len(pairs)):
                var pr = pairs[c]
                for k in range(pr.m.count):
                    pr.acc[k] = self._solve_point(
                        pr.a,
                        pr.b,
                        pr.m.normal,
                        pr.m.points[k],
                        pr.m.depths[k],
                        dt,
                        pr.acc[k],
                    )
                pairs[c] = pr
        # 4. Advance poses.
        for i in range(len(self.bodies)):
            if not self.statics[i]:
                self.bodies[i].integrate_pose(dt)

    def _joint_axis(
        mut self,
        ia: Int,
        ib: Int,
        pwa: Vec3,
        pwb: Vec3,
        e: Vec3,
        c: Real,
        h: Real,
        bias_rate: Real,
        ms: Real,
        isc: Real,
        use_bias: Bool,
        acc_e: Real,
    ) -> Real:
        """One scalar equality-constraint solve along unit axis `e` with
        position error `c`; returns the accumulated-impulse delta."""
        var va = Vec3(0, 0, 0)
        var ka = Real(0)
        if not self.statics[ia]:
            va = self.bodies[ia].velocity_at(pwa)
            ka = self.bodies[ia].inv_mass() + self.bodies[ia].angular_factor(
                pwa - self.bodies[ia].position(), e
            )
        var vb = Vec3(0, 0, 0)
        var kb = Real(0)
        if not self.statics[ib]:
            vb = self.bodies[ib].velocity_at(pwb)
            kb = self.bodies[ib].inv_mass() + self.bodies[ib].angular_factor(
                pwb - self.bodies[ib].position(), e
            )
        var denom = ka + kb
        if denom <= 0:
            return 0
        var vr = dot(vb - va, e)
        var bias = bias_rate * c if use_bias else Real(0)
        var dl = -ms * (vr + bias) / denom - isc * acc_e
        var j = e * dl
        if not self.statics[ia]:
            self.bodies[ia].apply_impulse(-j, pwa)
        if not self.statics[ib]:
            self.bodies[ib].apply_impulse(j, pwb)
        return dl

    def _joint_sweep(
        mut self,
        h: Real,
        bias_rate: Real,
        ms: Real,
        isc: Real,
        use_bias: Bool,
        iters: Int,
    ):
        for _ in range(iters):
            for c in range(len(self.joints)):
                var jt = self.joints[c]
                if self._inactive(jt.a) and self._inactive(jt.b):
                    continue
                var pwa = self.bodies[jt.a].act(jt.la)
                var pwb = self.bodies[jt.b].act(jt.lb)
                var gap = pwb - pwa
                if jt.kind == JOINT_DISTANCE:
                    var l = sqrt(max(dot(gap, gap), Real(1e-12)))
                    var u = gap / l
                    var acc_s = dot(jt.acc, u)
                    var dl = self._joint_axis(
                        jt.a, jt.b, pwa, pwb, u, l - jt.rest,
                        h, bias_rate, ms, isc, use_bias, acc_s,
                    )
                    jt.acc = u * (acc_s + dl)
                else:
                    # ball part (shared by hinge): drive the anchor gap to 0.
                    for ax in range(3):
                        var e = Vec3(0, 0, 0)
                        e[ax] = 1
                        var dl = self._joint_axis(
                            jt.a, jt.b, pwa, pwb, e, gap[ax],
                            h, bias_rate, ms, isc, use_bias, jt.acc[ax],
                        )
                        jt.acc[ax] += dl
                    if jt.kind == JOINT_HINGE:
                        var oa = self.bodies[jt.a].act(jt.axis_a) - self.bodies[
                            jt.a
                        ].act(Vec3(0, 0, 0))
                        var ob = self.bodies[jt.b].act(jt.axis_b) - self.bodies[
                            jt.b
                        ].act(Vec3(0, 0, 0))
                        var er = _cross(oa, ob)  # small-angle axis error
                        var wa = Vec3(0, 0, 0)
                        var wb2 = Vec3(0, 0, 0)
                        if not self.statics[jt.a]:
                            wa = self.bodies[jt.a].omega_world()
                        if not self.statics[jt.b]:
                            wb2 = self.bodies[jt.b].omega_world()
                        var tb = _tangent_basis(oa)
                        for ti in range(2):
                            var t = tb[0] if ti == 0 else tb[1]
                            var kaa = Real(0)
                            var kbb = Real(0)
                            if not self.statics[jt.a]:
                                kaa = self.bodies[jt.a].angular_only_factor(t)
                            if not self.statics[jt.b]:
                                kbb = self.bodies[jt.b].angular_only_factor(t)
                            var den = kaa + kbb
                            if den <= 0:
                                continue
                            var vr = dot(wb2 - wa, t)
                            var bias = (
                                bias_rate * dot(er, t) if use_bias else Real(0)
                            )
                            var acc_t = dot(jt.acc_ang, t)
                            var dl = -ms * (vr + bias) / den - isc * acc_t
                            jt.acc_ang = jt.acc_ang + t * dl
                            var limp = t * dl
                            if not self.statics[jt.a]:
                                self.bodies[jt.a].apply_angular_impulse(-limp)
                            if not self.statics[jt.b]:
                                self.bodies[jt.b].apply_angular_impulse(limp)
                            wa = Vec3(0, 0, 0)
                            wb2 = Vec3(0, 0, 0)
                            if not self.statics[jt.a]:
                                wa = self.bodies[jt.a].omega_world()
                            if not self.statics[jt.b]:
                                wb2 = self.bodies[jt.b].omega_world()
                self.joints[c] = jt

    def _warm_start_joints(mut self):
        for c in range(len(self.joints)):
            var jt = self.joints[c]
            if self._inactive(jt.a) and self._inactive(jt.b):
                continue
            var pwa = self.bodies[jt.a].act(jt.la)
            var pwb = self.bodies[jt.b].act(jt.lb)
            if not self.statics[jt.a]:
                self.bodies[jt.a].apply_impulse(-jt.acc, pwa)
                if jt.kind == JOINT_HINGE:
                    self.bodies[jt.a].apply_angular_impulse(-jt.acc_ang)
            if not self.statics[jt.b]:
                self.bodies[jt.b].apply_impulse(jt.acc, pwb)
                if jt.kind == JOINT_HINGE:
                    self.bodies[jt.b].apply_angular_impulse(jt.acc_ang)

    def _soft_sweep(
        mut self,
        mut pairs: List[_CPair],
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
            for c in range(len(pairs)):
                var pr = pairs[c]
                if self._inactive(pr.a) and self._inactive(pr.b):
                    continue
                var n = pr.m.normal
                for k in range(pr.m.count):
                    var pwa = self.bodies[pr.a].act(pr.ra[k])
                    var pwb = self.bodies[pr.b].act(pr.rb[k])
                    # anchors coincided at prep with depth d0; separation since
                    # then is the anchor drift along the normal
                    var d = pr.m.depths[k] - dot(pwb - pwa, n)
                    var va = Vec3(0, 0, 0)
                    var ka = Real(0)
                    if not self.statics[pr.a]:
                        va = self.bodies[pr.a].velocity_at(pwa)
                        ka = self.bodies[pr.a].inv_mass() + self.bodies[
                            pr.a
                        ].angular_factor(pwa - self.bodies[pr.a].position(), n)
                    var vb = Vec3(0, 0, 0)
                    var kb = Real(0)
                    if not self.statics[pr.b]:
                        vb = self.bodies[pr.b].velocity_at(pwb)
                        kb = self.bodies[pr.b].inv_mass() + self.bodies[
                            pr.b
                        ].angular_factor(pwb - self.bodies[pr.b].position(), n)
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
                        if not self.statics[pr.a]:
                            self.bodies[pr.a].apply_impulse(-j, pwa)
                        if not self.statics[pr.b]:
                            self.bodies[pr.b].apply_impulse(j, pwb)
                    # Coulomb friction: tangent impulses clamped to mu * lambda_n.
                    var tb = _tangent_basis(n)
                    var cap = mu * pr.acc[k]
                    for ti in range(2):
                        var t = tb[0] if ti == 0 else tb[1]
                        var vat = Vec3(0, 0, 0)
                        var kat = Real(0)
                        if not self.statics[pr.a]:
                            vat = self.bodies[pr.a].velocity_at(pwa)
                            kat = self.bodies[pr.a].inv_mass() + self.bodies[
                                pr.a
                            ].angular_factor(
                                pwa - self.bodies[pr.a].position(), t
                            )
                        var vbt = Vec3(0, 0, 0)
                        var kbt = Real(0)
                        if not self.statics[pr.b]:
                            vbt = self.bodies[pr.b].velocity_at(pwb)
                            kbt = self.bodies[pr.b].inv_mass() + self.bodies[
                                pr.b
                            ].angular_factor(
                                pwb - self.bodies[pr.b].position(), t
                            )
                        var dent = kat + kbt
                        if dent <= 0:
                            continue
                        var vt = dot(vbt - vat, t)
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
                            if not self.statics[pr.a]:
                                self.bodies[pr.a].apply_impulse(-jt, pwa)
                            if not self.statics[pr.b]:
                                self.bodies[pr.b].apply_impulse(jt, pwb)
                pairs[c] = pr

    def _ccd_advance(mut self, h: Real):
        """Swept/TOI pose advance (second-stage CCD, Jolt LinearCast
        direction): a body whose relative travel this substep could jump the
        thinnest feature of a pair linear-casts its box along the substep
        displacement (`swept_box_toi`) and advances only to the time of
        impact, minus a hair of back-off — the speculative solver then removes
        the approach velocity with the pair already AT the surface, so the
        midplane can never be crossed. Slow bodies take the plain pose step,
        bit-identical to the non-CCD path (zero-regression guarantee). Clamp
        fractions are decided against the substep-start snapshot before any
        pose moves, so mutually-approaching fast pairs resolve symmetrically
        (the relative displacement already contains both velocities)."""
        var n = len(self.bodies)
        var frac = List[Real]()
        for _ in range(n):
            frac.append(1)
        for i in range(n):
            if self._inactive(i):
                continue
            var vi = self.bodies[i].linear_velocity()
            if dot(vi, vi) * h * h < 1e-12:
                continue
            for j in range(n):
                if j == i:
                    continue
                var vj = Vec3(0, 0, 0)
                if not self._inactive(j):
                    vj = self.bodies[j].linear_velocity()
                var rel = (vi - vj) * h
                var ha = self.half[i].v
                var hb = self.half[j].v
                var thin = min(
                    min(ha[0], min(ha[1], ha[2])),
                    min(hb[0], min(hb[1], hb[2])),
                )
                if dot(rel, rel) <= (thin * 0.5) * (thin * 0.5):
                    continue  # cannot jump the pair's thinnest feature
                var r = swept_box_toi(
                    self.bodies[j].position(),
                    self._axes(j),
                    hb,
                    self.bodies[i].position(),
                    self._axes(i),
                    ha,
                    rel,
                )
                if r.hit and r.t < frac[i]:
                    frac[i] = r.t
        for i in range(n):
            if self._inactive(i):
                continue
            var f = frac[i]
            if f < 1:
                f = max(f - Real(0.01), 0)
            self.bodies[i].integrate_pose(h * f)

    def step_soft(
        mut self,
        dt: Real,
        gravity: Vec3,
        substeps: Int = 4,
        iters: Int = 4,
        hertz: Real = 30,
        zeta: Real = 10,
        mu: Real = 0.5,
        ccd: Bool = False,
    ):
        """Sub-stepped soft-constraint step (Box2D v3 "Soft Step" scheme):
        collide once, then per substep integrate velocities, solve with soft
        bias, integrate poses, and RELAX (bias-free sweep) so the bias energy
        never becomes bounce."""
        var h = dt / Real(substeps)
        var omega = Real(6.283185307179586) * hertz
        var c = h * omega * (2 * zeta + h * omega)
        var bias_rate = omega / (2 * zeta + h * omega)
        var mass_scale = c / (1 + c)
        var impulse_scale = 1 / (1 + c)
        var pairs = self._collect_pairs(True, dt)
        self._refresh_islands(pairs)
        for _ in range(substeps):
            for i in range(len(self.bodies)):
                if not self._inactive(i):
                    var f = gravity / self.bodies[i].inv_mass()
                    self.bodies[i].integrate_force(h, f, Vec3(0, 0, 0))
            # Warm start: re-apply accumulated impulses; the soft solve's
            # -impulseScale·acc decay is the matching counter-term.
            self._warm_start(pairs)
            self._warm_start_joints()
            self._joint_sweep(
                h, bias_rate, mass_scale, impulse_scale, True, iters
            )
            self._soft_sweep(
                pairs, h, bias_rate, mass_scale, impulse_scale, True, iters, mu
            )
            if ccd:
                self._ccd_advance(h)
            else:
                for i in range(len(self.bodies)):
                    if not self._inactive(i):
                        self.bodies[i].integrate_pose(h)
            # relax: remove the bias energy (velocity-only, no bias)
            self._joint_sweep(h, bias_rate, 1, 0, False, 2)
            self._soft_sweep(pairs, h, bias_rate, 1, 0, False, 2, mu)
        self._update_sleep(dt)
        self.cache = pairs^  # impulses persist to the next frame
