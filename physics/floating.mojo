"""A floating base: six unconstrained degrees of freedom at the root.

Everything in `Chain` assumes the root is bolted down, so a reaction wrench of
any size is available for free and nobody has to account for it. That covers
arms and legs of a fixed machine and covers nothing that moves: a quadruped, a
free-flying body, a thrown ragdoll. Lifting the assumption means the six root
equations stop being satisfied automatically and become part of the solve.

The system is then

    | H_bb  H_bj | | a_base |   | C_b |   |  0  |
    |            | |        | + |     | = |     |
    | H_bj' H_jj | |  qdd   |   | C_j |   | tau |

with the top block reading "no external wrench acts on the base". Gravity
enters through the shift the sweeps already use — the root accelerates at -g —
so what the solve returns for the base is `a_base - g` and adding g back is
the last step. A free body with no joints then comes out at exactly g, which
is the cheapest possible check that the shift is applied once and in the right
direction.

The mass matrix is assembled by UNIT ACCELERATIONS: zero the velocities, drive
one direction at a time, and read the resulting wrench and torques as a
column. That is O((6+n) n) rather than CRBA's tighter recursion, and the
benchmark quantifies what it costs. The reason to take that trade here is that
it reuses the two sweeps that the fixed-base tests already exercise, so a
floating-base bug cannot be a transcription error in a second, parallel
derivation of the same inertia. Symmetry of the result is then a real check
rather than a tautology, since nothing in the construction enforces it.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from geometry.motor import Motor3
from physics.chain import Chain, ChainLink, SpInertia


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


struct FloatingChain(Movable, ImplicitlyDeletable):
    """A `Chain` carried by a free rigid body.

    The base state is held in BODY coordinates, which is what makes the
    integration simple: in body-fixed spatial coordinates the spatial
    acceleration IS the component-wise derivative of the spatial velocity,
    because a motion vector's spatial cross product with itself vanishes. So
    the velocity update is plain Euler and only the pose update needs the
    rotation."""

    var chain: Chain
    var base_pos: Vec3  # world
    var base_rot: Quat  # body -> world
    var base_w: Vec3  # angular velocity, BODY frame
    var base_v: Vec3  # linear velocity of the origin, BODY frame
    var base_mass: Real
    var base_com: Vec3
    var base_idiag: Vec3
    var pinned: Bool  # bolt the base down again — the parity switch
    var use_crba: Bool  # CRBA assembly (default) or unit accelerations

    def __init__(out self, mass: Real, com: Vec3, i_diag: Vec3):
        self.chain = Chain()
        self.base_pos = Vec3(0, 0, 0)
        self.base_rot = Quat.identity()
        self.base_w = Vec3(0, 0, 0)
        self.base_v = Vec3(0, 0, 0)
        self.base_mass = mass
        self.base_com = com
        self.base_idiag = i_diag
        self.pinned = False
        self.use_crba = True

    def n(self) -> Int:
        return len(self.chain.links)

    def dof(self) -> Int:
        return 6 + len(self.chain.links)

    def add_link(mut self, link: ChainLink):
        self.chain.add_link(link)

    def add_link_to(mut self, p: Int, link: ChainLink) raises -> Int:
        return self.chain.add_link_to(p, link)

    def _base_inertia(self) -> SpInertia:
        return SpInertia.of_link(self.base_mass, self.base_com, self.base_idiag)

    def _sync(mut self):
        self.chain.base_w = self.base_w
        self.chain.base_v = self.base_v

    def mass_matrix(mut self) raises -> List[Real]:
        """The (6+n)x(6+n) inertia, row-major, ordered [angular, linear, q].

        Two derivations, selected by `use_crba`, kept because they fail
        differently. CRBA extends the composite-inertia recursion the
        fixed-base path already uses and is what runs by default. The
        unit-acceleration form drives one direction at a time and reads the
        resulting wrench off the backward sweep — slower by an order of
        magnitude, but derived from nothing the CRBA path shares, so the test
        that demands they agree is a real cross-check and not a restatement.
        Keeping the slow one is the cost of that check being meaningful."""
        if self.use_crba:
            return self.chain.mass_matrix_floating(self._base_inertia())
        return self._mass_matrix_units()

    def _mass_matrix_units(mut self) raises -> List[Real]:
        """Columns from unit accelerations with the velocities zeroed: each
        backward sweep returns exactly the wrench and torques needed to
        produce that one unit acceleration and nothing else."""
        var nn = self.n()
        var d = 6 + nn
        var h = List[Real]()
        for _ in range(d * d):
            h.append(0)

        var save_w = self.base_w
        var save_v = self.base_v
        var save_qd = self.chain.qd.copy()
        self.base_w = Vec3(0, 0, 0)
        self.base_v = Vec3(0, 0, 0)
        for i in range(nn):
            self.chain.qd[i] = 0
        self._sync()

        var ib = self._base_inertia()
        for k in range(d):
            var aw = Vec3(0, 0, 0)
            var av = Vec3(0, 0, 0)
            var qdd = List[Real]()
            for _ in range(nn):
                qdd.append(0)
            if k < 3:
                aw = Vec3(
                    Real(1) if k == 0 else Real(0),
                    Real(1) if k == 1 else Real(0),
                    Real(1) if k == 2 else Real(0),
                )
            elif k < 6:
                av = Vec3(
                    Real(1) if k == 3 else Real(0),
                    Real(1) if k == 4 else Real(0),
                    Real(1) if k == 5 else Real(0),
                )
            else:
                qdd[k - 6] = 1
            self.chain.base_wa = aw
            self.chain.base_va = av
            var r = self.chain.rnea_root(qdd, Vec3(0, 0, 0))
            var tau = r[0].copy()
            var fw = r[1]
            var fv = r[2]
            if k < 6:  # the base body's own inertia loads only the base block
                var ba = ib.apply(aw, av)
                fw = fw + ba[0]
                fv = fv + ba[1]
            for j in range(3):
                h[j * d + k] = fw[j]
                h[(3 + j) * d + k] = fv[j]
            for j in range(nn):
                h[(6 + j) * d + k] = tau[j]

        self.chain.base_wa = Vec3(0, 0, 0)
        self.chain.base_va = Vec3(0, 0, 0)
        self.base_w = save_w
        self.base_v = save_v
        self.chain.qd = save_qd^
        self._sync()
        return h^

    def bias(mut self, gravity: Vec3) raises -> List[Real]:
        """`C(q, qd)` over all 6+n rows, with gravity left OUT.

        Gravity is reintroduced as a shift on the answer rather than a term
        here, which is what keeps the free-fall case exact: a body with no
        joints has an identically zero bias, so nothing can perturb the g that
        the shift puts back."""
        self._sync()
        var nn = self.n()
        var qdd = List[Real]()
        for _ in range(nn):
            qdd.append(0)
        self.chain.base_wa = Vec3(0, 0, 0)
        self.chain.base_va = Vec3(0, 0, 0)
        var r = self.chain.rnea_root(qdd, Vec3(0, 0, 0))
        var tau = r[0].copy()
        var fw = r[1]
        var fv = r[2]
        # the base body's own velocity-product force
        var ib = self._base_inertia()
        var mom = ib.apply(self.base_w, self.base_v)
        fw = fw + _cross(self.base_w, mom[0]) + _cross(self.base_v, mom[1])
        fv = fv + _cross(self.base_w, mom[1])
        var out = List[Real]()
        for j in range(3):
            out.append(fw[j])
        for j in range(3):
            out.append(fv[j])
        for j in range(nn):
            out.append(tau[j])
        return out^

    def dynamics(
        mut self, tau: List[Real], gravity: Vec3
    ) raises -> List[Real]:
        """Solve for `[base_wa, base_va, qdd]`, base frame.

        The unknown the system is actually written in is `y = a_base - g`,
        because that is the shifted quantity the sweeps consume. Free floating
        means no external wrench, so the six base rows read `0`; pinning means
        `a_base = 0`, so they read `y_base = -g` instead. Note that pinning
        does NOT drop the base columns from the joint rows — those columns
        multiplied by `-g` ARE the gravity torques on the joints, so removing
        them would silently switch gravity off for the articulated part. The
        exact-parity test against `Chain` is what makes that distinction
        checkable rather than a matter of opinion."""
        var nn = self.n()
        var d = 6 + nn
        var h = self.mass_matrix()
        var b = self.bias(gravity)

        var rhs = List[Real]()
        for j in range(6):
            rhs.append(-b[j])
        for j in range(nn):
            rhs.append(tau[j] - b[6 + j])

        var g_body = self.base_rot.conjugate().rotate(gravity)
        if self.pinned:
            # a_base = 0, so the shifted unknown is pinned to -g
            for r in range(6):
                for cc in range(d):
                    h[r * d + cc] = Real(1) if r == cc else Real(0)
                rhs[r] = 0 if r < 3 else -g_body[r - 3]

        var x = Chain.solve_h(h^, rhs^, d)
        # undo the shift: the solve returned a_base - g
        for j in range(3):
            x[3 + j] = x[3 + j] + g_body[j]
        return x^

    def step(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """Semi-implicit Euler on all 6+n coordinates."""
        var a = self.dynamics(tau, gravity)
        var nn = self.n()
        if not self.pinned:
            self.base_w = self.base_w + Vec3(a[0], a[1], a[2]) * dt
            self.base_v = self.base_v + Vec3(a[3], a[4], a[5]) * dt
        for i in range(nn):
            self.chain.qd[i] = self.chain.qd[i] + a[6 + i] * dt
        for i in range(nn):
            self.chain.q[i] = self.chain.q[i] + self.chain.qd[i] * dt
        if not self.pinned:
            # body-frame linear velocity moves the world origin through R
            self.base_pos = self.base_pos + self.base_rot.rotate(self.base_v) * dt
            var w = self.base_w * dt
            var ang = length(w)
            if ang > 1e-12:
                var dq = Quat.from_axis_angle(w * (1.0 / ang), ang)
                self.base_rot = (self.base_rot * dq).normalized()
        self._sync()

    def base_motor(self) -> Motor3:
        return Motor3.from_translation(self.base_pos) * Motor3.from_quat(
            self.base_rot
        )

    def fk(mut self) raises -> List[Motor3]:
        """Link poses in WORLD, i.e. the chain's own poses carried by the base."""
        var local = self.chain.fk()
        var bm = self.base_motor()
        var out = List[Motor3]()
        for i in range(len(local)):
            out.append(bm * local[i])
        return out^

    def momentum(mut self, gravity: Vec3) raises -> Tuple[Vec3, Vec3]:
        """Total linear and angular momentum about the WORLD origin.

        The independent conservation check. It is assembled from per-link
        world velocities rather than from `H`, so it shares no arithmetic with
        the solve it is meant to audit — a mass matrix that is wrong in a way
        the symmetry check misses still fails this one."""
        self._sync()
        var nn = self.n()
        var qdd = List[Real]()
        for _ in range(nn):
            qdd.append(0)
        var m = self.chain.link_motion(qdd, Vec3(0, 0, 0))
        var local = self.chain.fk()
        var bm = self.base_motor()

        var p_lin = Vec3(0, 0, 0)
        var l_ang = Vec3(0, 0, 0)

        # base body
        var bq = self.base_rot
        var w_w = bq.rotate(self.base_w)
        var com_w = self.base_pos + bq.rotate(self.base_com)
        var v_com = bq.rotate(self.base_v + _cross(self.base_w, self.base_com))
        p_lin = p_lin + v_com * self.base_mass
        var i_w = _rotate_inertia(bq, self.base_idiag)
        l_ang = l_ang + _mul(i_w, w_w) + _cross(com_w, v_com * self.base_mass)

        for i in range(nn):
            var li = self.chain.links[i]
            var pose = bm * local[i]
            var qt = pose.to_quat_translation()
            var rq = qt[0]
            var org = qt[1]
            var wl = m[0][i].v
            var vl = m[1][i].v
            var ww = rq.rotate(wl)
            var cw = org + rq.rotate(li.com)
            var vc = rq.rotate(vl + _cross(wl, li.com))
            p_lin = p_lin + vc * li.mass
            var iw = _rotate_inertia(rq, li.i_diag)
            l_ang = l_ang + _mul(iw, ww) + _cross(cw, vc * li.mass)
        return (p_lin, l_ang)


def _rotate_inertia(q: Quat, d: Vec3) -> List[Vec3]:
    """`R diag(d) R'` as three column vectors."""
    var c0 = q.rotate(Vec3(d[0], 0, 0))
    var c1 = q.rotate(Vec3(0, d[1], 0))
    var c2 = q.rotate(Vec3(0, 0, d[2]))
    var e0 = q.rotate(Vec3(1, 0, 0))
    var e1 = q.rotate(Vec3(0, 1, 0))
    var e2 = q.rotate(Vec3(0, 0, 1))
    var out = List[Vec3]()
    out.append(e0 * c0[0] + e1 * c1[0] + e2 * c2[0])
    out.append(e0 * c0[1] + e1 * c1[1] + e2 * c2[1])
    out.append(e0 * c0[2] + e1 * c1[2] + e2 * c2[2])
    return out^


def _mul(m: List[Vec3], v: Vec3) -> Vec3:
    return m[0] * v[0] + m[1] * v[1] + m[2] * v[2]
