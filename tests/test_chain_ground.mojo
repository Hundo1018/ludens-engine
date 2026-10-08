# tier: integration
"""Chain contact through `collision` (ROADMAP 17.0 F12).

`Chain.resolve_contacts` no longer knows what a floor is: it asks
`collision.world_query.nearest_surface` for the closest collider, its signed
distance and its push-out normal. These tests pin the three things the old
`floor_y` argument could not express: the slab helper's distance is exact, the
nearest of several colliders wins, and a contact on a CURVED collider is
pushed out along that collider's normal rather than along world +y. The last
section covers `Chain.set_base_motion`, the explicit way `FloatingChain`
moves the root (it used to write Chain's fields directly).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from collision.collider_set import ColliderSet, Pose3
from collision.world_query import QueryFilter, nearest_surface
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 240.0


def _identity_axes_pose(at: Vec3) -> Pose3:
    var ax = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
    ax[0] = Vec3(1, 0, 0, 0)
    ax[1] = Vec3(0, 1, 0, 0)
    ax[2] = Vec3(0, 0, 1, 0)
    return Pose3(at, ax^)


def _rod_chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1, 0),
                Vec3(0, -1, 0, 0),
                Vec3(0, -0.5, 0, 0),
                1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0, 0),
            )
        )
    return c^


def _zero1() -> List[Real]:
    var t = List[Real]()
    t.append(0)
    return t^


def main() raises:
    var s = Suite("chain_ground")

    # ---- slab helper: distance to the top face is p.y - top, exactly ----
    var cs = ColliderSet()
    var slab = cs.add_ground_slab(-1.6)
    var poses = List[Pose3]()
    poses.append(slab[1].copy())
    s.eqi(slab[0], 0, "slab is collider 0")
    var f_all = QueryFilter.all()
    var above = nearest_surface(cs, poses, Vec3(3, -1.5, -2, 0), f_all)
    var inside = nearest_surface(cs, poses, Vec3(3, -1.62, -2, 0), f_all)
    s.check(above[1].dist == Real(-1.5) - Real(-1.6), "distance above the slab is p.y - top")
    s.check(inside[1].dist == Real(-1.62) - Real(-1.6), "depth inside the slab is top - p.y")
    s.check(inside[1].dist < 0 and inside[1].normal[1] == 1, "inside: negative, normal +y")
    var empty = ColliderSet()
    var none = nearest_surface(empty, List[Pose3](), Vec3(0, 0, 0, 0), f_all)
    s.eqi(none[0], -1, "no colliders: index -1")

    # ---- nearest of several, and the filter's ignore ----
    var two = ColliderSet()
    var floor = two.add_ground_slab(0.0)
    _ = two.add_sphere(0.5)
    var two_poses = List[Pose3]()
    two_poses.append(floor[1].copy())
    two_poses.append(_identity_axes_pose(Vec3(0, 2, 0, 0)))
    var p = Vec3(0, 1.2, 0, 0)  # 1.2 above the floor, 0.7 below the ball's centre
    var near = nearest_surface(two, two_poses, p, f_all)
    s.eqi(near[0], 1, "the sphere (0.2 away) beats the floor (1.2 away)")
    var skip = nearest_surface(two, two_poses, p, QueryFilter.ignoring(1))
    s.eqi(skip[0], 0, "ignoring the sphere leaves the floor")

    # ---- a chain tip resting on a sphere is pushed out along its normal ----
    # The joint sits at (0, -1); swung 0.6 rad, the rod's tip is at about
    # (0.565, -1.825). A radius-0.5 sphere centred at (0.2, -1.8) contains it,
    # and the tip lies almost level with the centre, so the push-out is
    # nearly horizontal.
    var bs = ColliderSet()
    _ = bs.add_sphere(0.5)
    var bposes = List[Pose3]()
    bposes.append(_identity_axes_pose(Vec3(0.2, -1.8, 0, 0)))
    var c = _rod_chain(1)
    c.q[0] = 0.6
    var tip = Vec3(0, -1, 0, 0)
    var pts = List[Int]()
    var locs = List[Vec3]()
    pts.append(0)
    locs.append(tip)
    var pw0 = c.point_world(0, tip)
    var d0 = nearest_surface(bs, bposes, pw0, f_all)[1]
    s.check(d0.dist < 0, "the swung tip starts inside the sphere")
    s.check(abs(d0.normal[0]) > 0.2, "the push-out normal is not vertical")
    var n_act = c.resolve_contacts(bs, bposes, 0.0, pts, locs, DT)
    s.eqi(n_act, 1, "one contact active on entry")
    var worst = Real(0)
    for _ in range(240):
        c.step(DT, _zero1(), G)
        _ = c.resolve_contacts(bs, bposes, 0.0, pts, locs, DT)
        var d = nearest_surface(bs, bposes, c.point_world(0, tip), f_all)[1].dist
        if -d > worst:
            worst = -d
    s.check(worst < 0.05, "tip stays out of the sphere while it swings against it")

    # ---- set_base_motion: a base accelerating at +g cancels gravity ----
    var free = _rod_chain(1)
    free.q[0] = 0.5
    var tau = _zero1()
    var with_g = free.dynamics(tau, G)
    s.check(abs(with_g[0]) > 1.0, "swung rod falls under gravity")
    free.set_base_motion(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), G)
    var in_freefall = free.dynamics(tau, G)
    s.check(abs(in_freefall[0]) < 1e-5, "base in free fall: no gravity torque on the joint")
    free.set_base_motion(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var back = free.dynamics(tau, G)
    s.check(back[0] == with_g[0], "zero base motion restores the fixed-base answer exactly")

    s.finish()
