# tier: system
"""Animators in the runtime (ROADMAP 17.64, `gameplay.animator`).

  1. Ordinary: a walk clip whose root bone moves 1 m per 1 s loop drives a
     character box (frictionless floor) by root motion: after 3 s of
     60 Hz frames the box has walked 3 m (2 %), and the pose's root has no
     horizontal translation; a footstep event at 0.5 s of the loop reaches
     the channel 3 times, tagged with the entity.
  2. Integration: the box turned 90 degrees about y walks along -z instead
     (root motion in the body frame); an entity without a body still
     animates and sends events but nothing moves; two animators share the
     library and keep separate clocks (the second at speed 2 fires twice
     as often).
  3. Extreme: an animator slot out of range raises; a root bone past the
     skeleton raises at `add`.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from ecs.entity import Entity
from physics.rigid6 import QuatBody6, Inertia3
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack
from procedural.anim_state import AnimGraph
from scheduler.events import Channel
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.animator import AnimatorRef, AnimEvent, AnimLibrary, Animators, tick_animators

comptime DT: Real = 1.0 / 60.0
comptime AR = AnimatorRef[3]
comptime Rt = Runtime[SparseSetBackend[Transform, RigidBodyRef, AR], QuatBody6]


def _walk() raises -> AnimClip:
    var c = AnimClip(2, 11, 10, True)
    for f in range(11):
        var u = Real(f) / 10
        c.set_key(f, 0, Vec3(u, 0.9, 0, 0), Quat(0, 0, 0, 1))
        c.set_key(f, 1, Vec3(0, 0.5, 0, 0), Quat(0, 0, 0, 1))
    return c^


def _lib() raises -> AnimLibrary:
    var lib = AnimLibrary()
    var tr = EventTrack()
    tr.add(0.5, 7)
    _ = lib.add(_walk(), tr^)
    return lib^


def _graph(speed: Real) -> AnimGraph:
    var g = AnimGraph(2)
    _ = g.add_state(0, speed)
    return g^


def _world(mut rt: Rt, yaw: Real) raises -> Entity:
    var f = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    rt.scene.set_friction(rt.body_of(f).index(), 0)
    var b = QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.box(70, 0.3, 0.5, 0.3))
    b.q = Quat.from_axis_angle(Vec3(0, 1, 0, 0), yaw)
    var e = rt.spawn_body(b^, Vec3(0.3, 0.5, 0.3, 0), False)
    rt.scene.set_friction(rt.body_of(e).index(), 0)
    rt.scene.set_sleep_thresholds(rt.body_of(e), 0, 0)
    return e


def _run(yaw: Real) raises -> Tuple[Vec3, Int, Int, Real]:
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0))
    var e = _world(rt, yaw)
    var lib = _lib()
    var an = Animators()
    var k = an.add(_graph(1), 0)
    rt.world.set(e, AR(k))
    var ch = Channel[AnimEvent]()
    var rd = ch.register_reader()
    var got = List[AnimEvent]()
    for _ in range(180):
        tick_animators[AID=3](rt, an, lib, DT, ch)
        _ = rt.advance(Float64(DT))
        ch.read(rd, got)
    var tagged = 0
    for ev in got:
        if ev.entity == e and ev.id == 7:
            tagged += 1
    var p = rt.scene.pose(rt.body_of(e)).pos
    return (p, len(got), tagged, an.pos[k][0])


def main() raises:
    var s = Suite("animator")
    var r = _run(0)
    print("  walk clip, 3 s: box at x", r[0][0], "z", r[0][2], " events", r[1], "(tagged", r[2], ") root x in pose", r[3])
    s.check(abs(r[0][0] - 3) < 0.06 and abs(r[0][2]) < 1e-3, "root motion walks the box 3 m in 3 s (2 %)")
    s.check(r[3] == 0, "the pose's root carries no horizontal translation")
    s.check(r[1] == 3 and r[2] == 3, "the 0.5 s footstep reaches the channel 3 times, tagged with the entity")

    var t = _run(Real(pi) / 2)
    print("  turned 90 deg about y: box at x", t[0][0], "z", t[0][2])
    s.check(abs(t[0][2] + 3) < 0.06 and abs(t[0][0]) < 0.01, "root motion is in the body's frame (walks along -z)")

    # no body; two clocks
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0))
    var lib = _lib()
    var an = Animators()
    var a = rt.world.spawn()
    var b = rt.world.spawn()
    rt.world.set(a, AR(an.add(_graph(1), 0)))
    rt.world.set(b, AR(an.add(_graph(2), -1)))
    var ch = Channel[AnimEvent]()
    var rd = ch.register_reader()
    var got = List[AnimEvent]()
    for _ in range(120):
        tick_animators[AID=3](rt, an, lib, DT, ch)
        _ = rt.advance(Float64(DT))
        ch.read(rd, got)
    var na = 0
    var nb = 0
    for ev in got:
        if ev.entity == a:
            na += 1
        elif ev.entity == b:
            nb += 1
    print("  two animators without bodies, 2 s: events speed 1", na, " speed 2", nb)
    s.check(na == 2 and nb == 4 and len(rt.scene.bset.bodies) == 0, "separate clocks; no body, nothing moved")

    var raised = 0
    rt.world.set(a, AR(9))
    try:
        tick_animators[AID=3](rt, an, lib, DT, ch)
    except:
        raised += 1
    try:
        _ = an.add(_graph(1), 5)
    except:
        raised += 1
    s.check(raised == 2, "a bad slot and a root past the skeleton raise")
    s.finish()
