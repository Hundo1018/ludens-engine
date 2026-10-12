# tier: integration
"""AI end to end (ROADMAP 17.15): perception -> blackboard -> behavior tree,
with line of sight from the physics world and search points from EQS.

Scene: a 30 x 20 m floor with a wall (physics box + the same geometry baked
into a navmesh). A guard at (5, 0, 10) faces +x; an intruder walks a scripted
route: hidden behind the wall, out into view, back behind the wall, gone.
Each tick: `Perception.sight_candidates` -> one `ContactScene6.ray_cast` per
candidate (blocked when it hits something before the target) ->
`commit_sight` -> `to_blackboard` -> the guard BT decides.

Laws: the guard patrols while the intruder is hidden, chases while it is
seen, searches after it disappears behind the wall and returns to patrol
when the memory expires; a sound wakes a guard that cannot see. EQS picks a
search point that is on the navmesh, reachable, near the last known position
and hidden from it-- not inside the wall. A dead target is forgotten.
"""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from ai.blackboard import Blackboard, CMP_TRUE, CMP_SET, CMP_LT
from ai.bt import BehaviorTree
from ai.decision import BtDecider
from ai.perception import Perception, SenseConfig
from ai.eqs import EnvQuery

comptime ALL = QueryFilter(0xFFFFFFFF, -1, False)
comptime K_VIS = 0
comptime K_POS = 1
comptime K_DIST = 2
comptime K_AGE = 3
comptime PATROL = 0
comptime CHASE = 1
comptime SEARCH = 2


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _len(v: Vec3) -> Real:
    return sqrt(dot(v, v))


