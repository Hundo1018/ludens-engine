"""Example 19 — react instead of poll: observers + a deferred command buffer.

Twelve entities carry `Health`; every third is also `Poisoned`. Each tick a
poison system lowers the Health of poisoned entities. Writing a component
while iterating the storage is exactly what a sync point is for, so the
system records the new values in a `SetBuffer` and applies them afterwards.

Two ways to find out WHO changed:
  * polling — keep last tick's Health of every entity and compare all twelve;
  * reacting — the reactive backend's push observer on Health `SET` events
    delivers only the entities that were written, in write order.
Both must name the same entities every tick; the observer did not have to
look at the eight healthy ones.

Run:

    pixi run mojo run -I build examples/19_reactive_commands.mojo
"""

from ecs.world import World
from ecs.entity import Entity
from ecs.component import ComponentType
from ecs.commands import SetBuffer
from ecs.reactive_backend import ReactiveBackend, EV_SET


@fieldwise_init
struct Health(ComponentType):
    comptime ID: Int = 0
    var hp: Int


@fieldwise_init
struct Poisoned(ComponentType):
    comptime ID: Int = 1
    var dmg: Int


comptime RB = ReactiveBackend[Health, Poisoned]


def main() raises:
    var w = World[RB]()
    var es = List[Entity]()
    for i in range(12):
        var e = w.spawn1(Health(100))
        if i % 3 == 0:
            w.set(e, Poisoned(7))
        es.append(e)
    var h_set = w.backend.observe1[Health](1 << EV_SET)
    _ = w.backend.drain(h_set)  # discard the spawn-time writes

    var last = List[Int]()
    for e in es:
        last.append(w.get[Health](e).hp)

    var all_agree = True
    for tick in range(3):
        # the poison system: read now, write at the sync point
        var buf = SetBuffer[Health, Poisoned]()
        for e in es:
            if w.has[Poisoned](e):
                buf.set(e, Health(w.get[Health](e).hp - w.get[Poisoned](e).dmg))
        buf.apply(w)

        # polling: compare every entity with last tick
        var polled = List[Int]()
        for k in range(len(es)):
            var hp = w.get[Health](es[k]).hp
            if hp != last[k]:
                polled.append(es[k].id)
            last[k] = hp
        # reacting: only the written entities arrive
        var reacted = List[Int]()
        for ev in w.backend.drain(h_set):
            reacted.append(ev.id)

        var same = len(polled) == len(reacted)
        if same:
            for k in range(len(polled)):
                if polled[k] != reacted[k]:
                    same = False
        all_agree = all_agree and same
        print("tick", tick, " changed (poll):", len(polled), " changed (observer):",
              len(reacted), " poll looked at", len(es), "entities")
    print("observer and polling name the same entities every tick:", "YES" if all_agree else "NO")
    print("poisoned entity hp after 3 ticks:", w.get[Health](es[0]).hp, " healthy:", w.get[Health](es[1]).hp)
