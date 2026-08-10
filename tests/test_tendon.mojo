"""Tendons, gated on the one identity everything else follows from:
`tau = -F dL/dq`.

The moment arms are checked against a CENTRAL FINITE DIFFERENCE of the length
function, which is the only check that actually tests the claim made in the
module docstring — that the tangent points of a wrapped path contribute
nothing to `dL/dq`. The finite difference knows nothing about that argument;
it just re-measures the whole path, arc included. If the stationarity
reasoning were wrong, the analytic arms and the difference would disagree
exactly where the wrap engages.

The integral gate is the second independent one: over a simulated trajectory,
the work a constant tension does must equal `-F * (L_end - L_start)`
regardless of the path taken between them. That is a statement about the
whole trajectory, so a moment arm that is right on average and wrong
instant-to-instant does not survive it.
"""

from std.math import sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from physics.chain import Chain, ChainLink
from physics.tendon import FixedTendon, SpatialTendon, WrapSphere


def zeros(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def arm_chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0.6, 0, 0), Vec3(0.3, 0, 0), 1.0,
                Vec3(0.02, 0.02, 0.02),
            )
        )
    return c^


def main() raises:
    var s = Suite("tendon")
    var g = Vec3(0, -9.81, 0)

    # ---- 1. fixed tendon: the arms ARE the coefficients ------------------
    var ft = FixedTendon()
    ft.add(0, 1.0)
    ft.add(1, -2.0)
    var q = zeros(2)
    q[0] = 0.7
    q[1] = 0.25
    print("  fixed length:", ft.length(q))
    s.check(abs(Float64(ft.length(q) - 0.2)) < 1e-6, "L = sum(c_i q_i)")

    var tau = zeros(2)
    ft.apply_tension(3.0, tau)
    s.check(
        abs(Float64(tau[0] + 3.0)) < 1e-6 and abs(Float64(tau[1] - 6.0)) < 1e-6,
        "fixed tendon torque = -F * c",
    )
    # accumulation: a second tendon on the same joints adds, it does not clobber
    ft.apply_tension(3.0, tau)
    s.check(abs(Float64(tau[0] + 6.0)) < 1e-6, "tendon torques accumulate")

    # ---- 2. spatial tendon, NO wrap: arms vs central difference ----------
    var c3 = arm_chain(3)
    c3.q[0] = 0.4
    c3.q[1] = -0.6
    c3.q[2] = 0.35
    var st = SpatialTendon()
    st.add_site(0, Vec3(0.1, 0.12, 0))
    st.add_site(1, Vec3(0.3, -0.09, 0))
    st.add_site(2, Vec3(0.5, 0.07, 0))

    var worst = Real(0)
    var ma = st.moment_arms(c3)
    var h = Real(2e-4)
    for i in range(3):
        var save = c3.q[i]
        c3.q[i] = save + h
        var lp = st.length(c3)
        c3.q[i] = save - h
        var lm = st.length(c3)
        c3.q[i] = save
        var fd = (lp - lm) / (2 * h)
        var e = Real(abs(Float64(ma[i] - fd)))
        print("  no-wrap arm", i, ":", ma[i], " fd:", fd)
        if e > worst:
            worst = e
    s.check(worst < 2e-3, "moment arms == d(length)/dq, unwrapped")

    # ---- 3. wrapping: length is continuous through the onset -------------
    #      sweep the obstacle radius up through the point where it first
    #      touches the straight path; a discontinuity here would be an
    #      impulsive force at the instant a tendon meets an obstacle
    var c1 = arm_chain(1)
    var sw = SpatialTendon()
    sw.add_site(0, Vec3(0.0, 0.35, 0))
    sw.add_site(0, Vec3(0.6, 0.35, 0))
    # the link pivot offsets both sites, so the obstacle is placed relative to
    # the chord's ACTUAL world midpoint rather than to the local coordinates
    var ca = c1.point_world(0, Vec3(0.0, 0.35, 0))
    var cb = c1.point_world(0, Vec3(0.6, 0.35, 0))
    var cmid = (ca + cb) * 0.5 - Vec3(0, 0.2, 0)  # 0.2 below the chord
    var prev = Real(-1)
    var max_jump = Real(0)
    var straight = Real(0)
    var monotone = True
    for k in range(60):
        var r = Real(k) * 0.005  # stays below |A-O| = 0.36, so both ends stay outside
        sw.wraps[0] = WrapSphere(cmid, r)
        var L = sw.length(c1)
        if k == 0:
            straight = L
        else:
            var jump = Real(abs(Float64(L - prev)))
            if jump > max_jump:
                max_jump = jump
            if L < prev - 1e-5:
                monotone = False
        prev = L
    print("  straight length:", straight, " final wrapped:", prev)
    print("  largest step in L over the sweep:", max_jump)
    s.check(prev > straight * 1.05, "a big enough obstacle lengthens the path")
    s.check(max_jump < 0.02, "length is continuous through wrap onset")
    s.check(monotone, "a growing obstacle never shortens the path")

    # ---- 4. the wrapped path actually clears the obstacle ----------------
    #      chord distance from the centre vs the radius: if the reported
    #      length were the straight one, this would be a penetrating path
    sw.wraps[0] = WrapSphere(cmid, 0.28)
    var a = ca
    var b = cb
    var Lw = sw.length(c1)
    print("  wrapped:", Lw, " straight:", length(b - a))
    s.check(Lw > length(b - a) + 1e-4, "wrapped path is longer than the chord")

    # ---- 5. WRAPPED moment arms vs central difference --------------------
    #      the real test of the stationarity argument
    var c2 = arm_chain(2)
    c2.q[0] = 0.3
    c2.q[1] = 0.5
    var sw2 = SpatialTendon()
    sw2.add_site(0, Vec3(0.05, 0.30, 0))
    sw2.add_site(1, Vec3(0.55, 0.30, 0))
    # centre the obstacle on the chord and nudge it off, so the wrap plane is
    # well defined -- exactly on the chord the geodesic family is degenerate
    var wa = c2.point_world(0, Vec3(0.05, 0.30, 0))
    var wb = c2.point_world(1, Vec3(0.55, 0.30, 0))
    var half = length(wb - wa) * 0.5
    sw2.wrap_last((wa + wb) * 0.5 + Vec3(0, 0.05, 0), half * 0.7)

    var ma2 = sw2.moment_arms(c2)
    var worst2 = Real(0)
    for i in range(2):
        var save = c2.q[i]
        c2.q[i] = save + h
        var lp = sw2.length(c2)
        c2.q[i] = save - h
        var lm = sw2.length(c2)
        c2.q[i] = save
        var fd = (lp - lm) / (2 * h)
        print("  wrapped arm", i, ":", ma2[i], " fd:", fd)
        var e = Real(abs(Float64(ma2[i] - fd)))
        if e > worst2:
            worst2 = e
    # confirm the wrap is engaged, or the test above proves nothing
    var chord = length(wb - wa)
    var wrapped_active = sw2.length(c2) > chord + 1e-5
    print("  wrap engaged:", wrapped_active, " (path", sw2.length(c2), "vs chord", chord, ")")
    s.check(wrapped_active, "the wrapped configuration really is wrapping")
    s.check(worst2 < 5e-3, "moment arms == d(length)/dq WITH the wrap engaged")

    # ---- 6. power balance: tau . qd == -F dL/dt --------------------------
    var cp = arm_chain(3)
    cp.q[0] = 0.2
    cp.q[1] = -0.4
    cp.q[2] = 0.6
    cp.qd[0] = 0.9
    cp.qd[1] = -1.3
    cp.qd[2] = 0.5
    var F = Real(4.0)
    var tp = zeros(3)
    st.apply_tension(cp, F, tp)
    var power = Real(0)
    for i in range(3):
        power += tp[i] * cp.qd[i]
    var ldot = st.velocity(cp)
    print("  tendon power:", power, "  -F*dL/dt:", -F * ldot)
    s.check(
        abs(Float64(power - (-F * ldot))) < 1e-4,
        "mechanical power == -F * dL/dt",
    )

    # ---- 7. INTEGRAL gate: work over a trajectory == -F * delta L --------
    var cw = arm_chain(3)
    cw.q[0] = 0.5
    cw.q[1] = -0.3
    cw.q[2] = 0.2
    var L0 = st.length(cw)
    var dt = Real(1.0 / 2000.0)
    var work = Real(0)
    for _ in range(400):
        var t2 = zeros(3)
        st.apply_tension(cw, F, t2)
        var p = Real(0)
        for i in range(3):
            p += t2[i] * cw.qd[i]
        work += p * dt
        cw.step(dt, t2, g)
    var L1 = st.length(cw)
    print("  integrated work:", work, "  -F*(L1-L0):", -F * (L1 - L0))
    var rel = abs(Float64(work - (-F * (L1 - L0)))) / (abs(Float64(F * (L1 - L0))) + 1e-9)
    print("  relative:", rel)
    s.check(rel < 5e-3, "work over a trajectory == -F * delta L")

    s.finish()
