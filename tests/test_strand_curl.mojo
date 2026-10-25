# tier: unit  (override: steps physics.strand alone; physics.rigid6 / fields are its pose and wind types)
"""Curled rest shapes for strands (ROADMAP 17.57, `StrandSet.add_curl`).

A 12-particle strand (2 cm segments) hanging from a bone along -y, curling
0.4 rad per segment about z, bend 0.5:

  1. Ordinary: `add_curl` with angle 0 steps bit for bit like `add` (both
     straight); with zero gravity, a kicked curled strand returns to its
     rest shape (largest deviation < 1 mm after 3 s) and its successive
     segments turn by 0.4 rad (+- 0.01).
  2. Integration: under gravity the curl persists: the curled tip sits
     sideways of the root (|x| > 3 cm) where the straight strand hangs
     plumb (|x| < 1 mm).
  3. Extreme: the rest shape is carried by the bone: after the bone turns
     90 degrees about y the zero-gravity strand settles on the turned rest
     shape (< 2 mm), i.e. it curls in the turned plane.
"""

from std.math import sqrt, acos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet

comptime DT: Real = 1.0 / 120.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime G = Vec3(0, -9.8, 0, 0)
comptime ANG: Real = 0.4


def bone(rot: Quat) -> List[Pose6]:
    return [Pose6(Vec3(0, 1, 0, 0), rot)]


def curled(angle: Real) raises -> StrandSet:
    var s = StrandSet(0.5, 0.5, 0.9, 0.002, 20.0)
    _ = s.add_curl(0, bone(Quat.identity())[0], ZERO, Vec3(0, -1, 0, 0), Vec3(0, 0, 1, 0), angle, 12, 0.02)
    return s^


def deviation(a: StrandSet, b: List[Vec3]) -> Real:
    var w = Real(0)
    for i in range(len(b)):
        w = max(w, length(a.x[i] - b[i]))
    return w


def main() raises:
    var st = Suite("strand_curl")
    var a = StrandSet(0.5, 0.5, 0.9, 0.002, 20.0)
    _ = a.add(0, bone(Quat.identity())[0], ZERO, Vec3(0, -1, 0, 0), 12, 0.02)
    var b = curled(0)
    var same = True
    for _ in range(240):
        a.step(DT, G, bone(Quat.identity()))
        b.step(DT, G, bone(Quat.identity()))
    for i in range(12):
        same = same and a.x[i][0] == b.x[i][0] and a.x[i][1] == b.x[i][1] and a.x[i][2] == b.x[i][2]
    st.check(same, "add_curl with angle 0 == add, bit for bit")

    var c = curled(ANG)
    var rest = c.x.copy()
    for i in range(1, 12):
        c.v[i] = Vec3(0.3 * Real(i % 3) - 0.3, 0.2, 0.1 * Real(i % 2), 0)
    for _ in range(360):
        c.step(DT, ZERO, bone(Quat.identity()))
    var dev = deviation(c, rest)
    var worst_turn = Real(0)
    for k in range(2, 12):
        var d0 = c.x[k - 1] - c.x[k - 2]
        var d1 = c.x[k] - c.x[k - 1]
        var turn = acos(min(Real(1), dot(d0, d1) / (length(d0) * length(d1))))
        worst_turn = max(worst_turn, abs(turn - ANG))
    print("zero g, kicked: largest deviation from the rest shape after 3 s", dev, " worst segment turn error", worst_turn)
    st.check(dev < 1e-3 and worst_turn < 0.01, "a kicked curled strand returns to its rest shape")

    var g = curled(ANG)
    var s2 = StrandSet(0.5, 0.5, 0.9, 0.002, 20.0)
    _ = s2.add(0, bone(Quat.identity())[0], ZERO, Vec3(0, -1, 0, 0), 12, 0.02)
    for _ in range(480):
        g.step(DT, G, bone(Quat.identity()))
        s2.step(DT, G, bone(Quat.identity()))
    print("under gravity after 4 s: curled tip x", g.tip(0)[0], " straight tip x", s2.tip(0)[0])
    st.check(abs(g.tip(0)[0]) > 0.03 and abs(s2.tip(0)[0]) < 1e-3, "the curl persists under gravity; the straight strand hangs plumb")

    var t = curled(ANG)
    var q = Quat.from_axis_angle(Vec3(0, 1, 0, 0), Real(pi) / 2)
    for _ in range(600):
        t.step(DT, ZERO, bone(q))
    var want = List[Vec3]()
    var root = Vec3(0, 1, 0, 0)
    for i in range(12):
        want.append(root + q.rotate(rest[i] - root))
    var dt_ = deviation(t, want)
    print("bone turned 90 deg about y: deviation from the turned rest shape", dt_)
    st.check(dt_ < 2e-3, "the rest shape turns with the bone")
    st.finish()
