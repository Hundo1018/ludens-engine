"""Balance quantities for physical characters (ROADMAP 17.66).

  * `center_of_mass(sc, bodies)`: mass-weighted centre and velocity of a set
    of bodies (a ragdoll's links).
  * `support_polygon(points)`: convex hull of the ground-contact points,
    projected to the ground plane, counter-clockwise in (x, z)
    (positive shoelace area x_a z_b - x_b z_a).
  * `capture_point(com, vel, g)`: the linear inverted pendulum's capture
    point com_xz + v_xz sqrt(h / g): where the foot must land to stop.
  * `balance_margin(poly, p)`: signed distance from p to the polygon edge,
    positive inside; `is_balanced` = margin of the capture point >= 0.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from physics.body_set import BodyId
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6


def center_of_mass[B: Body6](sc: ContactScene6[B], bodies: List[BodyId]) raises -> Tuple[Vec3, Vec3]:
    var m = Real(0)
    var c = Vec3(0, 0, 0, 0)
    var v = Vec3(0, 0, 0, 0)
    for id in bodies:
        var i = id.index()
        var im = sc.bset.bodies[i].inv_mass()
        if im <= 0:
            continue
        var mi = 1 / im
        m += mi
        c = c + sc.pose(id).pos * mi
        v = v + sc.velocity(id) * mi
    if m == 0:
        raise Error("center_of_mass: no dynamic body in the set")
    return (c * (1 / m), v * (1 / m))


def _cross2(o: Vec3, a: Vec3, b: Vec3) -> Real:
    return (a[0] - o[0]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[0] - o[0])


def support_polygon(points: List[Vec3]) -> List[Vec3]:
    """Convex hull in (x, z), counter-clockwise in (x, z) (monotone chain);
    collinear points dropped. Fewer than 3 distinct points give them back."""
    var p = List[Vec3]()
    for q in points:
        p.append(Vec3(q[0], 0, q[2], 0))
    # insertion sort by (x, z): support sets are a handful of points
    for i in range(1, len(p)):
        var j = i
        while j > 0 and (p[j][0] < p[j - 1][0] or (p[j][0] == p[j - 1][0] and p[j][2] < p[j - 1][2])):
            var t = p[j]
            p[j] = p[j - 1]
            p[j - 1] = t
            j -= 1
    if len(p) < 3:
        return p^
    var h = List[Vec3]()
    for i in range(len(p)):
        while len(h) >= 2 and _cross2(h[len(h) - 2], h[len(h) - 1], p[i]) >= 0:
            _ = h.pop()
        h.append(p[i])
    var lower = len(h) + 1
    var i = len(p) - 2
    while i >= 0:
        while len(h) >= lower and _cross2(h[len(h) - 2], h[len(h) - 1], p[i]) >= 0:
            _ = h.pop()
        h.append(p[i])
        i -= 1
    _ = h.pop()
    # the chain above is clockwise in (x, z); reverse it
    var out = List[Vec3]()
    var k = len(h) - 1
    while k >= 0:
        out.append(h[k])
        k -= 1
    return out^


def capture_point(com: Vec3, vel: Vec3, ground_y: Real, g: Real) -> Vec3:
    var h = max(com[1] - ground_y, Real(1e-6))
    var w = sqrt(h / g)
    return Vec3(com[0] + vel[0] * w, ground_y, com[2] + vel[2] * w, 0)


def balance_margin(poly: List[Vec3], p: Vec3) -> Real:
    """Signed distance in (x, z) from p to the polygon boundary, positive
    inside. Needs >= 3 vertices (otherwise -inf: no area to stand on)."""
    var n = len(poly)
    if n < 3:
        return -Real.MAX
    var inside = True
    var best = Real.MAX
    var sign = Real(0)
    for i in range(n):
        var a = poly[i]
        var b = poly[(i + 1) % n]
        var ex = b[0] - a[0]
        var ez = b[2] - a[2]
        var l2 = ex * ex + ez * ez
        var t = ((p[0] - a[0]) * ex + (p[2] - a[2]) * ez) / l2 if l2 > 0 else Real(0)
        t = min(max(t, Real(0)), Real(1))
        var dx = p[0] - (a[0] + ex * t)
        var dz = p[2] - (a[2] + ez * t)
        best = min(best, sqrt(dx * dx + dz * dz))
        var c = ex * (p[2] - a[2]) - ez * (p[0] - a[0])
        if sign == 0:
            sign = c
        elif (c > 0) != (sign > 0) and c != 0:
            inside = False
    return best if inside else -best


def is_balanced(poly: List[Vec3], com: Vec3, vel: Vec3, ground_y: Real, g: Real) -> Bool:
    return balance_margin(poly, capture_point(com, vel, ground_y, g)) >= 0
