"""Reduced-coordinate articulated chains (the Featherstone direction).

A serial chain of revolute joints integrated in JOINT space: n coordinates
for n joints, constraints exact by construction — the reduced-coordinate
counterpart to `ContactScene6`'s maximal-coordinate hinge joints (soft
constraints). Two completely independent formulations of the same mechanics,
which makes their agreement a strong cross-validation gate
(`test_chain`), and their cost difference a fair benchmark.

This slice implements CRBA + RNEA (mass matrix + bias forces) with the
COMPACT spatial-inertia form {m, h = m·c, I_o (3x3 about the link origin)} —
rigid and composite inertias both stay in this form for a serial chain, so no
6x6 matrices appear anywhere. Forward kinematics runs on PGA motors
(`Motor3`), keeping the engine's "Featherstone spatial vectors are motors"
thesis literal. The O(n) articulated-body algorithm (ABA) is the follow-up;
CRBA+RNEA is O(n^2)/O(n^3), which at game chain lengths is already fast.

Conventions (Featherstone RBDA): all spatial quantities in the LINK frame;
joint i rotates about `axis` (unit, link frame); the link frame origin sits ON
the joint; the child pivot is at `pivot` in this link's frame.
"""

from std.math import sqrt, cos, sin
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.motor import Motor3


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


comptime _Rows3 = InlineArray[Vec3, 3]


@fieldwise_init
struct _LV(Copyable, ImplicitlyCopyable, Movable):
    """Struct-wrapped Vec3 (bare List[SIMD3] corrupts on this nightly)."""

    var v: Vec3


