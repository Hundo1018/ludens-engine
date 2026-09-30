# tier: integration
"""Ropes (ROADMAP 17.41).

  ordinary     a 3 m inextensible rope pinned 2 m apart settles on the
               catenary: its sag matches the analytic a cosh(d / 2a) - a.
  seam parity  the same span as a chain of rigid links on distance joints
               in `ContactScene6` sags to the same depth (both approximate
               the catenary).
  integration  a rope tied (a solver distance joint as its load path)
               holds a 2 kg crate a rope length below the pin, carrying its
               weight; with a break tension below that load the rope snaps
               and the crate falls; a rope draped over a static box stays on
               top of it.
  extreme      a compliant rope stretches under the same load; a single
               segment works; both ends pinned at one point stay finite.
"""

from std.math import sqrt, cosh, sinh, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.rope import Rope

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _al(mut s: Suite, got: Real, want: Real, tol: Real, label: String):
    s.almost(Float64(got), Float64(want), label, Float64(tol))


def _catenary_sag(span: Real, length: Real) -> Real:
    """Solve 2 a sinh(span / 2a) = length for a (bisection), return the sag."""
    var lo = Real(0.01)
    var hi = Real(100)
    for _ in range(200):
        var a = (lo + hi) / 2
        if 2 * a * sinh(span / (2 * a)) > length:
            lo = a
        else:
            hi = a
    var a = (lo + hi) / 2
    return a * cosh(span / (2 * a)) - a


def _lowest(r: Rope) -> Real:
    var y = Real(1e9)
    for i in range(len(r.x)):
        y = min(y, r.x[i][1])
    return y


