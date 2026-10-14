"""Joint limits, motors and springs; the slider, cone-twist and rope kinds
(ROADMAP 17.47).

`Joint6` (ball / distance / hinge / weld) holds equality constraints only.
Everything a joint can do ON TOP of its equality part lives in a `JointExt`
kept in a list parallel to the scene's joints, so the `Joint6` layout and
its snapshot fields are unchanged:

- a joint COORDINATE `q` per kind: the hinge angle about its axis, the
  slider's travel along its axis, the rope's length, the cone-twist joint's
  twist angle;
- a LIMIT interval [lo, hi] on q (one-sided inequalities: the accumulated
  impulse of the lower side is >= 0, of the upper side <= 0), and for the
  cone-twist joint a swing CONE (the angle between the two twist axes);
- a MOTOR along q: velocity (drive dq/dt to `target`) or position (a soft
  spring toward `target` with its own hertz / zeta), its accumulated impulse
  capped at `max_force * h` per substep;
- a SPRING toward `rest` (soft-constraint hertz / zeta, uncapped);
- `collide`: False makes the two bodies skip contact with each other.

Limits are solved like contacts (Box2D v3 soft step): a side that is not
yet reached (C > 0) is speculative -- it may close at most C / h this
substep and adds no softness -- and a violated side (C < 0) pushes back
with the soft bias; in the relax pass only the speculative part remains.
A joint whose ext is all defaults costs a branch and changes nothing.

Row directions are recomputed from the current poses every solve, and the
warm start applies each accumulator along the current row direction.
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec3, dot, cross, tangent_basis, length
from geometry.quat import Quat
from .rigid6 import Body6
from .body_set import BodySet
from .joints6 import (
    Joint6,
    JOINT_HINGE,
    JOINT_SLIDER,
    JOINT_CONE_TWIST,
    JOINT_ROPE,
    JOINT_D6,
    JOINT_BROKEN,
    joint_island,
    joint_axis,
    drive_error,
)

comptime MOTOR_NONE = 0
comptime MOTOR_VELOCITY = 1
comptime MOTOR_POSITION = 2


@fieldwise_init
struct JointExt(Copyable, ImplicitlyCopyable, Movable):
    var lim_on: Bool
    var lo: Real
    var hi: Real
    var cone: Real  # cone-twist swing limit (rad); < 0 = none
    var motor: Int
    var target: Real
    var max_force: Real
    var m_hertz: Real
    var m_zeta: Real
    var s_hertz: Real  # spring; <= 0 = none
    var s_zeta: Real
    var s_rest: Real
    var ref_a: Vec3  # zero-angle reference, body frame of a (hinge, cone-twist)
    var ref_b: Vec3
    var ref_rel: Quat  # slider: rotation(a)^-1 rotation(b) to hold
    var collide: Bool
    var acc_lo: Real
    var acc_hi: Real
    var acc_motor: Real
    var acc_spring: Real
    var acc_cone: Real
    # ROADMAP 17.47 D6: per axis (0..2 linear x/y/z, 3..5 angular x/y/z of
    # a's frame) a mode in 2 bits (D6_FREE / D6_LOCKED / D6_LIMITED), the
    # limited range, and one accumulated impulse per row. 0 = not a D6.
    var d6_mode: Int
    var d6_lo_lin: Vec3
    var d6_hi_lin: Vec3
    var d6_lo_ang: Vec3
    var d6_hi_ang: Vec3
    var d6_acc_lin: Vec3
    var d6_acc_ang: Vec3

    @staticmethod
    def default() -> Self:
        var z = Vec3(0, 0, 0, 0)
        return Self(
            False, 0, 0, -1, MOTOR_NONE, 0, 0, 0, 0, 0, 0, 0,
            Vec3(1, 0, 0, 0), Vec3(1, 0, 0, 0), Quat.identity(), True, 0, 0, 0, 0, 0,
            0, z, z, z, z, z, z,
        )

    def active(self) -> Bool:
        return self.lim_on or self.cone >= 0 or self.motor != MOTOR_NONE or self.s_hertz > 0 or self.d6_mode != 0

    def d6_axis_mode(self, k: Int) -> Int:
        return (self.d6_mode >> (2 * k)) & 3


comptime D6_FREE = 0
comptime D6_LOCKED = 1
comptime D6_LIMITED = 2
comptime D6_ALL_LOCKED = 0b010101010101


@always_inline
def _dir[B: Body6](bset: BodySet[B], i: Int, v: Vec3) -> Vec3:
    """World direction of body-frame vector `v`."""
    return bset.bodies[i].act(v) - bset.bodies[i].act(Vec3(0, 0, 0, 0))


def _unit(v: Vec3) -> Vec3:
    var l = length(v)
    return v / l if l > 1e-12 else Vec3(0, 0, 0, 0)


def _signed_angle(u: Vec3, v: Vec3, axis: Vec3) -> Real:
    """Angle from u to v about unit `axis` (both projected on its plane)."""
    var pu = u - axis * dot(u, axis)
    var pv = v - axis * dot(v, axis)
    return atan2(dot(cross(pu, pv), axis), dot(pu, pv))


# ------------------------------------------------------------ rows


@fieldwise_init
struct _Row(Copyable, ImplicitlyCopyable, Movable):
    """A scalar constraint direction: angular (impulse = torque about `n`) or
    linear (impulse along `n` at the anchors)."""

    var angular: Bool
    var n: Vec3
    var pwa: Vec3
    var pwb: Vec3


def _row_mass[B: Body6](bset: BodySet[B], a: Int, b: Int, r: _Row) -> Real:
    var k = Real(0)
    if r.angular:
        if bset.is_dynamic(a):
            k += bset.bodies[a].angular_only_factor(r.n)
        if bset.is_dynamic(b):
            k += bset.bodies[b].angular_only_factor(r.n)
    else:
        if bset.is_dynamic(a):
            k += bset.bodies[a].inv_mass() + bset.bodies[a].angular_factor(r.pwa - bset.bodies[a].position(), r.n)
        if bset.is_dynamic(b):
            k += bset.bodies[b].inv_mass() + bset.bodies[b].angular_factor(r.pwb - bset.bodies[b].position(), r.n)
    return k


def _row_vel[B: Body6](bset: BodySet[B], a: Int, b: Int, r: _Row) -> Real:
    """d q / dt along the row (b relative to a)."""
    if r.angular:
        var wa = Vec3(0, 0, 0, 0)
        var wb = Vec3(0, 0, 0, 0)
        if bset.moves(a):
            wa = bset.bodies[a].omega_world()
        if bset.moves(b):
            wb = bset.bodies[b].omega_world()
        return dot(wb - wa, r.n)
    var va = Vec3(0, 0, 0, 0)
    var vb = Vec3(0, 0, 0, 0)
    if bset.moves(a):
        va = bset.bodies[a].velocity_at(r.pwa)
    if bset.moves(b):
        vb = bset.bodies[b].velocity_at(r.pwb)
    return dot(vb - va, r.n)


def _row_apply[B: Body6](mut bset: BodySet[B], a: Int, b: Int, r: _Row, dl: Real):
    if dl == 0:
        return
    var j = r.n * dl
    if r.angular:
        if bset.is_dynamic(a):
            bset.bodies[a].apply_angular_impulse(-j)
        if bset.is_dynamic(b):
            bset.bodies[b].apply_angular_impulse(j)
    else:
        if bset.is_dynamic(a):
            bset.bodies[a].apply_impulse(-j, r.pwa)
        if bset.is_dynamic(b):
            bset.bodies[b].apply_impulse(j, r.pwb)


def _coord[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[Real, _Row]:
    """The joint coordinate q and the row along which it moves."""
    var pwa = bset.bodies[jt.a].act(jt.la)
    var pwb = bset.bodies[jt.b].act(jt.lb)
    if jt.kind == JOINT_SLIDER:
        var ax = _unit(_dir(bset, jt.a, jt.axis_a))
        return (dot(pwb - pwa, ax), _Row(False, ax, pwa, pwb))
    if jt.kind == JOINT_ROPE:
        var g = pwb - pwa
        var l = length(g)
        var u = g / l if l > 1e-9 else Vec3(0, 1, 0, 0)
        return (l, _Row(False, u, pwa, pwb))
    if jt.kind == JOINT_CONE_TWIST:
        var axb = _unit(_dir(bset, jt.b, jt.axis_b))
        var q = _signed_angle(_dir(bset, jt.a, ex.ref_a), _dir(bset, jt.b, ex.ref_b), axb)
        return (q, _Row(True, axb, pwa, pwb))
    # hinge (and any other kind with an axis): angle about a's axis
    var axa = _unit(_dir(bset, jt.a, jt.axis_a))
    var q = _signed_angle(_dir(bset, jt.a, ex.ref_a), _dir(bset, jt.b, ex.ref_b), axa)
    return (q, _Row(True, axa, pwa, pwb))


def joint_coordinate[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Real:
    return _coord(bset, jt, ex)[0]


def _swing[B: Body6](bset: BodySet[B], jt: Joint6) -> Tuple[Real, _Row]:
    """Cone-twist swing angle (between the two twist axes) and the row that
    opens it."""
    var axa = _unit(_dir(bset, jt.a, jt.axis_a))
    var axb = _unit(_dir(bset, jt.b, jt.axis_b))
    var c = cross(axa, axb)
    var s = length(c)
    var ang = atan2(s, dot(axa, axb))
    var n = c / s if s > 1e-9 else tangent_basis(axa)[0]
    var p = bset.bodies[jt.b].act(jt.lb)
    return (ang, _Row(True, n, p, p))


def _limit_side[B: Body6](
    mut bset: BodySet[B], a: Int, b: Int, r: _Row, k: Real, c: Real, sign: Real,
    mut acc: Real, h: Real, bias_rate: Real, ms: Real, isc: Real, use_bias: Bool,
):
    """One limit side: C = sign * (q - bound) >= 0. `acc` is the impulse
    magnitude pushing q back inside (>= 0); it acts along sign * n."""
    var vr = sign * _row_vel(bset, a, b, r)
    var bias = Real(0)
    var m = Real(1)
    var i = Real(0)
    if c > 0:
        bias = c / h  # speculative: may close by at most c this substep
    elif use_bias:
        bias = bias_rate * c
        m = ms
        i = isc
    var dl = -m * (vr + bias) / k - i * acc
    var na = max(acc + dl, Real(0))
    dl = na - acc
    acc = na
    _row_apply(bset, a, b, r, sign * dl)


def _soft_coeffs(hertz: Real, zeta: Real, h: Real) -> Tuple[Real, Real, Real]:
    var omega = Real(6.283185307179586) * hertz
    var cc = h * omega * (2 * zeta + h * omega)
    return (omega / (2 * zeta + h * omega), cc / (1 + cc), 1 / (1 + cc))


def ext_sweep[B: Body6](
    mut bset: BodySet[B],
    mut joints: List[Joint6],
    mut ext: List[JointExt],
    h: Real,
    bias_rate: Real,
    ms: Real,
    isc: Real,
    use_bias: Bool,
    iters: Int,
    island_filter: Int,
):
    """Limits, cone, motors and springs of every joint with an active ext,
    and the slider's equality rows (`joint_sweep` skips sliders and ropes);
    same island filter as `joint_sweep`."""
    for _ in range(iters):
        for c in range(len(ext)):
            var jt = joints[c]
            if not ext[c].active() and jt.kind != JOINT_SLIDER:
                continue
            if jt.kind == JOINT_BROKEN:
                continue
            if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
                continue
            if island_filter != -2 and joint_island(bset, jt) != island_filter:
                continue
            var ex = ext[c]
            if jt.kind == JOINT_D6:
                d6_solve(bset, jt, ex, h, bias_rate, ms, isc, use_bias)
                ext[c] = ex
                continue
            if jt.kind == JOINT_SLIDER:
                slider_lock(bset, jt, ex, h, bias_rate, ms, isc, use_bias)
                joints[c] = jt
                if not ex.active():
                    continue
            var qr = _coord(bset, jt, ex)
            var q = qr[0]
            var r = qr[1]
            var k = _row_mass(bset, jt.a, jt.b, r)
            if k > 0:
                if ex.motor == MOTOR_VELOCITY:
                    var cap = ex.max_force * h
                    var dl = -(_row_vel(bset, jt.a, jt.b, r) - ex.target) / k
                    var na = min(max(ex.acc_motor + dl, -cap), cap)
                    _row_apply(bset, jt.a, jt.b, r, na - ex.acc_motor)
                    ex.acc_motor = na
                elif ex.motor == MOTOR_POSITION:
                    var sc = _soft_coeffs(ex.m_hertz, ex.m_zeta, h)
                    var cap = ex.max_force * h
                    var dl = -sc[1] * (_row_vel(bset, jt.a, jt.b, r) + sc[0] * (q - ex.target)) / k - sc[2] * ex.acc_motor
                    var na = min(max(ex.acc_motor + dl, -cap), cap)
                    _row_apply(bset, jt.a, jt.b, r, na - ex.acc_motor)
                    ex.acc_motor = na
                if ex.s_hertz > 0:
                    var sc = _soft_coeffs(ex.s_hertz, ex.s_zeta, h)
                    var dl = -sc[1] * (_row_vel(bset, jt.a, jt.b, r) + sc[0] * (q - ex.s_rest)) / k - sc[2] * ex.acc_spring
                    ex.acc_spring += dl
                    _row_apply(bset, jt.a, jt.b, r, dl)
                if ex.lim_on:
                    _limit_side(bset, jt.a, jt.b, r, k, q - ex.lo, 1, ex.acc_lo, h, bias_rate, ms, isc, use_bias)
                    _limit_side(bset, jt.a, jt.b, r, k, ex.hi - q, -1, ex.acc_hi, h, bias_rate, ms, isc, use_bias)
            if jt.kind == JOINT_CONE_TWIST and ex.cone >= 0:
                var sw = _swing(bset, jt)
                var ks = _row_mass(bset, jt.a, jt.b, sw[1])
                if ks > 0:
                    _limit_side(bset, jt.a, jt.b, sw[1], ks, ex.cone - sw[0], -1, ex.acc_cone, h, bias_rate, ms, isc, use_bias)
            ext[c] = ex


def _d6_frame[B: Body6](bset: BodySet[B], jt: Joint6) -> Tuple[Vec3, Vec3, Vec3]:
    return (_dir(bset, jt.a, Vec3(1, 0, 0, 0)), _dir(bset, jt.a, Vec3(0, 1, 0, 0)), _dir(bset, jt.a, Vec3(0, 0, 1, 0)))


def d6_coords[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[Vec3, Vec3]:
    """(linear, angular) D6 coordinates in a's frame: the anchor gap, and the
    rotation vector of b's rotation relative to the reference (exact per
    axis when one angular axis moves; when several do, the components of
    one rotation vector, not three sequential angles)."""
    var pwa = bset.bodies[jt.a].act(jt.la)
    var pwb = bset.bodies[jt.b].act(jt.lb)
    var qa = bset.bodies[jt.a].rotation()
    var gap = qa.conjugate().rotate(pwb - pwa)
    var err = qa.conjugate() * bset.bodies[jt.b].rotation() * ex.ref_rel.conjugate()
    if err.w < 0:
        err = Quat(-err.x, -err.y, -err.z, -err.w)
    var sv = sqrt(err.x * err.x + err.y * err.y + err.z * err.z)
    var rv = Vec3(2 * err.x, 2 * err.y, 2 * err.z, 0)
    if sv > 1e-9:
        rv = Vec3(err.x, err.y, err.z, 0) * (2 * atan2(sv, err.w) / sv)
    # err * ref_rel = qa^-1 qb: err is left of the reference, i.e. a
    # rotation in a's frame, so rv's components are about a's axes
    return (gap, rv)


def _d6_row[B: Body6](
    mut bset: BodySet[B], jt: Joint6, r: _Row, mode: Int, c: Real, lo: Real, hi: Real,
    mut acc: Real, h: Real, bias_rate: Real, ms: Real, isc: Real, use_bias: Bool,
):
    """One D6 axis: locked = soft equality c -> 0; limited = one-sided at the
    nearer bound (acc >= 0 pushes up from `lo`, <= 0 down from `hi`)."""
    var k = _row_mass(bset, jt.a, jt.b, r)
    if k <= 0:
        return
    var vr = _row_vel(bset, jt.a, jt.b, r)
    if mode == D6_LOCKED:
        var bias = bias_rate * c if use_bias else Real(0)
        var m = ms if use_bias else Real(1)
        var i = isc if use_bias else Real(0)
        var dl = -m * (vr + bias) / k - i * acc
        acc += dl
        _row_apply(bset, jt.a, jt.b, r, dl)
        return
    var lower = (c - lo) <= (hi - c)
    var sign = Real(1) if lower else Real(-1)
    var cc = (c - lo) if lower else (hi - c)
    var a1 = acc * sign  # this side's impulse magnitude (>= 0)
    if a1 < 0:
        a1 = 0
    _limit_side(bset, jt.a, jt.b, r, k, cc, sign, a1, h, bias_rate, ms, isc, use_bias)
    acc = a1 * sign


def d6_solve[B: Body6](
    mut bset: BodySet[B], jt: Joint6, mut ex: JointExt, h: Real, bias_rate: Real,
    ms: Real, isc: Real, use_bias: Bool,
):
    var fr = _d6_frame(bset, jt)
    var pwa = bset.bodies[jt.a].act(jt.la)
    var pwb = bset.bodies[jt.b].act(jt.lb)
    var co = d6_coords(bset, jt, ex)
    for k in range(3):
        var mode = ex.d6_axis_mode(k)
        if mode == D6_FREE:
            continue
        var e = fr[0] if k == 0 else (fr[1] if k == 1 else fr[2])
        var acc = ex.d6_acc_lin[k]
        _d6_row(bset, jt, _Row(False, e, pwa, pwb), mode, co[0][k], ex.d6_lo_lin[k], ex.d6_hi_lin[k], acc, h, bias_rate, ms, isc, use_bias)
        ex.d6_acc_lin[k] = acc
    for k in range(3):
        var mode = ex.d6_axis_mode(3 + k)
        if mode == D6_FREE:
            continue
        var e = fr[0] if k == 0 else (fr[1] if k == 1 else fr[2])
        var acc = ex.d6_acc_ang[k]
        _d6_row(bset, jt, _Row(True, e, pwb, pwb), mode, co[1][k], ex.d6_lo_ang[k], ex.d6_hi_ang[k], acc, h, bias_rate, ms, isc, use_bias)
        ex.d6_acc_ang[k] = acc


def _d6_impulse[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[Vec3, Vec3]:
    var fr = _d6_frame(bset, jt)
    var lin = fr[0] * ex.d6_acc_lin[0] + fr[1] * ex.d6_acc_lin[1] + fr[2] * ex.d6_acc_lin[2]
    var ang = fr[0] * ex.d6_acc_ang[0] + fr[1] * ex.d6_acc_ang[1] + fr[2] * ex.d6_acc_ang[2]
    return (lin, ang)


def ext_impulse[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[Vec3, Vec3]:
    """(linear, angular) impulse the ext rows (limits, motor, spring, cone)
    accumulated this substep on body b -- what `Joint6.acc` / `acc_ang`
    hold for the joint's own rows (ROADMAP 17.47 / 17.29: break checks and
    `joint_reaction` count both)."""
    var lin = Vec3(0, 0, 0, 0)
    var ang = Vec3(0, 0, 0, 0)
    if not ex.active():
        return (lin, ang)
    if jt.kind == JOINT_D6:
        return _d6_impulse(bset, jt, ex)
    var net = ex.acc_lo - ex.acc_hi + ex.acc_motor + ex.acc_spring
    if net != 0:
        var r = _coord(bset, jt, ex)[1]
        if r.angular:
            ang = r.n * net
        else:
            lin = r.n * net
    if jt.kind == JOINT_CONE_TWIST and ex.cone >= 0 and ex.acc_cone != 0:
        ang = ang - _swing(bset, jt)[1].n * ex.acc_cone
    return (lin, ang)


def sample_ext_loads[B: Body6](
    bset: BodySet[B], joints: List[Joint6], ext: List[JointExt], h: Real,
    mut peak_force: List[Real], mut peak_torque: List[Real],
):
    """`joints6.sample_loads` with the ext rows' impulses added to the
    joint's own: a hinge held at its limit, a motor at its torque cap or a
    slider stopped at its travel end loads the joint through these rows
    only, which the break check used to miss."""
    for c in range(min(len(joints), len(ext))):
        ref jt = joints[c]
        if jt.kind == JOINT_BROKEN or not ext[c].active():
            continue
        var e = ext_impulse(bset, jt, ext[c])
        var f = jt.acc + e[0]
        var t = jt.acc_ang + e[1]
        peak_force[c] = max(peak_force[c], sqrt(dot(f, f)) / h)
        peak_torque[c] = max(peak_torque[c], sqrt(dot(t, t)) / h)


def warm_start_ext[B: Body6](
    mut bset: BodySet[B], joints: List[Joint6], ext: List[JointExt], island_filter: Int
):
    for c in range(len(ext)):
        if not ext[c].active():
            continue
        var jt = joints[c]
        if jt.kind == JOINT_BROKEN:
            continue
        if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
            continue
        if island_filter != -2 and joint_island(bset, jt) != island_filter:
            continue
        ref ex = ext[c]
        if jt.kind == JOINT_D6:
            var fr = _d6_frame(bset, jt)
            var pwa = bset.bodies[jt.a].act(jt.la)
            var pwb = bset.bodies[jt.b].act(jt.lb)
            for k in range(3):
                var e = fr[0] if k == 0 else (fr[1] if k == 1 else fr[2])
                _row_apply(bset, jt.a, jt.b, _Row(False, e, pwa, pwb), ex.d6_acc_lin[k])
                _row_apply(bset, jt.a, jt.b, _Row(True, e, pwb, pwb), ex.d6_acc_ang[k])
            continue
        var r = _coord(bset, jt, ex)[1]
        _row_apply(bset, jt.a, jt.b, r, ex.acc_lo - ex.acc_hi + ex.acc_motor + ex.acc_spring)
        if jt.kind == JOINT_CONE_TWIST and ex.cone >= 0:
            _row_apply(bset, jt.a, jt.b, _swing(bset, jt)[1], -ex.acc_cone)


def slider_lock[B: Body6](
    mut bset: BodySet[B], mut jt: Joint6, ex: JointExt, h: Real, bias_rate: Real,
    ms: Real, isc: Real, use_bias: Bool,
):
    """The slider's equality part: the anchor gap has no component across the
    axis (two linear rows) and the relative rotation stays `ex.ref_rel`
    (three angular rows, as the weld)."""
    var pwa = bset.bodies[jt.a].act(jt.la)
    var pwb = bset.bodies[jt.b].act(jt.lb)
    var ax = _unit(_dir(bset, jt.a, jt.axis_a))
    var gap = pwb - pwa
    var tb = tangent_basis(ax)
    for ti in range(2):
        var t = tb[0] if ti == 0 else tb[1]
        var acc_t = dot(jt.acc, t)
        var dl = joint_axis(bset, jt.a, jt.b, pwa, pwb, t, dot(gap, t), h, bias_rate, ms, isc, use_bias, acc_t)
        jt.acc = jt.acc + t * dl
    var er = drive_error(bset.bodies[jt.a].rotation(), bset.bodies[jt.b].rotation(), ex.ref_rel) * Real(-1)
    for kx in range(3):
        var e = Vec3(0, 0, 0, 0)
        e[kx] = 1
        var r = _Row(True, e, pwa, pwb)
        var k = _row_mass(bset, jt.a, jt.b, r)
        if k <= 0:
            continue
        var bias = bias_rate * er[kx] if use_bias else Real(0)
        var dl = -ms * (_row_vel(bset, jt.a, jt.b, r) + bias) / k - isc * jt.acc_ang[kx]
        jt.acc_ang[kx] += dl
        _row_apply(bset, jt.a, jt.b, r, dl)
