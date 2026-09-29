"""Two-body joints for the soft substep solver (audit F11, cluster 4):
`Joint6` (ball / distance / hinge equality constraints), the scalar axis
solve, the sweep, and warm starting -- free functions over a `BodySet` view
and a joint slice, composed by `ContactScene6` (`physics/solver6.mojo`).
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec3, dot, cross, tangent_basis
from geometry.quat import Quat
from .rigid6 import Body6
from .body_set import BodySet


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
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )

    @staticmethod
    def distance(a: Int, b: Int, la: Vec3, lb: Vec3, rest: Real) -> Self:
        return Self(
            JOINT_DISTANCE, a, b, la, lb, rest,
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )

    @staticmethod
    def hinge(a: Int, b: Int, la: Vec3, lb: Vec3, axis: Vec3) -> Self:
        return Self(
            JOINT_HINGE, a, b, la, lb, 0,
            axis, axis, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )



def joint_island[B: Body6](bset: BodySet[B], jt: Joint6) -> Int:
    return bset.island[jt.a] if bset.is_dynamic(jt.a) else bset.island[jt.b]


def joint_axis[B: Body6](
    mut bset: BodySet[B],
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
    var va = Vec3(0, 0, 0, 0)
    var ka = Real(0)
    if bset.moves(ia):
        va = bset.bodies[ia].velocity_at(pwa)
    if bset.is_dynamic(ia):
        ka = bset.bodies[ia].inv_mass() + bset.bodies[ia].angular_factor(
            pwa - bset.bodies[ia].position(), e
        )
    var vb = Vec3(0, 0, 0, 0)
    var kb = Real(0)
    if bset.moves(ib):
        vb = bset.bodies[ib].velocity_at(pwb)
    if bset.is_dynamic(ib):
        kb = bset.bodies[ib].inv_mass() + bset.bodies[ib].angular_factor(
            pwb - bset.bodies[ib].position(), e
        )
    var denom = ka + kb
    if denom <= 0:
        return 0
    var vr = dot(vb - va, e)
    var bias = bias_rate * c if use_bias else Real(0)
    var dl = -ms * (vr + bias) / denom - isc * acc_e
    var j = e * dl
    if bset.is_dynamic(ia):
        bset.bodies[ia].apply_impulse(-j, pwa)
    if bset.is_dynamic(ib):
        bset.bodies[ib].apply_impulse(j, pwb)
    return dl


def joint_sweep[B: Body6](
    mut bset: BodySet[B],
    mut joints: List[Joint6],
    h: Real,
    bias_rate: Real,
    ms: Real,
    isc: Real,
    use_bias: Bool,
    iters: Int,
    island_filter: Int,
):
    for _ in range(iters):
        for c in range(len(joints)):
            var jt = joints[c]
            if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
                continue
            if island_filter != -2 and joint_island(bset, jt) != island_filter:
                continue
            var pwa = bset.bodies[jt.a].act(jt.la)
            var pwb = bset.bodies[jt.b].act(jt.lb)
            var gap = pwb - pwa
            if jt.kind == JOINT_DISTANCE:
                var l = sqrt(max(dot(gap, gap), Real(1e-12)))
                var u = gap / l
                var acc_s = dot(jt.acc, u)
                var dl = joint_axis(bset,
                    jt.a, jt.b, pwa, pwb, u, l - jt.rest,
                    h, bias_rate, ms, isc, use_bias, acc_s,
                )
                jt.acc = u * (acc_s + dl)
            else:
                # ball part (shared by hinge): drive the anchor gap to 0.
                for ax in range(3):
                    var e = Vec3(0, 0, 0, 0)
                    e[ax] = 1
                    var dl = joint_axis(bset,
                        jt.a, jt.b, pwa, pwb, e, gap[ax],
                        h, bias_rate, ms, isc, use_bias, jt.acc[ax],
                    )
                    jt.acc[ax] += dl
                if jt.kind == JOINT_HINGE:
                    var oa = bset.bodies[jt.a].act(jt.axis_a) - bset.bodies[
                        jt.a
                    ].act(Vec3(0, 0, 0, 0))
                    var ob = bset.bodies[jt.b].act(jt.axis_b) - bset.bodies[
                        jt.b
                    ].act(Vec3(0, 0, 0, 0))
                    var er = cross(oa, ob)  # small-angle axis error
                    var wa = Vec3(0, 0, 0, 0)
                    var wb2 = Vec3(0, 0, 0, 0)
                    if bset.moves(jt.a):
                        wa = bset.bodies[jt.a].omega_world()
                    if bset.moves(jt.b):
                        wb2 = bset.bodies[jt.b].omega_world()
                    var tb = tangent_basis(oa)
                    for ti in range(2):
                        var t = tb[0] if ti == 0 else tb[1]
                        var kaa = Real(0)
                        var kbb = Real(0)
                        if bset.is_dynamic(jt.a):
                            kaa = bset.bodies[jt.a].angular_only_factor(t)
                        if bset.is_dynamic(jt.b):
                            kbb = bset.bodies[jt.b].angular_only_factor(t)
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
                        if bset.is_dynamic(jt.a):
                            bset.bodies[jt.a].apply_angular_impulse(-limp)
                        if bset.is_dynamic(jt.b):
                            bset.bodies[jt.b].apply_angular_impulse(limp)
                        wa = Vec3(0, 0, 0, 0)
                        wb2 = Vec3(0, 0, 0, 0)
                        if bset.moves(jt.a):
                            wa = bset.bodies[jt.a].omega_world()
                        if bset.moves(jt.b):
                            wb2 = bset.bodies[jt.b].omega_world()
            joints[c] = jt


def warm_start_joints[B: Body6](
    mut bset: BodySet[B], joints: List[Joint6], island_filter: Int
):
    for c in range(len(joints)):
        var jt = joints[c]
        if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
            continue
        if island_filter != -2 and joint_island(bset, jt) != island_filter:
            continue
        var pwa = bset.bodies[jt.a].act(jt.la)
        var pwb = bset.bodies[jt.b].act(jt.lb)
        if bset.is_dynamic(jt.a):
            bset.bodies[jt.a].apply_impulse(-jt.acc, pwa)
            if jt.kind == JOINT_HINGE:
                bset.bodies[jt.a].apply_angular_impulse(-jt.acc_ang)
        if bset.is_dynamic(jt.b):
            bset.bodies[jt.b].apply_impulse(jt.acc, pwb)
            if jt.kind == JOINT_HINGE:
                bset.bodies[jt.b].apply_angular_impulse(jt.acc_ang)


# ------------------------------------------------------------ angular drives


@fieldwise_init
struct AngularDrive(Copyable, ImplicitlyCopyable, Movable):
    """A soft angular motor pulling body `b`'s orientation toward
    `rotation(a) * target` (ROADMAP 17.2: an animation pose as the drive
    target of a ragdoll joint). Its stiffness is its own `hertz` / `zeta`
    (Box2D v3 soft-constraint coefficients, like the contacts' but per
    drive), and the accumulated impulse is capped at `max_torque * h` per
    substep, so a drive can be as weak as a tired arm or turned off with a
    zero cap -- in which case it applies exactly nothing."""

    var a: Int
    var b: Int
    var target: Quat  # desired rotation of b relative to a
    var hertz: Real
    var zeta: Real
    var max_torque: Real
    var acc: Vec3  # accumulated angular impulse (world axes)

    @staticmethod
    def make(a: Int, b: Int, target: Quat, hertz: Real, zeta: Real, max_torque: Real) -> Self:
        return Self(a, b, target, hertz, zeta, max_torque, Vec3(0, 0, 0, 0))


def drive_error(qa: Quat, qb: Quat, target: Quat) -> Vec3:
    """Rotation vector (world frame) that would take b's current orientation
    to `qa * target` -- axis times angle, shortest way round."""
    var want = qa * target
    var qe = want * qb.conjugate()
    if qe.w < 0:
        qe = Quat(-qe.x, -qe.y, -qe.z, -qe.w)
    var s = sqrt(qe.x * qe.x + qe.y * qe.y + qe.z * qe.z)
    if s < 1e-9:
        return Vec3(2 * qe.x, 2 * qe.y, 2 * qe.z, 0)
    var ang = 2 * atan2(s, qe.w)
    return Vec3(qe.x, qe.y, qe.z, 0) * (ang / s)


def warm_start_drives[B: Body6](mut bset: BodySet[B], drives: List[AngularDrive]):
    for c in range(len(drives)):
        ref d = drives[c]
        if bset.impulse_inert(d.a) and bset.impulse_inert(d.b):
            continue
        if bset.is_dynamic(d.a):
            bset.bodies[d.a].apply_angular_impulse(-d.acc)
        if bset.is_dynamic(d.b):
            bset.bodies[d.b].apply_angular_impulse(d.acc)


def drive_sweep[B: Body6](
    mut bset: BodySet[B], mut drives: List[AngularDrive], h: Real, iters: Int
):
    """Soft angular solve of every drive, along the three world axes."""
    for _ in range(iters):
        for c in range(len(drives)):
            var d = drives[c]
            if bset.impulse_inert(d.a) and bset.impulse_inert(d.b):
                continue
            var e = drive_error(bset.bodies[d.a].rotation(), bset.bodies[d.b].rotation(), d.target)
            var omega = Real(6.283185307179586) * d.hertz
            var cc = h * omega * (2 * d.zeta + h * omega)
            var bias_rate = omega / (2 * d.zeta + h * omega)
            var ms = cc / (1 + cc)
            var isc = 1 / (1 + cc)
            var cap = d.max_torque * h
            for k in range(3):
                var ax = Vec3(0, 0, 0, 0)
                ax[k] = 1
                var kk = Real(0)
                if bset.is_dynamic(d.a):
                    kk += bset.bodies[d.a].angular_only_factor(ax)
                if bset.is_dynamic(d.b):
                    kk += bset.bodies[d.b].angular_only_factor(ax)
                if kk <= 0:
                    continue
                var wa = Vec3(0, 0, 0, 0)
                var wb = Vec3(0, 0, 0, 0)
                if bset.moves(d.a):
                    wa = bset.bodies[d.a].omega_world()
                if bset.moves(d.b):
                    wb = bset.bodies[d.b].omega_world()
                var wrel = dot(wb - wa, ax)
                var dl = -ms * (wrel - bias_rate * e[k]) / kk - isc * d.acc[k]
                var na = min(max(d.acc[k] + dl, -cap), cap)
                dl = na - d.acc[k]
                d.acc[k] = na
                if dl != 0:
                    var l = ax * dl
                    if bset.is_dynamic(d.a):
                        bset.bodies[d.a].apply_angular_impulse(-l)
                    if bset.is_dynamic(d.b):
                        bset.bodies[d.b].apply_angular_impulse(l)
            drives[c] = d