def main() raises:
    var s = Suite("rope")
    var sag = _catenary_sag(2, 3)

    # ---- ordinary: catenary ---------------------------------------------------
    var empty = ContactScene6[QuatBody6]()
    var r = Rope(Vec3(-1, 0, 0, 0), Vec3(1, 0, 0, 0), 40, 1, 0, 0, 3)
    r.pin(0, Vec3(-1, 0, 0, 0))
    r.pin(1, Vec3(1, 0, 0, 0))
    r.damping = 0.98
    for _ in range(600):
        r.step(empty, DT, G, 8, 8)
    var rs = -_lowest(r)
    print("  catenary sag", sag, " rope", rs, " length", r.length())
    _al(s, rs, sag, 0.03 * sag, "rope sag == catenary sag (3%)")
    _al(s, r.length(), 3, 0.02, "inextensible rope keeps its length")

    # ---- seam parity: rigid links on distance joints -----------------------
    var ch = ContactScene6[QuatBody6]()
    var links = 20
    var seg = Real(3) / Real(links)
    _ = ch.add(QuatBody6.at_rest(Vec3(-1, 0, 0, 0), Inertia3.box(1, 0.01, 0.01, 0.01)), Vec3(0.01, 0.01, 0.01, 0), True)
    for i in range(links - 1):
        var x = -1 + 2 * Real(i + 1) / Real(links)
        var id = ch.add(QuatBody6.at_rest(Vec3(x, 0, 0, 0), Inertia3.box(1.0 / 19.0, 0.02, 0.02, 0.02)), Vec3(0.02, 0.02, 0.02, 0), False)
        ch.set_filter(id.index(), 2, 1)  # links do not collide with each other
    _ = ch.add(QuatBody6.at_rest(Vec3(1, 0, 0, 0), Inertia3.box(1, 0.01, 0.01, 0.01)), Vec3(0.01, 0.01, 0.01, 0), True)
    var last = links
    for i in range(links):
        var a = i
        var b = i + 1 if i + 1 < links else last
        _ = ch.add_joint(Joint6.distance(a, b, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), seg))
    for _ in range(900):
        ch.step_soft(DT, G, substeps=8, iters=8)
    var low = Real(1e9)
    for i in range(len(ch.bset.bodies)):
        low = min(low, ch.bset.bodies[i].position()[1])
    print("  rigid-link chain sag", -low)
    _al(s, -low, sag, 0.05 * sag, "distance-joint chain sags to the catenary too (5%)")
    _al(s, -low, rs, 0.05 * sag, "rope and link chain agree (the seam)")

    # ---- integration: two-way load, snapping, draping ------------------------
    var hs = ContactScene6[QuatBody6]()
    var crate = hs.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(2, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    hs.set_can_sleep(crate, False)
    var hr = Rope(Vec3(0, 5, 0, 0), Vec3(0, 3.2, 0, 0), 20, 0.5, 0, 0, 1.8)
    hr.pin(0, Vec3(0, 5, 0, 0))
    hr.attach(1, hs, crate.index(), Vec3(0, 0.2, 0, 0))
    var tj = hr.tie(hs)
    hr.damping = 0.98
    for _ in range(300):
        hr.step(hs, DT, G)
        hs.step_soft(DT, G)
    var cy = hs.bset.bodies[crate.index()].position()[1]
    var load = sqrt(dot(hs.joints[tj].acc, hs.joints[tj].acc)) / (DT / 4)
    print("  hanging crate y", cy, " rope load", load)
    _al(s, cy, 5 - 1.8 - 0.2, 0.02, "the crate hangs a rope length below the pin")
    _al(s, load, 2 * 9.8, 0.05 * 19.6, "the rope's load path carries the crate's weight")
    hs.set_joint_break(tj, 10, 1e9)
    for _ in range(60):
        hr.step(hs, DT, G)
        hs.step_soft(DT, G)
    var snapped = False
    for i in range(len(hr.cut)):
        if hr.cut[i]:
            snapped = True
    s.check(snapped, "load above the break tension snaps the rope")
    s.check(hs.bset.bodies[crate.index()].position()[1] < cy - 1, "and the crate falls")

    var dr = ContactScene6[QuatBody6]()
    _ = dr.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), True)
    var drape = Rope(Vec3(-1, 1, 0, 0), Vec3(1, 1, 0, 0), 30, 0.3, 0, 0.03)
    drape.damping = 0.98
    for _ in range(180):
        drape.step(dr, DT, G)
    var on_top = True
    for i in range(len(drape.x)):
        var p = drape.x[i]
        if abs(p[0]) < 0.45 and p[1] < 0.5 + 0.03 - 0.01:
            on_top = False
    s.check(on_top, "a rope draped over a box stays on top of it")

    # ---- extremes --------------------------------------------------------------
    var soft = Rope(Vec3(0, 5, 0, 0), Vec3(0, 3, 0, 0), 20, 1, 1e-2, 0, 2)
    soft.pin(0, Vec3(0, 5, 0, 0))
    soft.damping = 0.98
    var stiff = Rope(Vec3(0, 5, 0, 0), Vec3(0, 3, 0, 0), 20, 1, 0, 0, 2)
    stiff.pin(0, Vec3(0, 5, 0, 0))
    stiff.damping = 0.98
    for _ in range(300):
        soft.step(empty, DT, G)
        stiff.step(empty, DT, G)
    s.check(soft.length() > stiff.length() + 0.01, "a compliant rope stretches more under its own weight")
    var one = Rope(Vec3(0, 1, 0, 0), Vec3(1, 1, 0, 0), 1, 1)
    one.pin(0, Vec3(0, 1, 0, 0))
    for _ in range(120):
        one.step(empty, DT, G)
    _al(s, one.length(), 1, 1e-3, "a single-segment rope is a pendulum of fixed length")
    var loop = Rope(Vec3(0, 1, 0, 0), Vec3(0, 1, 0, 0), 10, 1, 0, 0, 1)
    loop.pin(0, Vec3(0, 1, 0, 0))
    loop.pin(1, Vec3(0, 1, 0, 0))
    for _ in range(120):
        loop.step(empty, DT, G)
    var fin = True
    for i in range(len(loop.x)):
        if not (isfinite(loop.x[i][0]) and isfinite(loop.x[i][1])):
            fin = False
    s.check(fin, "both ends pinned at one point: finite")

    s.finish()
