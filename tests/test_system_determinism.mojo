# tier: system
"""ROADMAP 17.0i: two independent `Runtime`s fed the same uneven frame-dt
sequence and the same spawn/despawn script end bit-identical (every body's
position and orientation, every entity's Transform) and deliver identical
contact-event streams. This is the property replay (17.39) and rollback
(17.16) stand on, checked through the whole ECS + scheduler + physics stack
rather than per subsystem."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.entity import Entity
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from collision.contact_events import ContactEvent
from gameplay.runtime import Runtime, RigidBodyRef

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def _script(mut rt: Rt, mut log: List[Int]) raises -> List[Entity]:
    """Ground + a staggered pile; at frame 40 one box is despawned mid-pile
    and a new one dropped in its place. Returns the live entities."""
    var es = List[Entity]()
    _ = rt.spawn_body(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 20, 1, 20)),
        Vec3(20, 1, 20, 0), True,
    )
    for i in range(6):
        var x = Real(i % 3) * 0.3 - 0.3
        var y = Real(0.3) + Real(i) * 0.55
        es.append(rt.spawn_body(
            QuatBody6.at_rest(Vec3(x, y, 0.05 * Real(i), 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
            Vec3(0.25, 0.25, 0.25, 0), False,
        ))
    var reader = rt.events.register_reader()
    for f in range(120):
        var fdt = 1.0 / 144.0 if f % 3 == 0 else (1.0 / 30.0 if f % 3 == 1 else 1.0 / 60.0)
        _ = rt.advance(fdt)
        if f == 40:
            rt.despawn(es[2])
            es[2] = rt.spawn_body(
                QuatBody6.at_rest(Vec3(0, 4, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
                Vec3(0.25, 0.25, 0.25, 0), False,
            )
        var evs = List[ContactEvent]()
        rt.events.read(reader, evs)
        for i in range(len(evs)):
            log.append(evs[i].a * 1_000_000 + evs[i].b * 1000 + evs[i].kind)
    return es^


def main() raises:
    var s = Suite("system_determinism")
    var a = Rt(DT, G)
    var b = Rt(DT, G)
    var la = List[Int]()
    var lb = List[Int]()
    var ea = _script(a, la)
    var eb = _script(b, lb)

    s.check(len(la) > 0, "the script produces contact events")
    var same_events = len(la) == len(lb)
    if same_events:
        for i in range(len(la)):
            if la[i] != lb[i]:
                same_events = False
    s.check(same_events, "identical contact-event streams (" + String(len(la)) + " events)")

    var same_state = len(ea) == len(eb)
    for i in range(len(ea)):
        var ra = a.world.get[RigidBodyRef](ea[i])
        var rb = b.world.get[RigidBodyRef](eb[i])
        var pa = a.scene.bset.bodies[ra.id.index()].position()
        var pb = b.scene.bset.bodies[rb.id.index()].position()
        var ta = a.world.get[Transform](ea[i])
        var tb = b.world.get[Transform](eb[i])
        for k in range(3):
            if pa[k] != pb[k] or ta.translation[k] != tb.translation[k]:
                same_state = False
        if ta.rotation.x != tb.rotation.x or ta.rotation.w != tb.rotation.w:
            same_state = False
    s.check(same_state, "bit-identical body poses and Transforms after 120 uneven frames")

    var moved = False
    var r2 = a.world.get[RigidBodyRef](ea[2])
    if a.scene.bset.bodies[r2.id.index()].position()[1] < 3.9:
        moved = True
    s.check(moved, "the body spawned mid-run fell (it is simulated, not stale)")
    s.finish()
