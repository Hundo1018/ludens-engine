"""Cosserat rods with twist: positions plus one orientation per segment
(ROADMAP 17.57, the torsion degree of freedom `StrandSet` lacks; after
Kugelstadt & Schoemer 2016, "Position and orientation based Cosserat rods").

`StrandSet` is a chain of points: it bends and stretches but has nothing
that can twist. Here segment e between points e and e + 1 carries a unit
quaternion q_e whose third axis d3 = q_e e_z q_e* is the segment's
material tangent; its first two axes are the material frame the twist
turns. Per substep (XPBD-style projections, positions and orientations):

  * stretch-shear, per segment: gamma = (x_{e+1} - x_e) / l - d3(q_e);
    the points move along gamma and q_e turns its d3 toward the edge,
    weighted by the inverse masses w and the segment's inverse inertia wq;
  * bend-twist, per joint between q_e and q_{e+1}: the Darboux vector
    Omega = Im(q_e* q_{e+1}) is driven toward its rest value (the sign
    with the smaller difference, since q and -q are one rotation) as an
    XPBD constraint per component with a multiplier per joint: x / y with
    `bend_compliance`, z with `twist_compliance` (0 = rigid). XPBD, not a
    PBD stiffness fraction: with fractions the Gauss-Seidel sweeps settled
    away from the energy minimum (a twisted rod's end joints took 0.144
    rad and the inner ones 0.175 where 0.165 each is the minimum). The
    compliance is measured against the segments' inverse inertia: when
    compliance / h^2 is far below it (1e-4 here) the joints are in effect
    rigid, a fixed total twist cannot satisfy them all, and the joint
    solved last absorbs the error (1.9e-4 rad against 0.165); at the
    default 1 the twist spreads within 0.7 %. The joint sweep alternates
    direction per iteration for the same reason.

Velocities come from the position change; angular velocities from
2 Im(q_new q_old*) / h, integrated forward the same way. A point or a
segment with inverse mass / inertia 0 is held (clamped ends; move it with
`set_segment` to twist an end).

`twist_angle(e)` is the twist across joint e: 2 atan2(Omega_z, w) of the
relative rotation (radians). Clamping one end and turning the other by
phi spreads phi evenly over the joints (`test_cosserat_rod`).
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat


def _qadd(a: Quat, b: Quat) -> Quat:
    return Quat(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w)


def _qscale(a: Quat, s: Real) -> Quat:
    return Quat(a.x * s, a.y * s, a.z * s, a.w * s)


struct CosseratRod(Movable):
    var x: List[Vec3]
    var v: List[Vec3]
    var w: List[Real]  # inverse mass per point
    var q: List[Quat]  # per segment
    var omega: List[Vec3]  # angular velocity per segment (world)
    var wq: List[Real]  # inverse rotational inertia per segment (scalar)
    var rest_len: List[Real]
    var rest_darboux: List[Quat]  # per joint
    var lam: List[Vec3]  # XPBD multiplier per joint (reset each substep)
    var bend_compliance: Real
    var twist_compliance: Real
    var damping: Real  # velocity kept per substep
    var substeps: Int
    var iters: Int

    def __init__(out self, points: List[Vec3], mass: Real, bend_compliance: Real = 1, twist_compliance: Real = 1) raises:
        """A rod through `points` (straight segments), total `mass` spread
        over the points, rest shape = the given shape with untwisted
        frames (each frame the minimal rotation of the previous one)."""
        var n = len(points)
        if n < 2 or not (mass > 0) or not (bend_compliance >= 0) or not (twist_compliance >= 0):
            raise Error("CosseratRod: >= 2 points, mass > 0, compliances >= 0")
        self.x = points.copy()
        self.v = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.w = List[Real](length=n, fill=Real(n) / mass)
        self.q = List[Quat]()
        self.omega = List[Vec3]()
        self.wq = List[Real]()
        self.rest_len = List[Real]()
        self.rest_darboux = List[Quat]()
        self.lam = List[Vec3]()
        self.bend_compliance = bend_compliance
        self.twist_compliance = twist_compliance
        self.damping = 1
        self.substeps = 8
        self.iters = 4
        var prev = Quat.identity()
        var ez = Vec3(0, 0, 1, 0)
        for e in range(n - 1):
            var d = points[e + 1] - points[e]
            var l = length(d)
            if not (l > 0):
                raise Error("CosseratRod: repeated point")
            var t = d / l
            # minimal rotation of the previous frame's d3 onto t (the first
            # segment starts from e_z)
            var from_ = prev.rotate(ez)
            var c = dot(from_, t)
            var ax = Vec3(from_[1] * t[2] - from_[2] * t[1], from_[2] * t[0] - from_[0] * t[2], from_[0] * t[1] - from_[1] * t[0], 0)
            var r: Quat
            if c < Real(-0.999999):
                var perp = prev.rotate(Vec3(1, 0, 0, 0))
                r = Quat(perp[0], perp[1], perp[2], 0)
            else:
                r = Quat(ax[0], ax[1], ax[2], 1 + c).normalized()
            var qe = (r * prev).normalized()
            self.q.append(qe)
            prev = qe
            self.omega.append(Vec3(0, 0, 0, 0))
            self.rest_len.append(l)
            # rotational inertia of a thin segment, scaled to the point mass
            self.wq.append(Real(n) / mass / (l * l))
        for e in range(n - 2):
            self.rest_darboux.append(self.q[e].conjugate() * self.q[e + 1])
            self.lam.append(Vec3(0, 0, 0, 0))

    def points(self) -> Int:
        return len(self.x)

    def segments(self) -> Int:
        return len(self.q)

    def fix_point(mut self, i: Int):
        self.w[i] = 0
        self.v[i] = Vec3(0, 0, 0, 0)

    def fix_segment(mut self, e: Int):
        self.wq[e] = 0
        self.omega[e] = Vec3(0, 0, 0, 0)

    def set_segment(mut self, e: Int, q: Quat):
        """Place a held segment's orientation (turn a clamped end)."""
        self.q[e] = q.normalized()

    def darboux(self, j: Int) -> Quat:
        return self.q[j].conjugate() * self.q[j + 1]

    def twist_angle(self, j: Int) -> Real:
        """Twist across joint j (radians, about the material d3)."""
        var o = self.darboux(j)
        if o.w < 0:
            o = _qscale(o, -1)
        return 2 * atan2(o.z, o.w)

    def _stretch(mut self, e: Int):
        var a = e
        var b = e + 1
        var l = self.rest_len[e]
        var d3 = self.q[e].rotate(Vec3(0, 0, 1, 0))
        var g = (self.x[b] - self.x[a]) / l - d3
        var den = (self.w[a] + self.w[b]) / l + self.wq[e] * 4 * l + Real(1e-9)
        if den <= Real(1e-9):
            return
        g = g / den
        self.x[a] = self.x[a] + g * self.w[a]
        self.x[b] = self.x[b] - g * self.w[b]
        if self.wq[e] > 0:
            # q += wq l (gamma q e3*), e3* = (0, 0, -1, 0)
            var gq = Quat(g[0], g[1], g[2], 0)
            var dq = gq * self.q[e] * Quat(0, 0, -1, 0)
            self.q[e] = _qadd(self.q[e], _qscale(dq, self.wq[e] * l)).normalized()

    def _bend_twist(mut self, j: Int, h: Real):
        var qa = self.q[j]
        var qb = self.q[j + 1]
        var wa = self.wq[j]
        var wb = self.wq[j + 1]
        var den = wa + wb + Real(1e-9)
        if den <= Real(1e-9):
            return
        var o = qa.conjugate() * qb
        var r = self.rest_darboux[j]
        var om = Quat(o.x - r.x, o.y - r.y, o.z - r.z, o.w - r.w)
        var op = Quat(o.x + r.x, o.y + r.y, o.z + r.z, o.w + r.w)
        var dd = om if (om.x * om.x + om.y * om.y + om.z * om.z + om.w * om.w) <= (op.x * op.x + op.y * op.y + op.z * op.z + op.w * op.w) else op
        var ab = self.bend_compliance / (h * h)
        var at = self.twist_compliance / (h * h)
        var lj = self.lam[j]
        # delta = (C + alpha~ lambda) / (w + alpha~); lambda -= delta
        var dx_ = (dd.x + ab * lj[0]) / (den + ab)
        var dy_ = (dd.y + ab * lj[1]) / (den + ab)
        var dz_ = (dd.z + at * lj[2]) / (den + at)
        self.lam[j] = Vec3(lj[0] - dx_, lj[1] - dy_, lj[2] - dz_, 0)
        var c = Quat(dx_, dy_, dz_, 0)
        if wa > 0:
            self.q[j] = _qadd(qa, _qscale(qb * c, wa)).normalized()
        if wb > 0:
            self.q[j + 1] = _qadd(qb, _qscale(qa * c, -wb)).normalized()

    def step(mut self, dt: Real, gravity: Vec3):
        var h = dt / Real(self.substeps)
        var n = len(self.x)
        var ns = len(self.q)
        for _ in range(self.substeps):
            var px = self.x.copy()
            var pq = self.q.copy()
            for i in range(n):
                if self.w[i] > 0:
                    self.v[i] = self.v[i] + gravity * h
                    self.x[i] = self.x[i] + self.v[i] * h
            for e in range(ns):
                if self.wq[e] > 0:
                    var wv = self.omega[e]
                    var dq = Quat(wv[0], wv[1], wv[2], 0) * self.q[e]
                    self.q[e] = _qadd(self.q[e], _qscale(dq, Real(0.5) * h)).normalized()
            for j in range(ns - 1):
                self.lam[j] = Vec3(0, 0, 0, 0)
            for it in range(self.iters):
                for e in range(ns):
                    self._stretch(e)
                # alternate the sweep: one direction always let the last
                # joint before a clamped segment absorb its whole error
                # (it took 1.9e-4 rad of a twist the others shared)
                for jj in range(ns - 1):
                    var j = jj if it % 2 == 0 else ns - 2 - jj
                    self._bend_twist(j, h)
            for i in range(n):
                if self.w[i] > 0:
                    self.v[i] = (self.x[i] - px[i]) * (self.damping / h)
            for e in range(ns):
                if self.wq[e] > 0:
                    var rel = self.q[e] * pq[e].conjugate()
                    if rel.w < 0:
                        rel = _qscale(rel, -1)
                    self.omega[e] = Vec3(rel.x, rel.y, rel.z, 0) * (2 * self.damping / h)
