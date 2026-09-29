"""Two-body joints for the soft substep solver (audit F11, cluster 4):
`Joint6` (ball / distance / hinge equality constraints), the scalar axis
solve, the sweep, and warm starting -- free functions over a `BodySet` view
and a joint slice, composed by `ContactScene6` (`physics/solver6.mojo`).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross, tangent_basis
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
