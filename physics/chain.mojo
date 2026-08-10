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


@fieldwise_init
struct ChainLink(Copyable, ImplicitlyCopyable, Movable):
    var axis: Vec3  # revolute axis, unit, link frame
    var pivot: Vec3  # this joint's position in the PARENT link frame
    var com: Vec3  # centre of mass, link frame
    var mass: Real
    var i_diag: Vec3  # principal inertia about the COM


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
                * Motor3.from_translation(l.pivot)
                * Motor3.from_quat(Quat.from_axis_angle(l.axis, self.q[i]))
            )
            out.append(pose)
        return out^

    def _joint_rot(self, i: Int) -> Quat:
        return Quat.from_axis_angle(self.links[i].axis, self.q[i])

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
            var w_here = _matvec(rt, w_p) + l.axis * self.qd[i]
            var v_here = _matvec(rt, v_p + _cross(w_p, l.pivot))
            # SPATIAL accelerations: same transform as velocities, plus the
            # velocity-product joint term  v_i ×ₘ (S q̇) with S = (axis, 0),
            # plus the joint acceleration S·q̈ (zero in the bias case).
            var wa_here = (
                _matvec(rt, wa_p)
                + _cross(w_here, l.axis * self.qd[i])
                + l.axis * qdd[i]
            )
            var va_here = _matvec(rt, va_p + _cross(wa_p, l.pivot)) + _cross(
                v_here, l.axis * self.qd[i]
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
            out[i2] = dot(self.links[i2].axis, fw[i2].v)
            var par = self.parent[i2]
            if par >= 0:
                # push into the parent frame (rotate by R, shift by pivot)
                var q = self._joint_rot(i2)
                var fw_p = q.rotate(fw[i2].v)
                var fv_p = q.rotate(fv[i2].v)
                fw[par] = _LV(
                    fw[par].v + fw_p + _cross(self.links[i2].pivot, fv_p)
                )
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

    def dynamics(self, tau: List[Real], gravity: Vec3) raises -> List[Real]:
        """qdd = H⁻¹ (tau − C): CRBA mass matrix + RNEA bias, dense solve."""
        var n = len(self.links)
        var zero_qdd = List[Real]()
        for _ in range(n):
            zero_qdd.append(0)
        var c_bias = self._rnea(zero_qdd, gravity)
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
            var p = self.links[i3].pivot
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
            var f = comp[i].apply(self.links[i].axis, Vec3(0, 0, 0))
            var fwc = f[0]
            var fvc = f[1]
            hmat[i * n + i] = dot(self.links[i].axis, fwc)
            var j = i
            while self.parent[j] >= 0:
                var q = self._joint_rot(j)
                var p = self.links[j].pivot
                var fw_pp = q.rotate(fwc)
                var fv_pp = q.rotate(fvc)
                fwc = fw_pp + _cross(p, fv_pp)
                fvc = fv_pp
                j = self.parent[j]
                hmat[i * n + j] = dot(self.links[j].axis, fwc)
                hmat[j * n + i] = hmat[i * n + j]
        # --- solve H qdd = tau - C (Gaussian elimination, partial pivot) ---
        var rhs = List[Real]()
        for i in range(n):
            rhs.append(tau[i] - c_bias[i])
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
