"""Push-based observer gates (ROADMAP 4.4): trigger-order determinism and
semantic parity with manual polling on the reactive backend."""

from harness.runner import Suite
from ecs.world import World
from ecs.component import ComponentType
from ecs.reactive_backend import (
    ReactiveBackend,
    ObsEvent,
    EV_ADD,
    EV_SET,
    EV_REMOVE,
)


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


comptime RB = ReactiveBackend[Position, Velocity]


def _scenario(mut w: World[RB], h_all: Int, h_vel: Int) -> List[ObsEvent]:
    """A fixed mutation script; returns the all-events inbox afterwards."""
    var e0 = w.spawn1(Position(0, 0))  # ADD P, SET P
    var e1 = w.spawn1(Position(1, 1))  # ADD P, SET P
    w.set(e0, Velocity(1, 0))  # ADD V, SET V
    w.set(e0, Position(5, 5))  # SET P (no ADD: already present)
    w.remove[Velocity](e0)  # REMOVE V
    w.remove[Velocity](e0)  # nothing (was absent)
    w.set(e1, Velocity(0, 1))  # ADD V, SET V
    w.despawn(e1)  # REMOVE P, REMOVE V (slot order)
    _ = h_vel
    return w.backend.drain(h_all)


def main() raises:
    var s = Suite("observers")

    var w = World[RB]()
    var h_all = w.backend.observe2[Position, Velocity](
        (1 << EV_ADD) | (1 << EV_SET) | (1 << EV_REMOVE)
    )
    var h_vel = w.backend.observe1[Velocity](1 << EV_ADD)
    var ev = _scenario(w, h_all, h_vel)

    # Exact expected stream (kinds/slots/order derived by hand from the
    # script above; entity ids are 0 and 1 by construction).
    var want_kind = [
        EV_ADD, EV_SET,  # e0 P
        EV_ADD, EV_SET,  # e1 P
        EV_ADD, EV_SET,  # e0 V
        EV_SET,  # e0 P overwrite
        EV_REMOVE,  # e0 V
        EV_ADD, EV_SET,  # e1 V
        EV_REMOVE, EV_REMOVE,  # e1 despawn: P then V (slot order)
    ]
    var want_slot = [0, 0, 0, 0, 1, 1, 0, 1, 1, 1, 0, 1]
    var want_id = [0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1]
    s.eqi(len(ev), len(want_kind), "event count")
    var stream_ok = True
    for i in range(min(len(ev), len(want_kind))):
        if (
            ev[i].kind != want_kind[i]
            or ev[i].slot != want_slot[i]
            or ev[i].id != want_id[i]
        ):
            stream_ok = False
            print(
                "  mismatch at", i, ": got (", ev[i].kind, ev[i].slot,
                ev[i].id, ")",
            )
    s.check(stream_ok, "exact event stream (kinds, slots, ids, order)")

    # Filtered observer: only Velocity ADDs, nothing else leaked through.
    var vev = w.backend.drain(h_vel)
    s.eqi(len(vev), 2, "filtered observer: two velocity adds")
    s.check(
        len(vev) == 2
        and vev[0].kind == EV_ADD
        and vev[0].slot == 1
        and vev[0].id == 0
        and vev[1].id == 1,
        "filtered observer stream",
    )

    # Drain resets: nothing left in either inbox.
    s.eqi(len(w.backend.drain(h_all)), 0, "drain resets inbox")

    # Double-run determinism: an identical fresh run yields a bit-identical
    # event list.
    var w2 = World[RB]()
    var h2_all = w2.backend.observe2[Position, Velocity](
        (1 << EV_ADD) | (1 << EV_SET) | (1 << EV_REMOVE)
    )
    var h2_vel = w2.backend.observe1[Velocity](1 << EV_ADD)
    var ev2 = _scenario(w2, h2_all, h2_vel)
    var same = len(ev) == len(ev2)
    if same:
        for i in range(len(ev)):
            if (
                ev[i].kind != ev2[i].kind
                or ev[i].slot != ev2[i].slot
                or ev[i].id != ev2[i].id
            ):
                same = False
                break
    s.check(same, "double run: bit-identical event stream")

    # Polling parity: replaying ADD/REMOVE events reconstructs exactly the
    # membership the polled query reports.
    var w3 = World[RB]()
    var h3 = w3.backend.observe1[Velocity]((1 << EV_ADD) | (1 << EV_REMOVE))
    var a = w3.spawn1(Position(0, 0))
    var b = w3.spawn1(Position(1, 1))
    var c = w3.spawn1(Position(2, 2))
    w3.set(a, Velocity(1, 1))
    w3.set(b, Velocity(2, 2))
    w3.remove[Velocity](a)
    w3.set(c, Velocity(3, 3))
    var members = List[Int]()  # replay: ADD appends, REMOVE deletes
    var ev3 = w3.backend.drain(h3)
    for i in range(len(ev3)):
        if ev3[i].kind == EV_ADD:
            members.append(ev3[i].id)
        else:
            var out = List[Int]()
            for j in range(len(members)):
                if members[j] != ev3[i].id:
                    out.append(members[j])
            members = out^
    var polled = w3.query2[Position, Velocity]()
    s.eqi(len(members), len(polled), "replayed membership size == polled")
    var match_all = True
    for i in range(len(polled)):
        var found = False
        for j in range(len(members)):
            if members[j] == polled[i].id:
                found = True
        if not found:
            match_all = False
    s.check(match_all, "replayed membership == polled membership")

    s.finish()
