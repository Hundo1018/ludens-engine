"""Deferred component set gates (ROADMAP 4.4): value parity with immediate
writes, exact recording-order replay across types, iteration-safety, and
drop-if-despawned semantics."""

from harness.runner import Suite
from ecs.world import World
from ecs.component import ComponentType
from ecs.commands import SetBuffer
from ecs.sparse_backend import SparseSetBackend


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Velocity(ComponentType):
    comptime ID: Int = 1
    var dx: Int
    var dy: Int


comptime SB = SparseSetBackend[Position, Velocity]


def main() raises:
    var s = Suite("deferred_set")

    # 1. Per-value parity: the same interleaved writes, once direct and once
    #    deferred through the buffer, land identical component values.
    var wd = World[SB]()
    var wf = World[SB]()
    var buf = SetBuffer[Position, Velocity]()
    var ed = List[type_of(wd.spawn())]()
    var ef = List[type_of(wf.spawn())]()
    for i in range(8):
        ed.append(wd.spawn1(Position(i, i)))
        ef.append(wf.spawn1(Position(i, i)))
    for i in range(8):
        # interleave types on purpose: order log must preserve this
        wd.set(ed[i], Velocity(i * 2, -i))
        wd.set(ed[i], Position(i * 10, i))
        buf.set(ef[i], Velocity(i * 2, -i))
        buf.set(ef[i], Position(i * 10, i))
    s.eqi(buf.pending(), 16, "sixteen writes recorded")
    buf.apply(wf)
    s.eqi(buf.pending(), 0, "buffer reset after apply")
    var all_eq = True
    for i in range(8):
        var pd = wd.get[Position](ed[i])
        var pf = wf.get[Position](ef[i])
        var vd = wd.get[Velocity](ed[i])
        var vf = wf.get[Velocity](ef[i])
        if pd.x != pf.x or pd.y != pf.y or vd.dx != vf.dx or vd.dy != vf.dy:
            all_eq = False
    s.check(all_eq, "deferred == immediate, per value")

    # 2. Recording order wins across types: later write to the same entity
    #    overwrites the earlier one even though they sit in different queues.
    var w2 = World[SB]()
    var b2 = SetBuffer[Position, Velocity]()
    var e2 = w2.spawn1(Position(0, 0))
    b2.set(e2, Position(1, 1))
    b2.set(e2, Velocity(9, 9))
    b2.set(e2, Position(2, 2))  # must land AFTER Position(1,1)
    b2.apply(w2)
    s.eqi(Int(w2.get[Position](e2).x), 2, "recording order replayed exactly")

    # 3. Deferred write while iterating: mutate-during-query via the buffer
    #    leaves the iteration untouched, applies at the sync point.
    var w3 = World[SB]()
    var b3 = SetBuffer[Position, Velocity]()
    for i in range(4):
        _ = w3.spawn1(Position(i, 0))
    var hits = w3.query1[Position]()
    for i in range(len(hits)):
        b3.set(hits[i], Position(100 + i, 0))  # deferred: safe mid-iteration
        var again = w3.query1[Position]()  # world unchanged during recording
        s.eqi(len(again), 4, "world untouched while recording " + String(i))
    b3.apply(w3)
    var moved = 0
    var after = w3.query1[Position]()
    for i in range(len(after)):
        if Int(w3.get[Position](after[i]).x) >= 100:
            moved += 1
    s.eqi(moved, 4, "all deferred writes landed at the sync point")

    # 4. Writes to an entity that died before the sync point are dropped
    #    (no resurrection).
    var w4 = World[SB]()
    var b4 = SetBuffer[Position, Velocity]()
    var e4 = w4.spawn1(Position(1, 1))
    var e5 = w4.spawn1(Position(2, 2))
    b4.set(e4, Position(7, 7))
    b4.set(e5, Position(8, 8))
    w4.despawn(e4)
    b4.apply(w4)
    s.check(not w4.is_alive(e4), "despawned stays dead")
    s.eqi(Int(w4.get[Position](e5).x), 8, "surviving write landed")
    s.eqi(w4.entity_count(), 1, "no resurrection")

    # 5. Double-run determinism: same script, fresh world, identical state.
    var w5 = World[SB]()
    var b5 = SetBuffer[Position, Velocity]()
    var e6 = w5.spawn1(Position(0, 0))
    b5.set(e6, Position(3, 4))
    b5.set(e6, Velocity(5, 6))
    b5.apply(w5)
    s.check(
        Int(w5.get[Position](e6).x) == Int(w2.get[Position](e2).x) + 1,
        "deterministic final state (3 == 2+1 sanity)",
    )

    s.finish()