def _quad(mut v: List[Vec3], mut t: List[Int], x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
    var n = len(v)
    v.append(_v(x0, y, z0))
    v.append(_v(x0, y, z1))
    v.append(_v(x1, y, z0))
    v.append(_v(x1, y, z1))
    for k in [0, 1, 2, 2, 1, 3]:
        t.append(n + k)


def _box_tris(mut v: List[Vec3], mut t: List[Int], lo: Vec3, hi: Vec3):
    var n = len(v)
    for c in range(8):
        v.append(_v(hi[0] if c & 1 else lo[0], hi[1] if c & 2 else lo[1], hi[2] if c & 4 else lo[2]))
    var f = [2, 6, 3, 3, 6, 7, 0, 2, 4, 4, 2, 6, 1, 5, 3, 3, 5, 7, 0, 1, 2, 1, 3, 2, 4, 6, 5, 5, 6, 7]
    for k in range(len(f)):
        t.append(n + f[k])


def guard_tree() raises -> BtDecider:
    var t = BehaviorTree()
    var root = t.selector(reactive=True)
    var chase = t.sequence(reactive=True)
    t.add_child(root, chase)
    t.add_child(chase, t.condition(K_VIS, CMP_TRUE))
    t.add_child(chase, t.action(CHASE))
    var search = t.sequence(reactive=True)
    t.add_child(root, search)
    t.add_child(search, t.condition(K_POS, CMP_SET))
    t.add_child(search, t.action(SEARCH))
    t.add_child(root, t.action(PATROL))
    return BtDecider(t^)


def main() raises:
    var s = Suite("ai_world")
    # physics world: floor slab + wall at x 14.5..15.5, z 4..16, 3 m tall
    var world = ContactScene6[QuatBody6]()
    _ = world.add(QuatBody6.at_rest(_v(15, -0.5, 10), Inertia3.box(1, 15, 0.5, 10)), _v(15, 0.5, 10), True)
    _ = world.add(QuatBody6.at_rest(_v(15, 1.5, 10), Inertia3.box(1, 0.5, 1.5, 6)), _v(0.5, 1.5, 6), True)
    # the same level for the navmesh
    var v = List[Vec3]()
    var tr = List[Int]()
    _quad(v, tr, 0, 0, 30, 20, 0)
    _box_tris(v, tr, _v(14.5, 0, 4), _v(15.5, 3, 16))
    var mesh = bake_navmesh(v, tr, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))

    var per = Perception()
    var cfg = SenseConfig(25, 160, 1, 90, 1.6)
    var guard = per.add_observer(_v(5, 0, 10), _v(1, 0, 0), 0, cfg)
    var intruder = per.add_target(_v(20, 0, 10), 1)
    var bt = guard_tree()
    var bb = Blackboard(4)
    var actions = List[Int]()
    var rays = 0
    for tick in range(400):
        # scripted route: behind the wall (x 20) -> out at z 18 -> back -> gone
        var p: Vec3
        if tick < 60:
            p = _v(20, 0, 10)
        elif tick < 120:
            p = _v(20, 0, 10 + Real(tick - 60) * 0.2)  # walks north; in view once the line clears the wall end
        elif tick < 180:
            p = _v(20, 0, 22)
        else:
            p = _v(20, 0, 10)  # teleports back behind the wall
        per.set_target(intruder, p)
        var n = per.sight_candidates()
        var vis = List[Bool]()
        for i in range(n):
            var a = per.ray_from[i]
            var b = per.ray_to[i]
            var d = b - a
            var l = _len(d)
            var h = world.ray_cast(a, d / l, l, ALL)
            vis.append(not h.hit)
            rays += 1
        per.commit_sight(vis, tick)
        per.forget(tick)
        per.to_blackboard(guard, tick, bb, K_VIS, K_POS, K_DIST, K_AGE)
        actions.append(bt.decide(0, bb))
    s.check(rays > 300, "sight rays were cast every tick")
    s.eqi(actions[30], PATROL, "intruder behind the wall: patrol")
    var first_chase = -1
    for i in range(len(actions)):
        if actions[i] == CHASE:
            first_chase = i
            break
    s.check(first_chase > 60 and first_chase < 120, "chase starts once the intruder clears the wall (tick " + String(first_chase) + ")")
    s.eqi(actions[150], CHASE, "chase while in view")
    s.eqi(actions[200], SEARCH, "lost behind the wall: search")
    s.eqi(actions[275], PATROL, "memory expired (90 ticks): patrol")

    # hearing wakes a guard that cannot see
    var heard = per.hear(_v(20, 0, 10), 18, 1, intruder, 400)
    s.eqi(heard, 1, "the guard hears the noise through the wall")
    per.to_blackboard(guard, 400, bb, K_VIS, K_POS, K_DIST, K_AGE)
    s.check(not bb.flag(K_VIS) and bb.has(K_POS), "heard, not seen: last known position only")
    s.eqi(bt.decide(0, bb), SEARCH, "and the guard goes to search")

    # EQS: a search point near the last known position, on the navmesh,
    # reachable from the guard, hidden from the last known position
    var lkp = bb.get_vec(K_POS)
    var q = EnvQuery()
    q.grid(lkp, 6, 1)
    q.project_to_navmesh(mesh)
    q.path_length(mesh, _v(5, 0, 10), weight=0.5)
    q.distance_to(lkp, weight=1)
    var order = q.run()
    s.check(len(order) > 0, "EQS found candidate points")
    var best = q.pts[order[0]]
    s.check(mesh.find_span(best) >= 0, "best point is on the navmesh")
    s.check(not (best[0] > 14.25 and best[0] < 15.75 and best[2] > 3.75 and best[2] < 16.25), "not inside the wall")
    s.check(_len(best - lkp) <= 1.5, "close to the last known position")

    # a dead target is forgotten
    per.remove_target(intruder)
    per.to_blackboard(guard, 401, bb, K_VIS, K_POS, K_DIST, K_AGE)
    s.check(not bb.has(K_POS), "removed target: memory cleared")
    s.eqi(bt.decide(0, bb), PATROL, "back to patrol")
    s.finish()
