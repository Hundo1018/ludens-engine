# tier: integration
"""Perception and EQS edge cases (ROADMAP 17.15).

Perception: field of view (in front / behind / 360 deg), range limit, team
filter, sight overrides hearing at the same tick, hearing range scale,
memory expiry, freshest-record choice, a ray count mismatch raises, bad
config raises. EQS: ring / grid generation, distance and facing scoring
order, filters, navmesh projection drops off-mesh points, external values
must match the point count, spacing 0 raises, an empty query returns nothing.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from ai.blackboard import Blackboard
from ai.perception import Perception, SenseConfig, SENSE_SIGHT, SENSE_HEARING
from ai.eqs import EnvQuery


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _all_visible(n: Int) -> List[Bool]:
    return List[Bool](length=n, fill=True)


def main() raises:
    var s = Suite("ai_perception")
    var p = Perception()
    var o = p.add_observer(_v(0, 0, 0), _v(1, 0, 0), 0, SenseConfig(10, 90, 2, 5, 1.6))
    var o360 = p.add_observer(_v(0, 0, 0), _v(1, 0, 0), 0, SenseConfig(10, 360, 1, 5, 1.6))
    var front = p.add_target(_v(5, 0, 1), 1)
    var behind = p.add_target(_v(-5, 0, 0), 1)
    var far = p.add_target(_v(15, 0, 0), 1)
    var friend = p.add_target(_v(3, 0, 0), 0)
    var n = p.sight_candidates()
    # o: front only; o360: front + behind; far out of range; friend same team
    s.eqi(n, 3, "candidates: cone, 360, range and team filters")
    p.commit_sight(_all_visible(n), 0)
    s.eqi(len(p.memory[o]), 1, "90 deg observer remembers only the target in front")
    s.eqi(len(p.memory[o360]), 2, "360 deg observer remembers both")
    _ = far
    _ = friend
    # hearing: radius 3 sound at 5 m: heard by o (scale 2 -> 6 m), not o360 (3 m)
    var heard = p.hear(_v(0, 0, 5), 3, 1, behind, 1)
    s.eqi(heard, 1, "hearing range = radius x hearing_scale")
    var bi = -1
    for i in range(len(p.memory[o])):
        if p.memory[o][i].target == behind:
            bi = i
    s.check(bi >= 0 and p.memory[o][bi].sense == SENSE_HEARING, "heard target remembered by sound")
    # same tick: a sighting overrides a hearing record, never the reverse
    _ = p.hear(_v(5, 0, 1), 10, 1, front, 2)
    _ = p.sight_candidates()
    p.commit_sight(_all_visible(len(p.ray_obs)), 2)
    var fi = -1
    for i in range(len(p.memory[o])):
        if p.memory[o][i].target == front:
            fi = i
    s.eqi(p.memory[o][fi].sense, SENSE_SIGHT, "sight overrides hearing on the same tick")
    s.eqi(p.memory[o][p.best_target(o)].target, front, "freshest record: the seen front target")
    # memory expiry (5 ticks)
    p.forget(7)
    s.eqi(len(p.memory[o]), 1, "the tick-1 hearing record expired, the tick-2 sighting stays")
    p.forget(8)
    s.eqi(len(p.memory[o]), 0, "everything expires")
    var bb = Blackboard(4)
    p.to_blackboard(o, 8, bb, 0, 1, 2, 3)
    s.check(not bb.flag(0) and not bb.has(1), "empty memory clears the blackboard keys")
    var raised = False
    try:
        _ = p.sight_candidates()
        p.commit_sight(List[Bool](), 9)
    except:
        raised = True
    s.check(raised, "answer count mismatch raises")
    raised = False
    try:
        _ = p.add_observer(_v(0, 0, 0), _v(1, 0, 0), 0, SenseConfig(-1, 90, 1, 5, 1.6))
    except:
        raised = True
    s.check(raised, "negative sight range raises")

    # ---- EQS ----
    var q = EnvQuery()
    q.ring(_v(0, 0, 0), 5, 8)
    s.eqi(len(q), 8, "ring of 8")
    q.distance_to(_v(5, 0, 0))
    var order = q.run()
    s.eqi(order[0], 0, "nearest ring point to (5, 0, 0) is index 0")
    var q2 = EnvQuery()
    q2.ring(_v(0, 0, 0), 5, 8)
    q2.facing(_v(0, 0, 0), _v(0, 0, 1), fmin=0.5)
    var o2 = q2.run()
    s.check(len(o2) == 3 and o2[0] == 2, "facing filter keeps the 3 points ahead; straight ahead first")
    var q3 = EnvQuery()
    q3.grid(_v(0, 0, 0), 2, 1)
    s.eqi(len(q3), 25, "grid half-extent 2, spacing 1: 5 x 5")
    var ext = List[Real]()
    for i in range(25):
        ext.append(Real(i))
    q3.external(ext^, prefer_low=False)
    s.eqi(q3.run()[0], 24, "external values score")
    raised = False
    try:
        var q4 = EnvQuery()
        q4.grid(_v(0, 0, 0), 2, 1)
        q4.external(List[Real](), 1)
    except:
        raised = True
    s.check(raised, "external value count mismatch raises")
    raised = False
    try:
        var q5 = EnvQuery()
        q5.grid(_v(0, 0, 0), 2, 0)
    except:
        raised = True
    s.check(raised, "spacing 0 raises")
    var empty = EnvQuery()
    s.eqi(len(empty.run()), 0, "empty query: no result")
    # navmesh projection: a 10 x 10 floor, grid half-extent 8 around (5, 0, 5)
    var v = List[Vec3]()
    var t = List[Int]()
    v.append(_v(0, 0, 0))
    v.append(_v(0, 0, 10))
    v.append(_v(10, 0, 0))
    v.append(_v(10, 0, 10))
    for k in [0, 1, 2, 2, 1, 3]:
        t.append(k)
    var mesh = bake_navmesh(v, t, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))
    var q6 = EnvQuery()
    q6.grid(_v(5, 0, 5), 8, 2)
    q6.project_to_navmesh(mesh)
    var o6 = q6.run()
    var ok = True
    for i in o6:
        if mesh.find_span(q6.pts[i]) < 0:
            ok = False
    s.check(len(o6) == 25 and ok, "projection keeps the 25 on-mesh points of 81")
    s.finish()
