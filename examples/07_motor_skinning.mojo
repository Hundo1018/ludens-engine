"""Example 07 — motor skinning vs linear blend skinning (the candy wrapper).

A ring of vertices around a joint that twists 0° → 180°. Linear blend skinning
(LBS) averages matrices, so at half weight the ring collapses toward the bone
axis — the classic candy-wrapper artifact. Motor (dual-quaternion-style)
blending stays on the motion manifold and keeps the ring at full radius.

Run:

    pixi run mojo run -I build examples/07_motor_skinning.mojo
"""

from std.math import sqrt, cos, sin
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.skinning import skin_motor, skin_lbs


def ring_radius(pts: List[Vec3]) -> Tuple[Real, Real]:
    """(min, max) distance of the ring from the twist (x) axis."""
    var lo = Real(1e9)
    var hi = Real(0)
    for i in range(len(pts)):
        var r = sqrt(pts[i][1] * pts[i][1] + pts[i][2] * pts[i][2])
        if r < lo:
            lo = r
        if r > hi:
            hi = r
    return (lo, hi)


def main():
    # 8 vertices on a unit ring at x = 0.5, weighted half/half between bones
    var rest = List[Vec3]()
    var ia = List[Int]()
    var ib = List[Int]()
    var wa = List[Real]()
    var out = List[Vec3]()
    for k in range(8):
        var t = Real(k) * 0.785398
        rest.append(Vec3(0.5, cos(t), sin(t)))
        ia.append(0)
        ib.append(1)
        wa.append(0.5)
        out.append(Vec3(0))

    print("twist°   LBS ring r (min..max)   motor ring r (min..max)")
    for step in range(5):
        var angle = Real(step) * 0.785398  # 0..180° in 45° steps
        var bone0 = Motor3.identity()
        var bone1 = Motor3.from_quat(Quat.from_axis_angle(Vec3(1, 0, 0), angle))

        var mats = [bone0.to_mat4(), bone1.to_mat4()]
        skin_lbs(mats, rest, ia, ib, wa, out)
        var rl = ring_radius(out)

        var bones = [bone0, bone1]
        skin_motor(bones, rest, ia, ib, wa, out)
        var rm = ring_radius(out)

        print(
            "  ", Int(angle * 57.29578 + 0.5), "     ",
            rl[0], "..", rl[1], "   ", rm[0], "..", rm[1],
        )
    print("(LBS pinches to 0 as the joint reaches 180°; the motor ring stays at 1)")