def _sym_add(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = a[i] + b[i]
    return r


def _matvec(m: _Rows3, v: Vec3) -> Vec3:
    return Vec3(dot(m[0], v), dot(m[1], v), dot(m[2], v))


def _rot_rows(q: Quat) -> _Rows3:
    """Rows of Rᵀ (so `_matvec(rt, v)` = Rᵀ·v, world/parent -> local).
    Row i of Rᵀ is column i of R — exactly the image of basis vector i."""
    var r = _Rows3(fill=Vec3(0, 0, 0))
    r[0] = q.rotate(Vec3(1, 0, 0))
    r[1] = q.rotate(Vec3(0, 1, 0))
    r[2] = q.rotate(Vec3(0, 0, 1))
    return r


@fieldwise_init
struct SpInertia(Copyable, ImplicitlyCopyable, Movable):
    """Compact spatial inertia about the frame origin: {m, h = m·c, I_o}."""

    var m: Real
    var h: Vec3
    var io: _Rows3

    @staticmethod
    def of_link(mass: Real, com: Vec3, i_diag: Vec3) -> Self:
        """Rigid link: principal inertia about its COM, offset to the origin
        (parallel axis: I_o = I_c + m(|c|² 1 − c cᵀ))."""
        var c = com
        var c2 = dot(c, c)
        var io = _Rows3(fill=Vec3(0, 0, 0))
        for i in range(3):
            var row = Vec3(0, 0, 0)
            for j in range(3):
                var v = -mass * c[i] * c[j]
                if i == j:
                    v += mass * c2 + i_diag[i]
                row[j] = v
            io[i] = row
        return Self(mass, c * mass, io)

    def apply(self, w: Vec3, v: Vec3) -> Tuple[Vec3, Vec3]:
        """Spatial momentum/force map: (Iw + h×v, m·v − h×w)."""
        return (
            _matvec(self.io, w) + _cross(self.h, v),
            v * self.m - _cross(self.h, w),
        )


comptime JOINT_REVOLUTE = 0
comptime JOINT_PRISMATIC = 1


@fieldwise_init
struct ChainLink(Copyable, ImplicitlyCopyable, Movable):
    var axis: Vec3  # joint axis, unit, link frame
    var pivot: Vec3  # this joint's position in the PARENT link frame
    var com: Vec3  # centre of mass, link frame
    var mass: Real
    var i_diag: Vec3  # principal inertia about the COM
    var kind: Int  # JOINT_REVOLUTE | JOINT_PRISMATIC
    var lo: Real  # joint limit, low (lo >= hi disables limits)
    var hi: Real

    @staticmethod
    def revolute(
        axis: Vec3, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) -> Self:
        return Self(axis, pivot, com, mass, i_diag, JOINT_REVOLUTE, 1, -1)

    @staticmethod
    def prismatic(
        axis: Vec3, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) -> Self:
        """A sliding joint: `q` translates along `axis` instead of rotating.

        The whole difference in the dynamics is the MOTION SUBSPACE — S is
        (axis, 0) for a revolute joint and (0, axis) for a prismatic one — so
        every sweep that projects onto S needs the same two-way branch, and
        nothing else changes. That is why the joint kind lives on the link
        rather than in a separate solver path."""
        return Self(axis, pivot, com, mass, i_diag, JOINT_PRISMATIC, 1, -1)

    def limited(self, lo: Real, hi: Real) -> Self:
        """Copy with a joint range. `lo >= hi` means unlimited, which is the
        default, so an unconstrained joint costs no branch in the limit pass."""
        return Self(
            self.axis, self.pivot, self.com, self.mass, self.i_diag,
            self.kind, lo, hi,
        )

    def has_limits(self) -> Bool:
        return self.hi > self.lo


struct Chain(Movable, ImplicitlyDeletable):
    var links: List[ChainLink]
    var q: List[Real]
    var qd: List[Real]
    # parent link index (-1 = root); serial add_link chains i-1 -> i, and
    # add_link_to grows TREES (ragdolls) / forests (parent = -1 anywhere).
    # Parents always precede children (append order), so every forward
    # sweep can read parent state by index.
    var parent: List[Int]

    def __init__(out self):
        self.links = List[ChainLink]()
        self.q = List[Real]()
        self.qd = List[Real]()
        self.parent = List[Int]()

    def add_link(mut self, link: ChainLink):
        self.links.append(link)
        self.q.append(0)
        self.qd.append(0)
        self.parent.append(len(self.links) - 2)

    def add_link_to(mut self, p: Int, link: ChainLink) raises -> Int:
        """Attach under link `p` (or -1 for a new root); returns the index."""
        if p >= len(self.links):
            raise Error("parent must exist before the child")
        self.links.append(link)
        self.q.append(0)
        self.qd.append(0)
        self.parent.append(p)
        return len(self.links) - 1

    def fk(self) raises -> List[Motor3]:
        """World pose of every link frame — pure motor composition (GA)."""
        var out = List[Motor3]()
        for i in range(len(self.links)):
            var l = self.links[i]
            var base = Motor3.identity()
            if self.parent[i] >= 0:
                base = out[self.parent[i]]
            var pose = (
                base
                * Motor3.from_translation(self._joint_offset(i))
                * Motor3.from_quat(self._joint_rot(i))
            )
            out.append(pose)
        return out^

    def _joint_rot(self, i: Int) -> Quat:
        """Parent -> link rotation. A prismatic joint does not rotate."""
        if self.links[i].kind == JOINT_PRISMATIC:
            return Quat.identity()
        return Quat.from_axis_angle(self.links[i].axis, self.q[i])

    def _joint_offset(self, i: Int) -> Vec3:
        """This joint's origin in the PARENT frame. A prismatic joint slides
        its own origin along the axis, so `q` enters here instead of in the
        rotation."""
        var l = self.links[i]
        if l.kind == JOINT_PRISMATIC:
            return l.pivot + l.axis * self.q[i]
        return l.pivot

    def _rnea(self, qdd: List[Real], gravity: Vec3) raises -> List[Real]:
        """Recursive Newton-Euler: the joint torques that produce `qdd`.

        With `qdd = 0` this is the bias term C(q, q̇) that `dynamics` subtracts;
        with a real `qdd` it IS exact inverse dynamics, because the only
        difference is the joint-acceleration term `S·q̈` entering the forward
        sweep. Sharing one routine is what makes `inverse_dynamics` free rather
        than a second implementation to keep in sync — and what lets the
        round-trip test (τ → q̈ → τ) actually mean something."""
        var n = len(self.links)
        # --- forward pass: link-frame velocities and accelerations ---------
        var ws = List[_LV]()  # angular velocity, link frame
        var vs = List[_LV]()  # linear velocity of frame origin, link frame
        var wa = List[_LV]()  # angular acceleration
        var va = List[_LV]()  # linear acceleration (incl. -gravity)
        # gravity trick: the base "accelerates" at −g so every link feels
        # weight (standard Featherstone convention; the analytic pendulum and
        # the large-swing energy gates guard the sign chain end-to-end)
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var v_p = vs[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var wa_p = wa[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var va_p = va[pi].v if pi >= 0 else -gravity
            var rt = _rot_rows(self._joint_rot(i))  # parent -> link (Rᵀ)
            var off = self._joint_offset(i)
            # motion subspace: S = (axis, 0) revolute, (0, axis) prismatic
            var rev = l.kind == JOINT_REVOLUTE
            var s_w = l.axis if rev else Vec3(0, 0, 0)
            var s_v = Vec3(0, 0, 0) if rev else l.axis
            var w_here = _matvec(rt, w_p) + s_w * self.qd[i]
            var v_here = _matvec(rt, v_p + _cross(w_p, off)) + s_v * self.qd[i]
            # SPATIAL accelerations: same transform as velocities, plus the
            # velocity-product joint term  v_i ×ₘ (S q̇) with S = (axis, 0),
            # plus the joint acceleration S·q̈ (zero in the bias case).
            var wa_here = (
                _matvec(rt, wa_p)
                + _cross(w_here, s_w * self.qd[i])
                + s_w * qdd[i]
            )
            var va_here = (
                _matvec(rt, va_p + _cross(wa_p, off))
                + _cross(v_here, s_w * self.qd[i])
                + _cross(w_here, s_v * self.qd[i]) * 2
                + s_v * qdd[i]
            )
            ws.append(_LV(w_here))
            vs.append(_LV(v_here))
            wa.append(_LV(wa_here))
            va.append(_LV(va_here))
        # --- backward: link forces -> joint torques ------------------------
        var fw = List[_LV]()  # angular (torque) part, link frame
        var fv = List[_LV]()  # linear part
        for i in range(n):
            var li = self.links[i]
            var ii = SpInertia.of_link(li.mass, li.com, li.i_diag)
            var mom = ii.apply(ws[i].v, vs[i].v)
            var acc = ii.apply(wa[i].v, va[i].v)
            # f = I a + v ×* (I v)
            fw.append(
                _LV(acc[0] + _cross(ws[i].v, mom[0]) + _cross(vs[i].v, mom[1]))
            )
            fv.append(_LV(acc[1] + _cross(ws[i].v, mom[1])))
        var out = List[Real]()
        for _ in range(n):
            out.append(0)
        var i2 = n - 1
        while i2 >= 0:
            var li2 = self.links[i2]
            # tau = Sᵀ f: the angular half for a revolute joint, the linear
            # half for a prismatic one
            if li2.kind == JOINT_REVOLUTE:
                out[i2] = dot(li2.axis, fw[i2].v)
            else:
                out[i2] = dot(li2.axis, fv[i2].v)
            var par = self.parent[i2]
            if par >= 0:
                # push into the parent frame (rotate by R, shift by the joint
                # offset — which slides for a prismatic joint)
                var q = self._joint_rot(i2)
                var off2 = self._joint_offset(i2)
                var fw_p = q.rotate(fw[i2].v)
                var fv_p = q.rotate(fv[i2].v)
                fw[par] = _LV(fw[par].v + fw_p + _cross(off2, fv_p))
                fv[par] = _LV(fv[par].v + fv_p)
            i2 -= 1
        return out^

    def inverse_dynamics(
        self, qdd: List[Real], gravity: Vec3
    ) raises -> List[Real]:
        """τ = ID(q, q̇, q̈) — exact, O(n), no mass matrix formed.

        The control-side counterpart of `dynamics`: feed-forward torques,
        contact-force estimation and system identification all start here.
        Note it costs O(n) where inverting the mass matrix costs O(n³), which
        is the whole reason a controller uses ID rather than solving FD
        backwards."""
        return self._rnea(qdd, gravity)

    def mass_matrix(self) raises -> List[Real]:
        """The CRBA joint-space inertia H, row-major n x n.

        Exposed because contact resolution needs it: an impulse applied at a
        point costs `J H⁻¹ Jᵀ` in effective mass, so the contact solver cannot
        work from forward dynamics alone. `dynamics` calls this rather than
        keeping its own copy."""
        var n = len(self.links)
        # --- CRBA: composite inertias + mass matrix ------------------------
        var comp = List[SpInertia]()
        for i in range(n):
            var li = self.links[i]
            comp.append(SpInertia.of_link(li.mass, li.com, li.i_diag))
        var i3 = n - 1
        while i3 > 0:
            if self.parent[i3] < 0:
                i3 -= 1
                continue
            # fold child composite into the parent frame
            var q = self._joint_rot(i3)
            var p = self._joint_offset(i3)
            var ci = comp[i3]
            var h_p = q.rotate(ci.h) + p * ci.m
            # R I Rᵀ (columns = R·I·Rᵀ·e_a), assembled into rows explicitly
            var rt = _rot_rows(q)  # Rᵀ rows
            var c0 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(1, 0, 0))))
            var c1 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(0, 1, 0))))
            var c2 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(0, 0, 1))))
            var rrows = _Rows3(fill=Vec3(0, 0, 0))
            rrows[0] = Vec3(c0[0], c1[0], c2[0])
            rrows[1] = Vec3(c0[1], c1[1], c2[1])
            rrows[2] = Vec3(c0[2], c1[2], c2[2])
            var hr = q.rotate(ci.h)
            # parallel-axis for the shift p with total mass m and moment hr:
            # I_o' = RIRᵀ + m(pᵀp 1 − ppᵀ) + (p hrᵀ + hr pᵀ) − 2(p·hr)... use
            # the exact identity: I' = RIRᵀ − p×[hr]× − [p]×[hr+mp]×
            var px_hr = _cross_mat_mul(p, hr)
            var px_hmp = _cross_mat_mul(p, hr + p * ci.m)
            for r in range(3):
                rrows[r] = rrows[r] - px_hr[r] - _transpose_row(px_hmp, r)
            var par3 = self.parent[i3]
            comp[par3] = SpInertia(
                comp[par3].m + ci.m,
                comp[par3].h + h_p,
                _sym_add(comp[par3].io, rrows),
            )
            i3 -= 1
        # H[i][j]: propagate F = I^C_i S_i toward the base
        var hmat = List[Real]()  # n*n row-major
        for _ in range(n * n):
            hmat.append(0)
        for i in range(n):
            var li = self.links[i]
            var rev_i = li.kind == JOINT_REVOLUTE
            var f = (
                comp[i].apply(li.axis, Vec3(0, 0, 0)) if rev_i
                else comp[i].apply(Vec3(0, 0, 0), li.axis)
            )
            var fwc = f[0]
            var fvc = f[1]
            hmat[i * n + i] = dot(li.axis, fwc) if rev_i else dot(li.axis, fvc)
            var j = i
            while self.parent[j] >= 0:
                var q = self._joint_rot(j)
                var p = self._joint_offset(j)
                var fw_pp = q.rotate(fwc)
                var fv_pp = q.rotate(fvc)
                fwc = fw_pp + _cross(p, fv_pp)
                fvc = fv_pp
                j = self.parent[j]
                var lj = self.links[j]
                hmat[i * n + j] = (
                    dot(lj.axis, fwc) if lj.kind == JOINT_REVOLUTE
                    else dot(lj.axis, fvc)
                )
                hmat[j * n + i] = hmat[i * n + j]
        return hmat^

    @staticmethod
    def solve_h(var hmat: List[Real], var rhs: List[Real], n: Int) -> List[Real]:
        """Dense solve of `H x = rhs` (Gaussian elimination, partial pivot).

        Static and taking its operands by value so the contact solver can reuse
        it for `H⁻¹ Jᵀ` without re-deriving H per contact."""
        for col in range(n):
            var piv = col
            var best = abs(hmat[col * n + col])
            for r in range(col + 1, n):
                if abs(hmat[r * n + col]) > best:
                    best = abs(hmat[r * n + col])
                    piv = r
            if piv != col:
                for cc in range(n):
                    var tmp = hmat[col * n + cc]
                    hmat[col * n + cc] = hmat[piv * n + cc]
                    hmat[piv * n + cc] = tmp
                var tr = rhs[col]
                rhs[col] = rhs[piv]
                rhs[piv] = tr
            var d = hmat[col * n + col]
            for r in range(col + 1, n):
                var fscale = hmat[r * n + col] / d
                for cc in range(col, n):
                    hmat[r * n + cc] -= fscale * hmat[col * n + cc]
                rhs[r] -= fscale * rhs[col]
        var qdd = List[Real]()
        for _ in range(n):
            qdd.append(0)
        var rr2 = n - 1
        while rr2 >= 0:
            var acc = rhs[rr2]
            for cc in range(rr2 + 1, n):
                acc -= hmat[rr2 * n + cc] * qdd[cc]
            qdd[rr2] = acc / hmat[rr2 * n + rr2]
            rr2 -= 1
        return qdd^

    def dynamics(self, tau: List[Real], gravity: Vec3) raises -> List[Real]:
        """qdd = H⁻¹ (tau − C): CRBA mass matrix + RNEA bias, dense solve."""
        var n = len(self.links)
        var zero_qdd = List[Real]()
        for _ in range(n):
            zero_qdd.append(0)
        var c_bias = self._rnea(zero_qdd, gravity)
        var hmat = self.mass_matrix()
        var rhs = List[Real]()
        for i in range(n):
            rhs.append(tau[i] - c_bias[i])
        return Self.solve_h(hmat^, rhs^, n)


    # ------------------------------------------------ contact coupling
    # A reduced-coordinate body has no world-space impulse to push on: every
    # force must arrive through the joints. The bridge is the point Jacobian —
    # the row mapping joint velocities to the velocity of one material point
    # along one direction — and its transpose, which maps an impulse at that
    # point back to joint torques. `J H⁻¹ Jᵀ` is then the effective mass the
    # contact sees, which is what makes the impulse solvable in joint space.

    def point_world(self, i: Int, local: Vec3) raises -> Vec3:
        """World position of a point given in link `i`'s frame."""
        var poses = self.fk()
        return poses[i].apply_point(local)

    def point_jacobian(
        self, i: Int, local: Vec3, dir: Vec3
    ) raises -> List[Real]:
        """Row `J` with `J q̇ = (velocity of the point) · dir`.

        Only ancestors of link `i` contribute: a joint that is not on the path
        to the root cannot move the point at all, and its column is exactly
        zero. Walking the ancestor chain rather than all joints is what keeps
        this O(depth) instead of O(n)."""
        var n = len(self.links)
        var poses = self.fk()
        var pw = poses[i].apply_point(local)
        var j = List[Real]()
        for _ in range(n):
            j.append(0)
        var k = i
        while k >= 0:
            # joint k's axis and origin in world (one decomposition serves
            # both: the quaternion rotates the axis, the translation IS the
            # joint origin)
            var qt = poses[k].to_quat_translation()
            var axis_w = qt[0].rotate(self.links[k].axis)
            var origin_w = qt[1]
            if self.links[k].kind == JOINT_REVOLUTE:
                # revolute: the point moves at omega x r
                j[k] = dot(_cross(axis_w, pw - origin_w), dir)
            else:
                # prismatic: the point translates with the axis, independent
                # of where it sits relative to the joint
                j[k] = dot(axis_w, dir)
            k = self.parent[k]
        return j^

    def point_velocity(self, i: Int, local: Vec3, dir: Vec3) raises -> Real:
        var j = self.point_jacobian(i, local, dir)
        var v = Real(0)
        for k in range(len(j)):
            v += j[k] * self.qd[k]
        return v

    def apply_impulse_with(
        mut self, h: List[Real], i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """`apply_impulse` with the mass matrix supplied.

        H depends only on `q`, which does NOT change during a velocity
        iteration, so recomputing it per contact per iteration is pure waste —
        it made the contact pass cost an O(n³) solve times contacts times
        iterations, and dominated the step by ~29x at 2 links."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var hinv_jt = Self.solve_h(h.copy(), j.copy(), n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def apply_impulse(
        mut self, i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """Apply the impulse at (link `i`, `local`) along `dir` that changes the
        point's velocity along `dir` by `target_dv`. Returns the impulse.

        Effective mass is `1 / (J H⁻¹ Jᵀ)`; the velocity update is
        `Δq̇ = H⁻¹ Jᵀ λ`. Both need the same `H⁻¹ Jᵀ`, so it is solved once."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var h = self.mass_matrix()
        var hinv_jt = Self.solve_h(h^, j.copy(), n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0  # the point cannot be moved along `dir` by any joint
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def resolve_ground(
        mut self,
        floor_y: Real,
        restitution: Real,
        contacts: List[Int],
        locals: List[Vec3],
        dt: Real,
        iters: Int = 8,
    ) raises -> Int:
        """Sequential-impulse ground contact, SPLIT into velocity and position.

        The velocity pass applies only impulses that make the normal velocity
        non-negative, which by construction removes kinetic energy or leaves it
        alone. The penetration is then repaired in a SECOND pass that runs on a
        pseudo-velocity: it moves `q` and is discarded rather than accumulated
        into `q̇`.

        Doing both in one pass — a Baumgarte bias folded into the velocity
        target — is the obvious formulation and it PUMPS ENERGY: the positional
        term is not a physical impulse, so whatever it adds to the velocity
        stays there and comes back as speed on the next bounce. Measured here
        at nearly 3x the free-swinging peak before the split.

        Returns how many contacts were active on entry, not on exit: after a
        successful resolve none are active, so the exit count is always zero
        and would report "nothing touched" for every working contact."""
        var n = len(self.links)
        var initial_active = 0
        for c in range(len(contacts)):
            var pw = self.point_world(contacts[c], locals[c])
            if pw[1] <= floor_y:
                initial_active += 1
        if initial_active == 0:
            return 0

        var up = Vec3(0, 1, 0)
        # H is a function of q alone, so it is computed ONCE per pass rather
        # than per contact per iteration
        var h1 = self.mass_matrix()
        # --- pass 1: velocity only (physical impulses) ---------------------
        for _ in range(iters):
            for c in range(len(contacts)):
                var i = contacts[c]
                var pw = self.point_world(i, locals[c])
                if pw[1] > floor_y:
                    continue
                var vn = self.point_velocity(i, locals[c], up)
                if vn >= 0:
                    continue  # already separating
                _ = self.apply_impulse_with(
                    h1, i, locals[c], up, -(1 + restitution) * vn
                )

        # --- pass 2: positional repair on a pseudo-velocity ----------------
        var saved = self.qd.copy()
        var h2 = self.mass_matrix()
        for k in range(n):
            self.qd[k] = 0
        for _ in range(iters):
            for c in range(len(contacts)):
                var i = contacts[c]
                var pw = self.point_world(i, locals[c])
                var pen = floor_y - pw[1]
                if pen <= 0:
                    continue
                var vn = self.point_velocity(i, locals[c], up)
                var want = pen / dt - vn
                if want <= 0:
                    continue
                _ = self.apply_impulse_with(h2, i, locals[c], up, want)
        for k in range(n):
            self.q[k] += self.qd[k] * dt
            self.qd[k] = saved[k]
        return initial_active

    def resolve_limits(mut self, dt: Real, iters: Int = 8) raises -> Int:
        """Stop joints at their range, by impulse rather than by clamping.

        Clamping `q` directly is the tempting one-liner and it is wrong twice
        over: it leaves `q̇` pointing into the wall, so the joint re-violates
        every step and jitters, and it injects position without a corresponding
        impulse, so a limited joint silently gains energy. Solving it as a
        one-sided constraint uses the same machinery as contact — a joint's
        "Jacobian" is just the unit vector eₖ, so the effective mass is
        (H⁻¹)ₖₖ — and gets the same velocity/position split for free.

        Returns how many limits were violated on entry."""
        var n = len(self.links)
        var initial = 0
        for k in range(n):
            var l = self.links[k]
            if not l.has_limits():
                continue
            if self.q[k] < l.lo or self.q[k] > l.hi:
                initial += 1
        if initial == 0:
            return 0

        var h1 = self.mass_matrix()
        # --- velocity pass: kill motion INTO the stop ----------------------
        for _ in range(iters):
            for k in range(n):
                var l = self.links[k]
                if not l.has_limits():
                    continue
                var low = self.q[k] < l.lo
                var high = self.q[k] > l.hi
                if not (low or high):
                    continue
                # moving away from the stop already? leave it alone — a limit
                # is one-sided, and pushing back would glue the joint to it
                if low and self.qd[k] >= 0:
                    continue
                if high and self.qd[k] <= 0:
                    continue
                _ = self._joint_impulse(h1, k, -self.qd[k])

        # --- position pass on a pseudo-velocity, as in resolve_ground ------
        var saved = self.qd.copy()
        var h2 = self.mass_matrix()
        for k in range(n):
            self.qd[k] = 0
        for _ in range(iters):
            for k in range(n):
                var l = self.links[k]
                if not l.has_limits():
                    continue
                var err = Real(0)
                if self.q[k] < l.lo:
                    err = l.lo - self.q[k]
                elif self.q[k] > l.hi:
                    err = l.hi - self.q[k]
                else:
                    continue
                _ = self._joint_impulse(h2, k, err / dt - self.qd[k])
        for k in range(n):
            self.q[k] += self.qd[k] * dt
            self.qd[k] = saved[k]
        return initial

    def _joint_impulse(
        mut self, h: List[Real], k: Int, target_dv: Real
    ) raises -> Real:
        """Impulse along joint coordinate `k` alone: the contact machinery with
        `J = eₖ`, so the effective mass is the k-th diagonal of `H⁻¹`."""
        var n = len(self.links)
        var e = List[Real]()
        for i in range(n):
            e.append(Real(1) if i == k else Real(0))
        var hinv_e = Self.solve_h(h.copy(), e^, n)
        var w = hinv_e[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for i in range(n):
            self.qd[i] += hinv_e[i] * lam
        return lam

    def step(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """Semi-implicit Euler in joint space."""
        var qdd = self.dynamics(tau, gravity)
        for i in range(len(self.links)):
            self.qd[i] += qdd[i] * dt
            self.q[i] += self.qd[i] * dt

    def dynamics_aba(
        self, tau: List[Real], gravity: Vec3
    ) raises -> List[Real]:
        """qdd via the articulated-body algorithm (Featherstone RBDA 7.3):
        three O(n) sweeps instead of CRBA's O(n²) matrix + O(n³) solve.
        Same answer as `dynamics()` (parity-gated in test_aba); the U Uᵀ/d
        update breaks the compact {m,h,I_o} form, so articulated inertias
        carry full symmetric 6x6 blocks (`_ABI`)."""
        var n = len(self.links)
        # --- pass 1 (outward): velocities, joint bias c, bias force p ------
        var ws = List[_LV]()
        var vs = List[_LV]()
        var cw = List[_LV]()
        var cv = List[_LV]()
        var pw = List[_LV]()
        var pv = List[_LV]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var v_p = vs[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var rt = _rot_rows(self._joint_rot(i))
            var w_here = _matvec(rt, w_p) + l.axis * self.qd[i]
            var v_here = _matvec(rt, v_p + _cross(w_p, l.pivot))
            var sqd = l.axis * self.qd[i]
            cw.append(_LV(_cross(w_here, sqd)))
            cv.append(_LV(_cross(v_here, sqd)))
            var ii = SpInertia.of_link(l.mass, l.com, l.i_diag)
            var mom = ii.apply(w_here, v_here)
            pw.append(
                _LV(_cross(w_here, mom[0]) + _cross(v_here, mom[1]))
            )
            pv.append(_LV(_cross(w_here, mom[1])))
            ws.append(_LV(w_here))
            vs.append(_LV(v_here))
        # --- pass 2 (inward): articulated inertias ------------------------
        var ia = List[_ABI]()
        for i in range(n):
            var l = self.links[i]
            ia.append(_ABI.of(SpInertia.of_link(l.mass, l.com, l.i_diag)))
        var uw = List[_LV]()
        var uv = List[_LV]()
        var dd = List[Real]()
        var uu = List[Real]()
        for _ in range(n):
            uw.append(_LV(Vec3(0, 0, 0)))
            uv.append(_LV(Vec3(0, 0, 0)))
            dd.append(0)
            uu.append(0)
        var i2 = n - 1
        while i2 >= 0:
            var l = self.links[i2]
            var u_ = ia[i2].apply(l.axis, Vec3(0, 0, 0))
            uw[i2] = _LV(u_[0])
            uv[i2] = _LV(u_[1])
            dd[i2] = dot(l.axis, u_[0])
            uu[i2] = tau[i2] - dot(l.axis, pw[i2].v)
            var par = self.parent[i2]
            if par >= 0:
                var inv_d = 1 / dd[i2]
                # Ia = IA − U Uᵀ/d (rank-1, symmetric by construction)
                var a2 = _msub(ia[i2].a, _outer_scaled(u_[0], u_[0], inv_d))
                var b2 = _msub(ia[i2].b, _outer_scaled(u_[0], u_[1], inv_d))
                var d2 = _msub(ia[i2].d, _outer_scaled(u_[1], u_[1], inv_d))
                # pa = p^A + Ia c + U u/d
                var iac = _ABI(a2, b2, d2).apply(cw[i2].v, cv[i2].v)
                var paw = pw[i2].v + iac[0] + u_[0] * (uu[i2] * inv_d)
                var pav = pv[i2].v + iac[1] + u_[1] * (uu[i2] * inv_d)
                # into the parent frame: rotate blocks, then shift by pivot
                # (same composition as the force push in dynamics()):
                # A' = A₁ − B₁P + PB₁ᵀ − PD₁P ; B' = B₁ + PD₁ ; D' = D₁
                var q = self._joint_rot(i2)
                var p = l.pivot
                var a1 = _rot_mat(q, a2)
                var b1 = _rot_mat(q, b2)
                var d1 = _rot_mat(q, d2)
                var px = _skew(p)
                var ap = _msub(
                    _msub(
                        _madd(a1, _matmul(px, _transpose(b1))),
                        _matmul(b1, px),
                    ),
                    _matmul(_matmul(px, d1), px),
                )
                var bp = _madd(b1, _matmul(px, d1))
                ia[par] = _ABI(
                    _madd(ia[par].a, ap),
                    _madd(ia[par].b, bp),
                    _madd(ia[par].d, d1),
                )
                var fw_p = q.rotate(paw)
                var fv_p = q.rotate(pav)
                pw[par] = _LV(pw[par].v + fw_p + _cross(p, fv_p))
                pv[par] = _LV(pv[par].v + fv_p)
            i2 -= 1
        # --- pass 3 (outward): accelerations ------------------------------
        var qdd = List[Real]()
        for _ in range(n):
            qdd.append(0)
        var aw = List[_LV]()
        var av = List[_LV]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            # same base-acceleration gravity trick at every root
            var wa_p = aw[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var va_p = av[pi].v if pi >= 0 else -gravity
            var rt = _rot_rows(self._joint_rot(i))
            var w_a = _matvec(rt, wa_p) + cw[i].v
            var v_a = _matvec(rt, va_p + _cross(wa_p, l.pivot)) + cv[i].v
            qdd[i] = (
                uu[i] - dot(uw[i].v, w_a) - dot(uv[i].v, v_a)
            ) / dd[i]
            aw.append(_LV(w_a + l.axis * qdd[i]))
            av.append(_LV(v_a))
        return qdd^

    def step_aba(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """Semi-implicit Euler in joint space, O(n) dynamics."""
        var qdd = self.dynamics_aba(tau, gravity)
        for i in range(len(self.links)):
            self.qd[i] += qdd[i] * dt
            self.q[i] += self.qd[i] * dt

    def energy(self, gravity: Vec3) raises -> Real:
        """Kinetic (via the velocity recursion) + potential (via motor FK)."""
        var n = len(self.links)
        var e = Real(0)
        var poses = self.fk()
        var ws2 = List[_LV]()
        var vs2 = List[_LV]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws2[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var v_p = vs2[pi].v if pi >= 0 else Vec3(0, 0, 0)
            var rt = _rot_rows(self._joint_rot(i))
            var w = _matvec(rt, w_p) + l.axis * self.qd[i]
            var v = _matvec(rt, v_p + _cross(w_p, l.pivot))
            var ii = SpInertia.of_link(l.mass, l.com, l.i_diag)
            var mom = ii.apply(w, v)
            e += (dot(w, mom[0]) + dot(v, mom[1])) * 0.5
            var com_w = poses[i].apply_point(l.com)
            e -= l.mass * dot(gravity, com_w)
            ws2.append(_LV(w))
            vs2.append(_LV(v))
        return e


def _cross_mat_mul(a: Vec3, b: Vec3) -> _Rows3:
    """Rows of [a]× [b]× (product of two cross matrices)."""
    var r = _Rows3(fill=Vec3(0, 0, 0))
    var ab = dot(a, b)
    for i in range(3):
        var row = Vec3(0, 0, 0)
        for j in range(3):
            var v = b[i] * a[j]
            if i == j:
                v -= ab
            row[j] = v
        r[i] = row
    return r


def _transpose_row(m: _Rows3, r: Int) -> Vec3:
    return Vec3(m[0][r], m[1][r], m[2][r])


def _skew(p: Vec3) -> _Rows3:
    """Rows of [p]×."""
    var r = _Rows3(fill=Vec3(0, 0, 0))
    r[0] = Vec3(0, -p[2], p[1])
    r[1] = Vec3(p[2], 0, -p[0])
    r[2] = Vec3(-p[1], p[0], 0)
    return r


def _outer_scaled(u: Vec3, v: Vec3, s: Real) -> _Rows3:
    """Rows of s·(u vᵀ)."""
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = v * (u[i] * s)
    return r


def _matmul(x: _Rows3, y: _Rows3) -> _Rows3:
    """Rows of X·Y (both given as rows)."""
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = y[0] * x[i][0] + y[1] * x[i][1] + y[2] * x[i][2]
    return r


def _madd(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = a[i] + b[i]
    return r


def _msub(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = a[i] - b[i]
    return r


def _transpose(m: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = Vec3(m[0][i], m[1][i], m[2][i])
    return r


def _tmatvec(m: _Rows3, v: Vec3) -> Vec3:
    """Mᵀ·v for M given as rows."""
    return m[0] * v[0] + m[1] * v[1] + m[2] * v[2]


def _rot_mat(q: Quat, m: _Rows3) -> _Rows3:
    """Rows of R·M·Rᵀ for a general 3x3 M (column-wise, like dynamics())."""
    var rt = _rot_rows(q)
    var c0 = q.rotate(_matvec(m, _matvec(rt, Vec3(1, 0, 0))))
    var c1 = q.rotate(_matvec(m, _matvec(rt, Vec3(0, 1, 0))))
    var c2 = q.rotate(_matvec(m, _matvec(rt, Vec3(0, 0, 1))))
    var r = _Rows3(fill=Vec3(0, 0, 0))
    for i in range(3):
        r[i] = Vec3(c0[i], c1[i], c2[i])
    return r


@fieldwise_init
struct _ABI(Copyable, ImplicitlyCopyable, Movable):
    """Articulated-body inertia: symmetric 6x6 in {angular, linear} blocks
    [[A, B], [Bᵀ, D]]; the rank-1 U Uᵀ/d update breaks the rigid compact
    form, so ABA carries these where CRBA kept {m, h, I_o}."""

    var a: _Rows3
    var b: _Rows3
    var d: _Rows3

    @staticmethod
    def of(ii: SpInertia) -> Self:
        var b = _skew(ii.h)
        var d = _Rows3(fill=Vec3(0, 0, 0))
        d[0] = Vec3(ii.m, 0, 0)
        d[1] = Vec3(0, ii.m, 0)
        d[2] = Vec3(0, 0, ii.m)
        return Self(ii.io, b, d)

    def apply(self, w: Vec3, v: Vec3) -> Tuple[Vec3, Vec3]:
        """Force = [[A, B], [Bᵀ, D]] · (w, v)."""
        return (
            _matvec(self.a, w) + _matvec(self.b, v),
            _tmatvec(self.b, w) + _matvec(self.d, v),
        )
