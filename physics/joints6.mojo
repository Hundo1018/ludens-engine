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
comptime JOINT_BROKEN = 3  # ROADMAP 17.29: overloaded and released; solved by nothing
comptime JOINT_WELD = 4  # ROADMAP 17.5: ball + full 3-axis angular lock (rigid bond)
# ROADMAP 17.47 (solved in `physics.joint_ext`, which `joint_sweep` defers to):
comptime JOINT_SLIDER = 5  # prismatic: free along axis_a, all else locked
comptime JOINT_CONE_TWIST = 6  # ball + swing cone and twist range (axis_a / axis_b)
comptime JOINT_ROPE = 7  # anchor distance within the ext's [lo, hi] only
# ROADMAP 17.47, second slice:
comptime JOINT_UNIVERSAL = 8  # ball + axis_a (in a) stays perpendicular to axis_b (in b)
comptime JOINT_GEAR = 9  # ratio * (w_a . axis_a) + (w_b . axis_b) = 0, no anchors
comptime JOINT_PULLEY = 10  # |p_a - g_a| + ratio |p_b - g_b| <= rest, pull only
comptime JOINT_D6 = 11  # six axes, each free / locked / limited (solved in joint_ext)


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
    var ratio: Real  # gear / pulley ratio (17.47); 1 for every other kind

    @staticmethod
    def ball(a: Int, b: Int, la: Vec3, lb: Vec3) -> Self:
        return Self(
            JOINT_BALL, a, b, la, lb, 0,
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def distance(a: Int, b: Int, la: Vec3, lb: Vec3, rest: Real) -> Self:
        return Self(
            JOINT_DISTANCE, a, b, la, lb, rest,
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def hinge(a: Int, b: Int, la: Vec3, lb: Vec3, axis: Vec3) -> Self:
        return Self(
            JOINT_HINGE, a, b, la, lb, 0,
            axis, axis, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def weld(a: Int, b: Int, la: Vec3, lb: Vec3, ref_rel: Quat) -> Self:
        """Rigid bond (ROADMAP 17.5): anchors coincide AND the relative
        rotation stays `ref_rel` (= rotation(a)^-1 * rotation(b) at the time
        the bond is made). The reference quaternion rides in the fields a
        weld does not otherwise use -- `axis_a` = (x, y, z), `rest` = w -- so
        the struct layout and the snapshot format are unchanged."""
        return Self(
            JOINT_WELD, a, b, la, lb, ref_rel.w,
            Vec3(ref_rel.x, ref_rel.y, ref_rel.z, 0), Vec3(0, 0, 1, 0),
            Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def slider(a: Int, b: Int, la: Vec3, lb: Vec3, axis_a: Vec3) -> Self:
        """Prismatic (17.47): b moves along `axis_a` (a's body frame) through
        a's anchor; the other two translations and all rotation are locked.
        `ContactScene6.add_joint` records the relative rotation to hold."""
        return Self(
            JOINT_SLIDER, a, b, la, lb, 0,
            axis_a, axis_a, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def cone_twist(a: Int, b: Int, la: Vec3, lb: Vec3, axis_a: Vec3, axis_b: Vec3) -> Self:
        """Ball joint whose twist axes (`axis_a` in a's frame, `axis_b` in
        b's) carry the swing cone and twist range set on the joint's ext
        (17.47; a shoulder or hip)."""
        return Self(
            JOINT_CONE_TWIST, a, b, la, lb, 0,
            axis_a, axis_b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def rope(a: Int, b: Int, la: Vec3, lb: Vec3, max_len: Real) -> Self:
        """Anchors at most `max_len` apart and free closer in (17.47; the
        limit is set on the joint's ext by `add_joint`)."""
        return Self(
            JOINT_ROPE, a, b, la, lb, max_len,
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def universal(a: Int, b: Int, la: Vec3, lb: Vec3, axis_a: Vec3, axis_b: Vec3) -> Self:
        """Cardan / Hooke joint (17.47): anchors coincide and `axis_a` (a's
        frame) stays perpendicular to `axis_b` (b's frame) -- two rotational
        freedoms, the cross's two shafts. Make it with the axes
        perpendicular."""
        return Self(
            JOINT_UNIVERSAL, a, b, la, lb, 0,
            axis_a, axis_b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    @staticmethod
    def gear(a: Int, b: Int, axis_a: Vec3, axis_b: Vec3, ratio: Real) -> Self:
        """Gear coupling (17.47): ratio * (w_a . axis_a) + (w_b . axis_b) = 0
        -- b turns `ratio` times as fast as a, the other way for ratio > 0
        (two meshing spur gears; a negative ratio turns them the same way,
        a belt). Each body keeps its own hinge to the frame; the gear adds
        only this velocity row (no position term: tooth backlash is not
        modelled)."""
        return Self(
            JOINT_GEAR, a, b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 0,
            axis_a, axis_b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), ratio,
        )

    @staticmethod
    def pulley(a: Int, b: Int, la: Vec3, lb: Vec3, ground_a: Vec3, ground_b: Vec3, length: Real, ratio: Real) -> Self:
        """Rope over two fixed pulleys at world points `ground_a` /
        `ground_b` (17.47): |p_a - g_a| + ratio |p_b - g_b| <= length, the
        rope only pulls. ratio 2 is a block and tackle: b moves half as far
        and carries twice the tension. The ground points ride in the axis
        fields."""
        return Self(
            JOINT_PULLEY, a, b, la, lb, length,
            ground_a, ground_b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), ratio,
        )

    @staticmethod
    def d6(a: Int, b: Int, la: Vec3, lb: Vec3) -> Self:
        """Six-axis joint (17.47): every axis of a's frame (3 linear, 3
        angular) starts LOCKED (a weld); `ContactScene6.set_d6_axis` frees or
        limits each. `add_joint` records the relative rotation to hold."""
        return Self(
            JOINT_D6, a, b, la, lb, 0,
            Vec3(1, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
        )

    def ref_rotation(self) -> Quat:
        """The weld's reference relative rotation (see `weld`)."""
        return Quat(self.axis_a[0], self.axis_a[1], self.axis_a[2], self.rest)



@always_inline
def _js[B: Body6](bset: BodySet[B], i: Int) -> Real:
    """Contact / joint mass scale of body i (`SolverConfig.max_mass_ratio`,
    17.19); 1 when off (x * 1 is exact: bit-identical)."""
    return bset.cscale[i] if bset.mass_ratio > 0 else Real(1)


@always_inline
def _scaled_linear(kind: Int) -> Bool:
    """Joint kinds whose anchor rows `joint_sweep` solves (and so scales)."""
    return kind == JOINT_BALL or kind == JOINT_DISTANCE or kind == JOINT_HINGE or kind == JOINT_WELD or kind == JOINT_CONE_TWIST or kind == JOINT_UNIVERSAL


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
    scaled: Bool = False,
) -> Real:
    """One scalar equality-constraint solve along unit axis `e` with
    position error `c`; returns the accumulated-impulse delta. `scaled`:
    apply the bodies' `max_mass_ratio` scale (the core joint rows)."""
    var sa = _js(bset, ia) if scaled else Real(1)
    var sb = _js(bset, ib) if scaled else Real(1)
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
    ka *= sa
    kb *= sb
    var denom = ka + kb
    if denom <= 0:
        return 0
    var vr = dot(vb - va, e)
    var bias = bias_rate * c if use_bias else Real(0)
    var dl = -ms * (vr + bias) / denom - isc * acc_e
    var j = e * dl
    if bset.is_dynamic(ia):
        bset.bodies[ia].apply_impulse(-j * sa, pwa)
    if bset.is_dynamic(ib):
        bset.bodies[ib].apply_impulse(j * sb, pwb)
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
            if jt.kind == JOINT_BROKEN or jt.kind == JOINT_SLIDER or jt.kind == JOINT_ROPE or jt.kind == JOINT_D6:
                continue  # sliders, ropes and D6: `physics.joint_ext.ext_sweep`
            if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
                continue
            if island_filter != -2 and joint_island(bset, jt) != island_filter:
                continue
            if jt.kind == JOINT_GEAR:
                _gear_row(bset, jt)
                joints[c] = jt
                continue
            if jt.kind == JOINT_PULLEY:
                _pulley_row(bset, jt, h, bias_rate, ms, isc, use_bias)
                joints[c] = jt
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
                    h, bias_rate, ms, isc, use_bias, acc_s, True,
                )
                jt.acc = u * (acc_s + dl)
            else:
                # ball part (shared by hinge): drive the anchor gap to 0.
                for ax in range(3):
                    var e = Vec3(0, 0, 0, 0)
                    e[ax] = 1
                    var dl = joint_axis(bset,
                        jt.a, jt.b, pwa, pwb, e, gap[ax],
                        h, bias_rate, ms, isc, use_bias, jt.acc[ax], True,
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
                            kaa = bset.bodies[jt.a].angular_only_factor(t) * _js(bset, jt.a)
                        if bset.is_dynamic(jt.b):
                            kbb = bset.bodies[jt.b].angular_only_factor(t) * _js(bset, jt.b)
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
                            bset.bodies[jt.a].apply_angular_impulse(-limp * _js(bset, jt.a))
                        if bset.is_dynamic(jt.b):
                            bset.bodies[jt.b].apply_angular_impulse(limp * _js(bset, jt.b))
                        wa = Vec3(0, 0, 0, 0)
                        wb2 = Vec3(0, 0, 0, 0)
                        if bset.moves(jt.a):
                            wa = bset.bodies[jt.a].omega_world()
                        if bset.moves(jt.b):
                            wb2 = bset.bodies[jt.b].omega_world()
                elif jt.kind == JOINT_UNIVERSAL:
                    _universal_row(bset, jt, bias_rate, ms, isc, use_bias)
                elif jt.kind == JOINT_WELD:
                    # angular lock about the three world axes. `er` is the
                    # rotation vector by which b leads its reference pose
                    # rotation(a) * ref (`drive_error` points the other way).
                    var er = drive_error(
                        bset.bodies[jt.a].rotation(),
                        bset.bodies[jt.b].rotation(),
                        jt.ref_rotation(),
                    ) * Real(-1)
                    for k in range(3):
                        var ax = Vec3(0, 0, 0, 0)
                        ax[k] = 1
                        var den = Real(0)
                        if bset.is_dynamic(jt.a):
                            den += bset.bodies[jt.a].angular_only_factor(ax) * _js(bset, jt.a)
                        if bset.is_dynamic(jt.b):
                            den += bset.bodies[jt.b].angular_only_factor(ax) * _js(bset, jt.b)
                        if den <= 0:
                            continue
                        var wa = Vec3(0, 0, 0, 0)
                        var wb2 = Vec3(0, 0, 0, 0)
                        if bset.moves(jt.a):
                            wa = bset.bodies[jt.a].omega_world()
                        if bset.moves(jt.b):
                            wb2 = bset.bodies[jt.b].omega_world()
                        var vr = dot(wb2 - wa, ax)
                        var bias = bias_rate * er[k] if use_bias else Real(0)
                        var dl = -ms * (vr + bias) / den - isc * jt.acc_ang[k]
                        jt.acc_ang[k] += dl
                        var limp = ax * dl
                        if bset.is_dynamic(jt.a):
                            bset.bodies[jt.a].apply_angular_impulse(-limp * _js(bset, jt.a))
                        if bset.is_dynamic(jt.b):
                            bset.bodies[jt.b].apply_angular_impulse(limp * _js(bset, jt.b))
            joints[c] = jt


@always_inline
def _wdir[B: Body6](bset: BodySet[B], i: Int, v: Vec3) -> Vec3:
    return bset.bodies[i].act(v) - bset.bodies[i].act(Vec3(0, 0, 0, 0))


def _ang_k[B: Body6](bset: BodySet[B], i: Int, n: Vec3) -> Real:
    return bset.bodies[i].angular_only_factor(n) if bset.is_dynamic(i) else Real(0)


def _omega[B: Body6](bset: BodySet[B], i: Int) -> Vec3:
    return bset.bodies[i].omega_world() if bset.moves(i) else Vec3(0, 0, 0, 0)


def _universal_row[B: Body6](
    mut bset: BodySet[B], mut jt: Joint6, bias_rate: Real, ms: Real, isc: Real, use_bias: Bool,
):
    """C = oa . ob = 0; dC/dt = (w_b - w_a) . (ob x oa)."""
    var oa = _wdir(bset, jt.a, jt.axis_a)
    var ob = _wdir(bset, jt.b, jt.axis_b)
    var t = cross(ob, oa)
    var tl = sqrt(dot(t, t))
    if tl < 1e-9:
        return  # axes parallel: the cross is folded flat, no defined row
    t = t / tl
    var den = _ang_k(bset, jt.a, t) + _ang_k(bset, jt.b, t)
    if den <= 0:
        return
    var vr = dot(_omega(bset, jt.b) - _omega(bset, jt.a), t)
    var bias = bias_rate * dot(oa, ob) / tl if use_bias else Real(0)
    var acc_t = dot(jt.acc_ang, t)
    var dl = -ms * (vr + bias) / den - isc * acc_t
    # keep only the component along this row: the ball rows are linear
    jt.acc_ang = t * (acc_t + dl)
    if bset.is_dynamic(jt.a):
        bset.bodies[jt.a].apply_angular_impulse(t * (-dl))
    if bset.is_dynamic(jt.b):
        bset.bodies[jt.b].apply_angular_impulse(t * dl)


def _gear_row[B: Body6](mut bset: BodySet[B], mut jt: Joint6):
    """ratio (w_a . oa) + (w_b . ob) = 0, solved rigidly (a velocity row has
    no position error to soften). Impulse lambda: ratio oa lambda on a, ob
    lambda on b; `acc_ang` holds ob lambda (b's torque, for loads)."""
    var oa = _wdir(bset, jt.a, jt.axis_a)
    var ob = _wdir(bset, jt.b, jt.axis_b)
    var r = jt.ratio
    var den = r * r * _ang_k(bset, jt.a, oa) + _ang_k(bset, jt.b, ob)
    if den <= 0:
        return
    var cdot = r * dot(_omega(bset, jt.a), oa) + dot(_omega(bset, jt.b), ob)
    var lam = dot(jt.acc_ang, ob)
    var dl = -cdot / den
    jt.acc_ang = ob * (lam + dl)
    if bset.is_dynamic(jt.a):
        bset.bodies[jt.a].apply_angular_impulse(oa * (r * dl))
    if bset.is_dynamic(jt.b):
        bset.bodies[jt.b].apply_angular_impulse(ob * dl)


def _pulley_row[B: Body6](
    mut bset: BodySet[B], mut jt: Joint6, h: Real, bias_rate: Real, ms: Real, isc: Real, use_bias: Bool,
):
    """C = |p_a - g_a| + ratio |p_b - g_b| - rest <= 0. Tension lambda >= 0
    pulls a toward g_a and b toward g_b (times ratio); `acc` holds u_a
    lambda (the rope tension on a, for loads)."""
    var pa = bset.bodies[jt.a].act(jt.la)
    var pb = bset.bodies[jt.b].act(jt.lb)
    var da = pa - jt.axis_a
    var db = pb - jt.axis_b
    var la = sqrt(dot(da, da))
    var lb = sqrt(dot(db, db))
    if la < 1e-9 or lb < 1e-9:
        return
    var ua = da / la
    var ub = db / lb
    var r = jt.ratio
    var ka = Real(0)
    var kb = Real(0)
    if bset.is_dynamic(jt.a):
        ka = bset.bodies[jt.a].inv_mass() + bset.bodies[jt.a].angular_factor(pa - bset.bodies[jt.a].position(), ua)
    if bset.is_dynamic(jt.b):
        kb = bset.bodies[jt.b].inv_mass() + bset.bodies[jt.b].angular_factor(pb - bset.bodies[jt.b].position(), ub)
    var den = ka + r * r * kb
    if den <= 0:
        return
    var va = bset.bodies[jt.a].velocity_at(pa) if bset.moves(jt.a) else Vec3(0, 0, 0, 0)
    var vb = bset.bodies[jt.b].velocity_at(pb) if bset.moves(jt.b) else Vec3(0, 0, 0, 0)
    var cdot = dot(va, ua) + r * dot(vb, ub)
    var c = la + r * lb - jt.rest
    var bias = Real(0)
    var m = Real(1)
    var i = Real(0)
    if c < 0:
        bias = c / h  # slack: may close by at most -c this substep
    elif use_bias:
        bias = bias_rate * c
        m = ms
        i = isc
    var lam = sqrt(dot(jt.acc, jt.acc))
    var dl = m * (cdot + bias) / den - i * lam
    var nl = max(lam + dl, Real(0))
    dl = nl - lam
    jt.acc = ua * nl
    if bset.is_dynamic(jt.a):
        bset.bodies[jt.a].apply_impulse(ua * (-dl), pa)
    if bset.is_dynamic(jt.b):
        bset.bodies[jt.b].apply_impulse(ub * (-r * dl), pb)


def warm_start_joints[B: Body6](
    mut bset: BodySet[B], joints: List[Joint6], island_filter: Int
):
    for c in range(len(joints)):
        var jt = joints[c]
        if jt.kind == JOINT_BROKEN:
            continue
        if bset.impulse_inert(jt.a) and bset.impulse_inert(jt.b):
            continue
        if island_filter != -2 and joint_island(bset, jt) != island_filter:
            continue
        if jt.kind == JOINT_GEAR:
            var oa = _wdir(bset, jt.a, jt.axis_a)
            var ob = _wdir(bset, jt.b, jt.axis_b)
            var lam = dot(jt.acc_ang, ob)
            if bset.is_dynamic(jt.a):
                bset.bodies[jt.a].apply_angular_impulse(oa * (jt.ratio * lam))
            if bset.is_dynamic(jt.b):
                bset.bodies[jt.b].apply_angular_impulse(ob * lam)
            continue
        if jt.kind == JOINT_PULLEY:
            var pa = bset.bodies[jt.a].act(jt.la)
            var pb = bset.bodies[jt.b].act(jt.lb)
            var da = pa - jt.axis_a
            var db = pb - jt.axis_b
            var la = sqrt(dot(da, da))
            var lb = sqrt(dot(db, db))
            if la < 1e-9 or lb < 1e-9:
                continue
            var lam = sqrt(dot(jt.acc, jt.acc))
            if bset.is_dynamic(jt.a):
                bset.bodies[jt.a].apply_impulse(da * (-lam / la), pa)
            if bset.is_dynamic(jt.b):
                bset.bodies[jt.b].apply_impulse(db * (-jt.ratio * lam / lb), pb)
            continue
        var pwa = bset.bodies[jt.a].act(jt.la)
        var pwb = bset.bodies[jt.b].act(jt.lb)
        # 17.19: rows `joint_sweep` scales take the same scale here
        var lin = _scaled_linear(jt.kind)
        var ang = jt.kind == JOINT_HINGE or jt.kind == JOINT_WELD
        var sa = _js(bset, jt.a)
        var sb = _js(bset, jt.b)
        if bset.is_dynamic(jt.a):
            bset.bodies[jt.a].apply_impulse(-jt.acc * (sa if lin else Real(1)), pwa)
            if jt.kind == JOINT_HINGE or jt.kind == JOINT_WELD or jt.kind == JOINT_SLIDER or jt.kind == JOINT_UNIVERSAL:
                bset.bodies[jt.a].apply_angular_impulse(-jt.acc_ang * (sa if ang else Real(1)))
        if bset.is_dynamic(jt.b):
            bset.bodies[jt.b].apply_impulse(jt.acc * (sb if lin else Real(1)), pwb)
            if jt.kind == JOINT_HINGE or jt.kind == JOINT_WELD or jt.kind == JOINT_SLIDER or jt.kind == JOINT_UNIVERSAL:
                bset.bodies[jt.b].apply_angular_impulse(jt.acc_ang * (sb if ang else Real(1)))


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


def sample_loads(
    joints: List[Joint6], h: Real, mut peak_force: List[Real], mut peak_torque: List[Real]
):
    """Record each joint's load after a substep -- its accumulated linear
    and angular impulse over the substep length -- keeping the frame's peak.
    Sampling every substep is what catches an impact: the last substep
    alone reads the joint after the impact has already been absorbed."""
    for c in range(len(joints)):
        if joints[c].kind == JOINT_BROKEN:
            continue
        peak_force[c] = max(peak_force[c], sqrt(dot(joints[c].acc, joints[c].acc)) / h)
        peak_torque[c] = max(peak_torque[c], sqrt(dot(joints[c].acc_ang, joints[c].acc_ang)) / h)


def check_breaks(
    mut joints: List[Joint6],
    break_force: List[Real],
    break_torque: List[Real],
    mut peak_force: List[Real],
    mut peak_torque: List[Real],
    mut broken: List[Int],
):
    """Release every joint whose peak load this step exceeded its threshold
    (ROADMAP 17.29), then reset the peaks. In a steady state the peak equals
    the constraint force (a hanging mass m reads m·g). A released joint
    turns `JOINT_BROKEN` and its index is appended to `broken`."""
    for c in range(len(joints)):
        if joints[c].kind != JOINT_BROKEN and (
            peak_force[c] > break_force[c] or peak_torque[c] > break_torque[c]
        ):
            joints[c].kind = JOINT_BROKEN
            joints[c].acc = Vec3(0, 0, 0, 0)
            joints[c].acc_ang = Vec3(0, 0, 0, 0)
            broken.append(c)
        peak_force[c] = 0
        peak_torque[c] = 0
