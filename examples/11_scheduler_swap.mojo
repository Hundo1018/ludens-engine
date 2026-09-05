"""Example 11 — one world, any dispatch: the scheduler seam.

The same deterministic workload — 12 entities with Position/Velocity/Health;
per tick every entity integrates `pos += vel` and every even-id entity deals 10
damage to its id+1 neighbour — is run under three schedulers:

  * `SequentialScheduler`      — the imperative reference: systems run in order.
  * `EntityActorScheduler` (Parallel) — each entity is an actor; the damage is a
    message to the neighbour, applied in a drain round.
  * `SystemActorScheduler` (Parallel) — two dataflow actors, an emitter and a
    sink, connected by damage commands.

After 3 ticks every odd entity has lost 30 hp and every even entity is
untouched — an order-independent result. All three schedulers must print the
identical final Health list.

Run:

    pixi run mojo run -I build examples/11_scheduler_swap.mojo
"""

from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.entity import Entity

from scheduler.scheduler import Scheduler, System
from scheduler.sequential import SequentialScheduler
from scheduler.entity_actor import EntityActorScheduler, EntityHandler
from scheduler.system_actor import SystemActorScheduler, ActorSystem
from scheduler.policy import Serial, Parallel
from scheduler.message import MessageType, Envelope

comptime N = 12
comptime FRAMES = 3
comptime DMG = 10
comptime APPLY_IDX = 1  # ApplySystem's slot in the SystemActorScheduler pack


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


@fieldwise_init
struct Health(ComponentType):
    comptime ID: Int = 2
    var hp: Int


@fieldwise_init
struct Damage(MessageType):
    comptime KIND: Int = 0
    var amount: Int


@fieldwise_init
struct DamageCmd(MessageType):
    comptime KIND: Int = 0
    var entity: Int
    var amount: Int


# --- sequential systems: the imperative reference ---
struct MoveSystem(System):
    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        var movers = w.query2[Position, Velocity]()
        for i in range(len(movers)):
            var e = movers[i]
            var p = w.get[Position](e)
            var v = w.get[Velocity](e)
            w.set(e, Position(p.x + v.dx, p.y + v.dy))


struct DamageSystem(System):
    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        var ents = w.query1[Health]()
        var n = len(ents)
        var max_id = 0
        for i in range(n):
            if ents[i].id > max_id:
                max_id = ents[i].id
        var index_of = List[Int](capacity=max_id + 1)
        for _ in range(max_id + 1):
            index_of.append(-1)
        for i in range(n):
            index_of[ents[i].id] = i
        for i in range(n):
            var e = ents[i]
            if e.id % 2 == 0 and e.id + 1 <= max_id and index_of[e.id + 1] >= 0:
                var target = ents[index_of[e.id + 1]]
                var h = w.get[Health](target)
                w.set(target, Health(h.hp - DMG))


# --- entity-actor handler: the same logic as message passing ---
struct SpreadHandler(EntityHandler):
    comptime M = Damage
    comptime Key = Health

    @staticmethod
    def update[B: StorageBackend](
        mut w: World[B], e: Entity, mut outbox: List[Envelope[Damage]]
    ):
        var p = w.get[Position](e)
        var v = w.get[Velocity](e)
        w.set(e, Position(p.x + v.dx, p.y + v.dy))
        if e.id % 2 == 0:
            outbox.append(Envelope[Damage](e.id + 1, Damage(DMG)))

    @staticmethod
    def receive[B: StorageBackend](
        mut w: World[B],
        e: Entity,
        inbox: List[Damage],
        mut outbox: List[Envelope[Damage]],
    ):
        var total = 0
        for i in range(len(inbox)):
            total += inbox[i].amount
        if total > 0:
            var h = w.get[Health](e)
            w.set(e, Health(h.hp - total))


# --- system actors: a two-stage dataflow ---
struct EmitSystem(ActorSystem):
    comptime M = DamageCmd

    @staticmethod
    def handle[B: StorageBackend](
        mut w: World[B], inbox: List[DamageCmd]
    ) -> List[Envelope[DamageCmd]]:
        var out = List[Envelope[DamageCmd]]()
        var movers = w.query2[Position, Velocity]()
        for i in range(len(movers)):
            var e = movers[i]
            var p = w.get[Position](e)
            var v = w.get[Velocity](e)
            w.set(e, Position(p.x + v.dx, p.y + v.dy))
            if e.id % 2 == 0:
                out.append(Envelope[DamageCmd](APPLY_IDX, DamageCmd(e.id + 1, DMG)))
        return out^


struct ApplySystem(ActorSystem):
    comptime M = DamageCmd

    @staticmethod
    def handle[B: StorageBackend](
        mut w: World[B], inbox: List[DamageCmd]
    ) -> List[Envelope[DamageCmd]]:
        var out = List[Envelope[DamageCmd]]()
        if len(inbox) == 0:
            return out^
        var ents = w.query1[Health]()
        var n = len(ents)
        var max_id = 0
        for i in range(n):
            if ents[i].id > max_id:
                max_id = ents[i].id
        var index_of = List[Int](capacity=max_id + 1)
        for _ in range(max_id + 1):
            index_of.append(-1)
        for i in range(n):
            index_of[ents[i].id] = i
        for i in range(len(inbox)):
            var cmd = inbox[i]
            if 0 <= cmd.entity <= max_id and index_of[cmd.entity] >= 0:
                var target = ents[index_of[cmd.entity]]
                var h = w.get[Health](target)
                w.set(target, Health(h.hp - cmd.amount))
        return out^


comptime Backend = SparseSetBackend[Position, Velocity, Health]


def hp_list[S: Scheduler]() -> List[Int]:
    """Run the fixed scenario under scheduler `S`; return hp in entity-id order."""
    var w = World[S.B]()
    for i in range(N):
        var e = w.spawn()
        w.set(e, Position(i, 0))
        w.set(e, Velocity(1, 0))
        w.set(e, Health(100))

    var sched = S()
    for _ in range(FRAMES):
        sched.tick(w)

    var ents = w.query1[Health]()
    var out = List[Int](capacity=N)
    for _ in range(N):
        out.append(0)
    for i in range(len(ents)):
        out[ents[i].id] = w.get[Health](ents[i]).hp
    return out^


def _show(label: String, hp: List[Int]):
    var line = String("  ") + label + ": ["
    for i in range(len(hp)):
        line += String(hp[i])
        if i + 1 < len(hp):
            line += ", "
    line += "]"
    print(line)


def _same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    print("== same 12-entity world, three schedulers, final Health list ==")
    var seq = hp_list[SequentialScheduler[Backend, MoveSystem, DamageSystem]]()
    var ea = hp_list[EntityActorScheduler[Backend, Parallel, SpreadHandler]]()
    var sa = hp_list[SystemActorScheduler[Backend, Parallel, EmitSystem, ApplySystem]]()

    _show("SequentialScheduler        ", seq)
    _show("EntityActorScheduler[Par]  ", ea)
    _show("SystemActorScheduler[Par]  ", sa)

    var ok = _same(seq, ea) and _same(seq, sa)
    print("  all three identical:", "YES" if ok else "NO")
