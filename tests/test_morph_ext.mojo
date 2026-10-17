# tier: component
"""Deformation data, second batch (ROADMAP 17.65): normal deltas,
in-between shapes, RBF correctives, the per-bone scale channel.

  1. Normal deltas: a target with weight 1 turns +y normals to +x
     (normalised); weight 0 leaves the base normals bit for bit; a delta
     that cancels the normal keeps the base normal.
  2. In-betweens: shapes at 0.5 and 1.0; at w = 0.5 / 1.0 the result is
     the shape exactly, at 0.25 half the first, at 0.75 the midpoint of
     the two, at 1.5 the last segment extended; one shape at 1 equals the
     plain `MorphSet` target bit for bit.
  3. RBF: elbow-angle samples 0 / 60 / 120 deg -> weights 0 / 0.3 / 1 are
     reproduced (1e-5); 90 deg falls between 0.3 and 1; duplicate samples
     raise.
  4. Scale channel: all scales 1 equal `skin_motor_k` bit for bit; a bone
     scaled (1, 0.5, 1) about its joint halves its vertices' height above
     the joint (squash) at the bind pose.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.motor import Motor3
from geometry.morph import MorphSet, InbetweenMorph
from geometry.pose_space import PoseSpaceRbf
from geometry.skinning import skin_motor_k, skin_motor_k_scaled


def main() raises:
    var s = Suite("morph_ext")

    # 1. normal deltas
    var base_n = List[Vec3](length=4, fill=Vec3(0, 1, 0, 0))
    var m = MorphSet(4)
    _ = m.add_target_n([1, 2], [Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)], [Vec3(1, -1, 0, 0), Vec3(0, -1, 0, 0)])
    var n1 = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    m.apply_normals(base_n, [1.0], n1)
    var n0 = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    m.apply_normals(base_n, [0.0], n0)
    s.check(abs(n1[1][0] - 1) < 1e-6 and abs(n1[1][1]) < 1e-6, "normal delta turns +y into +x")
    s.check(n1[2][1] == 1 and n1[0][1] == 1, "a cancelling delta keeps the base normal; untouched vertices keep theirs")
    s.check(n0[1][1] == 1 and n0[1][0] == 0, "weight 0: base normals")

    # 2. in-betweens
    var base = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    var ib = InbetweenMorph(3)
    ib.add_shape(0.5, [0], [Vec3(0, 1, 0, 0)])
    ib.add_shape(1.0, [0, 2], [Vec3(0, 0, 3, 0), Vec3(2, 0, 0, 0)])
    var o = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    ib.apply(base, 0.5, o)
    var at05 = o[0][1] == 1 and o[0][2] == 0 and o[2][0] == 0
    ib.apply(base, 1.0, o)
    var at1 = o[0][2] == 3 and o[0][1] == 0 and o[2][0] == 2
    ib.apply(base, 0.25, o)
    var at025 = abs(o[0][1] - 0.5) < 1e-6
    ib.apply(base, 0.75, o)
    var at075 = abs(o[0][1] - 0.5) < 1e-6 and abs(o[0][2] - 1.5) < 1e-6 and abs(o[2][0] - 1) < 1e-6
    ib.apply(base, 1.5, o)
    var at15 = abs(o[0][2] - 6) < 1e-6 and abs(o[0][1] + 1) < 1e-6 and abs(o[2][0] - 4) < 1e-6
    print("in-between at 0.75:", o[0][0], " checks", at05, at1, at025, at075, at15)
    s.check(at05 and at1, "in-betweens: the shapes at their weights exactly")
    s.check(at025 and at075, "in-betweens: piecewise linear between shapes (and from zero)")
    s.check(at15, "in-betweens: last segment extended past the last weight")
    var one = InbetweenMorph(3)
    one.add_shape(1.0, [0, 2], [Vec3(0.3, 0.1, 0, 0), Vec3(2, 0, 0.7, 0)])
    var plain = MorphSet(3)
    _ = plain.add_target([0, 2], [Vec3(0.3, 0.1, 0, 0), Vec3(2, 0, 0.7, 0)])
    var a = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    var b = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    var same = True
    for wv in [Real(0.3), Real(0.77), Real(1.0)]:
        one.apply(base, wv, a)
        plain.apply(base, [wv], b)
        for i in range(3):
            same = same and length(a[i] - b[i]) < 1e-7
    s.check(same, "one shape at 1 = the plain linear target")

    # 3. RBF correctives
    var rbf = PoseSpaceRbf(1, 1, 1.0)
    var deg = Real(3.14159265358979) / 180
    rbf.add([0.0], [0.0])
    rbf.add([60 * deg], [0.3])
    rbf.add([120 * deg], [1.0])
    rbf.solve()
    var e0 = rbf.eval([0.0])[0]
    var e60 = rbf.eval([60 * deg])[0]
    var e120 = rbf.eval([120 * deg])[0]
    var e90 = rbf.eval([90 * deg])[0]
    print("RBF: 0 / 60 / 120 / 90 deg ->", e0, e60, e120, e90)
    s.check(abs(e0) < 1e-5 and abs(e60 - 0.3) < 1e-5 and abs(e120 - 1) < 1e-5, "RBF reproduces its samples")
    s.check(e90 > 0.3 and e90 < 1, "RBF: 90 deg between the 60 and 120 deg samples")
    var dup = PoseSpaceRbf(1, 1, 1.0)
    dup.add([0.5], [1.0])
    dup.add([0.5], [2.0])
    var raised = False
    try:
        dup.solve()
    except:
        raised = True
    s.check(raised, "duplicate samples raise")

    # 4. scale channel: bone 0 at the origin, bone 1 (the joint) at y = 1
    var bones: List[Motor3] = [Motor3.identity(), Motor3.identity()]
    var rest: List[Vec3] = [Vec3(0.1, 0.5, 0, 0), Vec3(0.1, 1.5, 0, 0), Vec3(-0.1, 2.0, 0.2, 0)]
    var idx: List[Int] = [0, 1, 1, 0, 1, 0]
    var wts: List[Real] = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0]
    var centre: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0)]
    var ones: List[Vec3] = [Vec3(1, 1, 1, 0), Vec3(1, 1, 1, 0)]
    var p1 = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    var p2 = List[Vec3](length=3, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(bones, rest, idx, wts, 2, p1)
    skin_motor_k_scaled(bones, ones, centre, rest, idx, wts, 2, p2)
    var bit = True
    for i in range(3):
        bit = bit and p1[i][0] == p2[i][0] and p1[i][1] == p2[i][1] and p1[i][2] == p2[i][2]
    s.check(bit, "scales 1: skin_motor_k bit for bit")
    var squash: List[Vec3] = [Vec3(1, 1, 1, 0), Vec3(1, 0.5, 1, 0)]
    skin_motor_k_scaled(bones, squash, centre, rest, idx, wts, 2, p2)
    print("squash (1, 0.5, 1) about y = 1: heights", p2[0][1], p2[1][1], p2[2][1])
    s.check(p2[0][1] == 0.5 and abs(p2[1][1] - 1.25) < 1e-6 and abs(p2[2][1] - 1.5) < 1e-6, "squash halves the height above the joint, bone 0 untouched")
    s.finish()
