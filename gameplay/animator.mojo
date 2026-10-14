"""Animators in the runtime (ROADMAP 17.64): the `procedural.anim_state`
graph assembled with the ECS world, the event channel and the physics
body of an entity.

An entity carries `AnimatorRef[ID]` (a slot in an `Animators` table: the
graph is not implicitly copyable, so it lives beside the world, as bodies
live in the scene behind `RigidBodyRef`). `tick_animators` advances every
animator by dt and, per entity:

  * writes the pose into the table (`pos` / `rot`, 3 and 4 reals a bone);
  * sends each clip event fired this tick to an `AnimEvent` channel, tagged
    with the entity;
  * with root motion on and a `RigidBodyRef`, turns the root bone's
    displacement over the tick (`root_motion`, across loop wraps, rotated
    into the body's frame) into the body's horizontal velocity -- the
    physics moves the character, so it still collides -- and strips the
    root's horizontal translation from the pose.
"""

from geometry.vec import Real, Vec3
from ecs.storage import StorageBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from physics.rigid6 import Body6
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack
from procedural.anim_state import AnimGraph
from procedural.anim_graph import root_motion
from scheduler.events import Channel
from .runtime import Runtime, RigidBodyRef


@fieldwise_init
struct AnimatorRef[AID: Int](ComponentType):
    """Slot of an entity's animator in `Animators` (component id `AID`)."""

    comptime ID: Int = Self.AID
    var slot: Int


@fieldwise_init
struct AnimEvent(Copyable, ImplicitlyCopyable, Movable):
    var entity: Entity
    var id: Int


struct AnimLibrary(Movable):
    """Clips and their event tracks (track k belongs to clip k)."""

    var clips: List[AnimClip]
    var tracks: List[EventTrack]

    def __init__(out self):
        self.clips = List[AnimClip]()
        self.tracks = List[EventTrack]()

    def add(mut self, var clip: AnimClip, var track: EventTrack) -> Int:
        self.clips.append(clip^)
        self.tracks.append(track^)
        return len(self.clips) - 1


struct Animators(Movable):
    var graphs: List[AnimGraph]
    var pos: List[List[Real]]
    var rot: List[List[Real]]
    var root: List[Int]  # root bone, -1 = no root motion
    var last_motion: List[Vec3]  # root displacement of the last tick (world)

    def __init__(out self):
        self.graphs = List[AnimGraph]()
        self.pos = List[List[Real]]()
        self.rot = List[List[Real]]()
        self.root = List[Int]()
        self.last_motion = List[Vec3]()

    def add(mut self, var graph: AnimGraph, root: Int = -1) raises -> Int:
        """A new animator; `root` >= 0 turns on root motion from that bone."""
        if root >= graph.bones:
            raise Error("Animators.add: root bone out of range")
        var n = graph.bones
        self.graphs.append(graph^)
        self.pos.append(List[Real](length=3 * n, fill=0))
        self.rot.append(List[Real](length=4 * n, fill=0))
        self.root.append(root)
        self.last_motion.append(Vec3(0, 0, 0, 0))
        return len(self.graphs) - 1


def tick_animators[B: StorageBackend, Body: Body6, AID: Int](
    mut rt: Runtime[B, Body],
    mut anims: Animators,
    lib: AnimLibrary,
    dt: Real,
    mut events: Channel[AnimEvent],
) raises:
    """Advance every entity's animator by `dt` (module docstring)."""
    var es = rt.world.query1[AnimatorRef[AID]]()
    var fired = List[Int]()
    for e in es:
        var k = rt.world.get[AnimatorRef[AID]](e).slot
        if k < 0 or k >= len(anims.graphs):
            raise Error("tick_animators: animator slot out of range")
        var state0 = anims.graphs[k].current
        var t0 = anims.graphs[k].time
        fired.clear()
        anims.graphs[k].tick(dt, lib.clips, lib.tracks, anims.pos[k], anims.rot[k], fired)
        for id in fired:
            events.send(AnimEvent(e, id))
        var root = anims.root[k]
        if root < 0 or not rt.world.has[RigidBodyRef](e):
            continue
        var cur = anims.graphs[k].current
        var t1 = anims.graphs[k].time
        var clip = anims.graphs[k].states[cur].clip
        var d = root_motion(lib.clips[clip], root, t0 if cur == state0 else Real(0), t1)
        var id = rt.world.get[RigidBodyRef](e).id
        var q = rt.scene.pose(id).rot
        var dw = q.rotate(d)
        anims.last_motion[k] = dw
        var v = rt.scene.velocity(id)
        rt.scene.set_velocity(id, Vec3(dw[0] / dt, v[1], dw[2] / dt, 0), rt.scene.angular_velocity(id))
        # the body carries the character: no horizontal root translation in the pose
        anims.pos[k][3 * root] = 0
        anims.pos[k][3 * root + 2] = 0
