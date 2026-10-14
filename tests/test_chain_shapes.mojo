# tier: integration
"""Link shapes and self-collision for reduced-coordinate chains (ROADMAP
17.51, `physics.chain_shapes`).

  1. Ordinary: a 1 m arm (capsule radius 0.05) swinging down from near
     horizontal onto a ledge under its middle comes to rest on the ledge
     (the centreline 0.05 from the ledge's far top edge); with only the
     tip as a contact point it swings straight past the ledge.
  2. Integration: a 3-link chain folded back on itself without gravity,
     its third link spinning toward the first: with self-collision the two
     capsules never get closer than their radii (to 5 mm); without it they
     pass through each other.
  3. Extreme: a link and its parent are never tested against each other
     (no contact at their shared joint); no shapes = nothing to do.
"""

from std.math import atan2
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.chain import Chain, ChainLink
from physics.chain_shapes import LinkCapsule, resolve_shape_contacts
from collision.collider_set import ColliderSet, Pose3

comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime ROD_I = Vec3(1.0 / 12.0, 1e-3, 1.0 / 12.0, 0)


def _seg_dist(a0: Vec3, a1: Vec3, b0: Vec3, b1: Vec3) -> Real:
    """Brute-force minimum distance of two segments (100 x 100 samples)."""
    var best = Real(1e9)
    for i in range(101):
        var p = a0 + (a1 - a0) * (Real(i) / 100)
        for j in range(101):
            var q = b0 + (b1 - b0) * (Real(j) / 100)
            best = min(best, length(p - q))
    return best


def main() raises:
    var s = Suite("chain_shapes")

    # ---- arm onto a ledge -----------------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0.5, 0.5, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.5)), Vec3(0.05, 0.05, 0.5, 0), True)
    var poses = sc.query_poses()
    var shape_q = Real(0)
    var point_min = Real(9)
    for mode in range(2):
        var arm = Chain()
        arm.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 1, 0, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I))
        arm.q[0] = 1.5
        var caps = List[LinkCapsule]()
        caps.append(LinkCapsule(0, ZERO, Vec3(0, -1, 0, 0), 0.05))
        var pts = List[Int]()
        pts.append(0)
        var locs = List[Vec3]()
        locs.append(Vec3(0, -1, 0, 0))
        var z1 = List[Real](length=1, fill=0)
        for _ in range(480):
            arm.step(DT, z1, G)
            if mode == 0:
                _ = resolve_shape_contacts(arm, sc.colliders, poses, caps, DT)
            else:
                _ = arm.resolve_contacts(sc.colliders, poses, 0.0, pts, locs, DT)
                point_min = min(point_min, arm.q[0])
        if mode == 0:
            shape_q = arm.q[0]
    # rest: turning down from horizontal, the arm's line is lowest at the
    # ledge's FAR top edge, so it rests on (0.55, 0.55) at distance 0.05
    var c = Chain()
    c.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, 1, 0, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I))
    c.q[0] = shape_q
    var tip = c.point_world(0, Vec3(0, -1, 0, 0))
    var dir = (tip - Vec3(0, 1, 0, 0)) / length(tip - Vec3(0, 1, 0, 0))
    var corner = Vec3(0.55, 0.55, 0, 0)
    var rel = corner - Vec3(0, 1, 0, 0)
    var along = rel[0] * dir[0] + rel[1] * dir[1]
    var gap = length(rel - dir * along)
    print("  arm on a ledge, 2 s: capsule rest angle", shape_q, " centreline to the ledge corner", gap, "(radius 0.05);  tip-point contact: smallest angle", point_min)
    s.check(abs(gap - 0.05) < 0.005 and shape_q > 0.5, "the capsule arm rests on the ledge at its radius")
    s.check(point_min < 0, "with only the tip as a contact point the arm swings past the ledge")

    # ---- self-collision -------------------------------------------------------------------------------------
    var empty = ColliderSet()
    var none = List[Pose3]()
    var dmin = List[Real]()
    for mode in range(2):
        var ch = Chain()
        for _ in range(3):
            ch.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), ZERO if len(ch.links) == 0 else Vec3(0, -1, 0, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I))
        ch.q[1] = 2.6
        ch.q[2] = 1.6
        ch.qd[2] = 2
        var caps = List[LinkCapsule]()
        for k in range(3):
            caps.append(LinkCapsule(k, ZERO, Vec3(0, -1, 0, 0), 0.05))
        var z3 = List[Real](length=3, fill=0)
        var d = Real(9)
        for _ in range(480):
            ch.step(DT, z3, ZERO)
            _ = resolve_shape_contacts(ch, empty, none, caps, DT, mode == 0)
            var a0 = ch.point_world(0, ZERO)
            var a1 = ch.point_world(0, Vec3(0, -1, 0, 0))
            var b0 = ch.point_world(2, ZERO)
            var b1 = ch.point_world(2, Vec3(0, -1, 0, 0))
            d = min(d, _seg_dist(a0, a1, b0, b1))
        dmin.append(d)
    print("  folded 3-link chain, third link spinning into the first, 2 s: closest centrelines with self-collision", dmin[0], ", without", dmin[1], "(radii sum 0.1)")
    s.check(dmin[0] > 0.095 and dmin[1] < 0.02, "self-collision keeps the capsules apart; without it they pass through")

    # ---- extremes -----------------------------------------------------------------------------------------------
    var adj = Chain()
    adj.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), ZERO, Vec3(0, -0.5, 0, 0), 1, ROD_I))
    adj.add_link(ChainLink.revolute(Vec3(0, 0, 1, 0), Vec3(0, -1, 0, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I))
    var ac = List[LinkCapsule]()
    ac.append(LinkCapsule(0, ZERO, Vec3(0, -1, 0, 0), 0.05))
    ac.append(LinkCapsule(1, ZERO, Vec3(0, -1, 0, 0), 0.05))
    var n_adj = resolve_shape_contacts(adj, empty, none, ac, DT)
    var n_none = resolve_shape_contacts(adj, empty, none, List[LinkCapsule](), DT)
    s.check(n_adj == 0 and n_none == 0, "parent and child are not tested against each other; no shapes, nothing")
    s.finish()
