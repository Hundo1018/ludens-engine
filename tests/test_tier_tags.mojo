# tier: system
"""ECS tier tags (ROADMAP 17.85, `Tier[N, BASE]` and
`Runtime.sync_tier_tags`).

  1. Ordinary: 30 balls on a floor along x = 0 .. 58, three tiers by
     distance to an observer at the origin (8 m / 20 m): after a tiered
     frame and the sync, every body entity carries exactly one tag, the one
     of its scene tier, and `query1[Tier[0]]` returns exactly the tier-0
     bodies.
  2. Integration: the observer moves to x = 60; after the next frame the
     tags follow (the far end is now tier 0, the origin end tier 2), on the
     sparse-set and the archetype backend alike; a `select` without
     `Tier[0]` returns the rest.
  3. Extreme: a body outside the plan (spawned after it) counts as tier 0;
     a second sync with nothing changed writes nothing (same tags).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.storage import StorageBackend, Filter
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.transform import Transform
from ecs.entity import Entity
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.tiers import DistanceTiers, Tier

comptime DT: Real = 1.0 / 60.0
comptime T0 = Tier[0, 8]
comptime T1 = Tier[1, 8]
comptime T2 = Tier[2, 8]


def _setup[B: StorageBackend](mut rt: Runtime[B, QuatBody6]) raises -> List[Entity]:
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(30, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 5)), Vec3(50, 0.5, 5, 0), True)
    var es = List[Entity]()
    for k in range(30):
        es.append(rt.spawn_sphere(QuatBody6.at_rest(Vec3(Real(k) * 2, 0.5, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False))
    var it: List[Int] = [4, 4, 2]
    var su: List[Int] = [4, 2, 1]
    var pe: List[Int] = [1, 2, 4]
    rt.scene.set_tier_table(it, su, pe)
    return es^


def _consistent[B: StorageBackend](rt: Runtime[B, QuatBody6]) -> Bool:
    var es = rt.world.query1[RigidBodyRef]()
    for e in es:
        var slot = rt.world.get[RigidBodyRef](e).id.index()
        var t = rt.scene.tier_of[slot] if slot < len(rt.scene.tier_of) else 0
        var n = Int(rt.world.has[T0](e)) + Int(rt.world.has[T1](e)) + Int(rt.world.has[T2](e))
        if n != 1:
            return False
        if (t == 0 and not rt.world.has[T0](e)) or (t == 1 and not rt.world.has[T1](e)) or (t == 2 and not rt.world.has[T2](e)):
            return False
    return True


def _count0[B: StorageBackend](rt: Runtime[B, QuatBody6]) -> Int:
    var n = 0
    for t in rt.scene.tier_of:
        if t == 0:
            n += 1
    return n


def _run[B: StorageBackend](name: String, mut s: Suite) raises:
    var rt = Runtime[B, QuatBody6](DT, Vec3(0, -9.8, 0, 0))
    var es = _setup(rt)
    var radii: List[Real] = [8, 20]
    var pol = DistanceTiers(radii^, 1)
    var obs: List[Vec3] = [Vec3(0, 0, 0, 0)]
    _ = rt.advance_tiered(Float64(DT), pol, obs)
    rt.sync_tier_tags[3, 8]()
    var near = len(rt.world.query1[T0]())
    print("  " + name + ": observer at 0: tier-0 tags", near, " scene tier-0 bodies", _count0(rt), " ball 0 tier 0", rt.world.has[T0](es[0]), " ball 29 tier 2", rt.world.has[T2](es[29]))
    s.check(_consistent(rt) and near == _count0(rt) and rt.world.has[T0](es[0]) and rt.world.has[T2](es[29]), name + ": one tag per body, the scene's tier")

    obs[0] = Vec3(60, 0, 0, 0)
    _ = rt.advance_tiered(Float64(DT), pol, obs)
    rt.sync_tier_tags[3, 8]()
    var rest = rt.world.select(Filter().with_[RigidBodyRef]().without[T0]())
    print("  " + name + ": observer at 60: ball 0 tier 2", rt.world.has[T2](es[0]), " ball 29 tier 0", rt.world.has[T0](es[29]), " without Tier[0]", len(rest), "of", len(rt.world.query1[RigidBodyRef]()))
    s.check(_consistent(rt) and rt.world.has[T2](es[0]) and rt.world.has[T0](es[29]), name + ": tags follow the observer")
    s.check(len(rest) + len(rt.world.query1[T0]()) == len(rt.world.query1[RigidBodyRef]()), name + ": select without Tier[0] is the rest")

    var late = rt.spawn_sphere(QuatBody6.at_rest(Vec3(100, 0.5, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    rt.sync_tier_tags[3, 8]()
    var before = len(rt.world.query1[T0]())
    rt.sync_tier_tags[3, 8]()
    s.check(rt.world.has[T0](late) and len(rt.world.query1[T0]()) == before and _consistent(rt), name + ": a body outside the plan is tier 0; a repeated sync changes nothing")


def main() raises:
    var s = Suite("tier_tags")
    _run[SparseSetBackend[Transform, RigidBodyRef, T0, T1, T2]]("sparse-set", s)
    _run[ArchetypeBackend[Transform, RigidBodyRef, T0, T1, T2]]("archetype", s)
    s.finish()
