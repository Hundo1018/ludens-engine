"""Actor scheduling, hardened (architecture law v3).

`test_scheduler_parity` already shows the actor schedulers reach the same world
as the sequential one. What it does not show is the part that makes actors
usable as a rollback foundation: that the delivery SEMANTICS are pinned down —
message order, same-tick visibility, what happens when a mailbox fills, and
whether two identical runs really are identical.

ORDINARY    a message sent during wake is delivered and acted on in the SAME
            tick; a cascade of sends resolves within the tick; inbox contents
            arrive in ascending sender order regardless of dispatch policy.
INTEGRATION serial and parallel dispatch give bit-identical worlds AND
            bit-identical delivery counts and cascade depths; two independent
            runs of the same scenario agree exactly, which is the property
            replay and rollback rest on.
EXTREME     an empty actor population, a single actor talking to itself, a
            cascade deeper than the round cap (must be reported, not silently
            truncated), a mailbox that overflows (must drop deterministically
            and count it), and messages addressed to entities that do not exist.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from scheduler.entity_actor import EntityActorScheduler, EntityHandler
from scheduler.policy import Serial, Parallel
from scheduler.message import MessageType, Envelope

comptime N = 16


@fieldwise_init
struct Tag(ComponentType):
    comptime ID: Int = 0
    var v: Int


@fieldwise_init
struct Acc(ComponentType):
    comptime ID: Int = 1
    var sum: Int
    var first: Int  # payload of the first message received, ever
    var count: Int


@fieldwise_init
struct Ping(MessageType):
    comptime KIND: Int = 0
    var amount: Int
    var hops: Int


struct Relay(EntityHandler):
    """Every actor sends its id to actor 0 on wake. Actor 0 then relays a
    decrementing hop count back to actor 1, which bounces it on — a cascade
    whose depth is controlled by the initial hop value, so the round cap can be
    driven on purpose rather than hoped for."""

    comptime M = Ping
    comptime Key = Tag

    @staticmethod
    def update[B: StorageBackend](
        mut world: World[B], e: Entity, mut outbox: List[Envelope[Ping]]
    ):
        outbox.append(Envelope[Ping](0, Ping(e.id + 1, 0)))

    @staticmethod
    def receive[B: StorageBackend](
        mut world: World[B],
        e: Entity,
        inbox: List[Ping],
        mut outbox: List[Envelope[Ping]],
    ):
        var a = world.get[Acc](e)
        var total = a.sum
        var first = a.first
        for k in range(len(inbox)):
            if a.count == 0 and k == 0:
                first = inbox[k].amount
            total += inbox[k].amount
            # bounce a shrinking hop count between actors 0 and 1
            if inbox[k].hops > 0:
                var to = 1 if e.id == 0 else 0
                outbox.append(Envelope[Ping](to, Ping(0, inbox[k].hops - 1)))
        world.set(e, Acc(total, first, a.count + len(inbox)))


struct SelfTalk(EntityHandler):
    """One actor that messages only itself, `hops` times."""

    comptime M = Ping
    comptime Key = Tag

    @staticmethod
    def update[B: StorageBackend](
        mut world: World[B], e: Entity, mut outbox: List[Envelope[Ping]]
    ):
        outbox.append(Envelope[Ping](e.id, Ping(1, 3)))

    @staticmethod
    def receive[B: StorageBackend](
        mut world: World[B],
        e: Entity,
        inbox: List[Ping],
        mut outbox: List[Envelope[Ping]],
    ):
        var a = world.get[Acc](e)
        var total = a.sum
        for k in range(len(inbox)):
            total += inbox[k].amount
            if inbox[k].hops > 0:
                outbox.append(Envelope[Ping](e.id, Ping(1, inbox[k].hops - 1)))
        world.set(e, Acc(total, a.first, a.count + len(inbox)))


struct Ghost(EntityHandler):
    """Every actor sends to an entity id far outside the population."""

    comptime M = Ping
    comptime Key = Tag

    @staticmethod
    def update[B: StorageBackend](
        mut world: World[B], e: Entity, mut outbox: List[Envelope[Ping]]
    ):
        outbox.append(Envelope[Ping](9999, Ping(1, 0)))
        outbox.append(Envelope[Ping](-5, Ping(1, 0)))

    @staticmethod
    def receive[B: StorageBackend](
        mut world: World[B],
        e: Entity,
        inbox: List[Ping],
        mut outbox: List[Envelope[Ping]],
    ):
        var a = world.get[Acc](e)
        world.set(e, Acc(a.sum + len(inbox), a.first, a.count + len(inbox)))


comptime BK = SparseSetBackend[Tag, Acc]


def _seed(mut w: World[BK], n: Int):
    for _ in range(n):
        var e = w.spawn()
        w.set(e, Tag(0))
        w.set(e, Acc(0, 0, 0))


def _digest(w: World[BK], n: Int) -> Int:
    var h = 0
    for i in range(n):
        var a = w.get[Acc](Entity(i, 0))
        h = h * 131 + a.sum
        h = h * 131 + a.first
        h = h * 131 + a.count
    return h


def main() raises:
    var s = Suite("actor")

    # ---- ORDINARY: same-tick delivery ----
    var w = World[BK]()
    _seed(w, N)
    var sched = EntityActorScheduler[BK, Serial, Relay]()
    sched.tick(w)
    var a0 = w.get[Acc](Entity(0, 0))
    print("  actor 0 after one tick — sum", a0.sum, " count", a0.count,
          " first", a0.first, " rounds", sched.rounds_used)
    s.eqi(
        a0.count, N,
        "every wake-stage message is delivered and acted on in the SAME tick",
    )
    s.eqi(
        a0.sum, N * (N + 1) // 2,
        "and the payloads are all there, none lost",
    )
    s.eqi(a0.first, 1, "the first message in the inbox is from the lowest sender id")
    s.check(sched.rounds_used >= 1, "the drain stage ran")
    s.check(not sched.truncated, "and reached quiescence")
    s.eqi(sched.dropped, 0, "with an unbounded mailbox nothing is dropped")

    # ---- INTEGRATION: dispatch policy does not change the answer ----
    var ws = World[BK]()
    _seed(ws, N)
    var ss = EntityActorScheduler[BK, Serial, Relay]()
    for _ in range(4):
        ss.tick(ws)

    var wp = World[BK]()
    _seed(wp, N)
    var sp = EntityActorScheduler[BK, Parallel, Relay]()
    for _ in range(4):
        sp.tick(wp)

    print("  digests — serial", _digest(ws, N), " parallel", _digest(wp, N))
    s.eqi(
        _digest(wp, N), _digest(ws, N),
        "parallel dispatch is bit-identical to serial",
    )
    s.eqi(sp.delivered, ss.delivered, "and delivers exactly as many messages")
    s.eqi(sp.rounds_used, ss.rounds_used, "in the same number of cascade rounds")

    # two independent runs agree exactly: the property replay rests on
    var wr = World[BK]()
    _seed(wr, N)
    var sr = EntityActorScheduler[BK, Parallel, Relay]()
    for _ in range(4):
        sr.tick(wr)
    s.eqi(
        _digest(wr, N), _digest(wp, N),
        "an independent rerun reproduces the run exactly",
    )

    # ---- EXTREME ----
    # empty population
    var we = World[BK]()
    var se = EntityActorScheduler[BK, Serial, Relay]()
    se.tick(we)
    s.eqi(se.delivered, 0, "an empty actor population delivers nothing")
    s.check(not se.truncated, "and does not report truncation")

    # a single actor messaging itself
    var w1 = World[BK]()
    _seed(w1, 1)
    var s1 = EntityActorScheduler[BK, Serial, SelfTalk]()
    s1.tick(w1)
    var acc1 = w1.get[Acc](Entity(0, 0))
    print("  self-talk — count", acc1.count, " rounds", s1.rounds_used)
    s.eqi(acc1.count, 4, "a self-addressed cascade of 4 resolves in one tick")
    s.check(not s1.truncated, "and terminates")

    # a cascade deeper than the round cap must be REPORTED, not silent
    var w2 = World[BK]()
    _seed(w2, 1)
    var s2 = EntityActorScheduler[BK, Serial, SelfTalk]()
    s2.max_rounds = 2
    s2.tick(w2)
    print("  capped at 2 rounds — used", s2.rounds_used,
          " truncated", s2.truncated)
    s.eqi(s2.rounds_used, 2, "the cap is honoured")
    s.check(
        s2.truncated,
        "and hitting it with mail still queued is REPORTED, not silent",
    )

    # mailbox overflow: deterministic, counted, and the same under both policies
    var w3 = World[BK]()
    _seed(w3, N)
    var s3 = EntityActorScheduler[BK, Serial, Relay]()
    s3.mailbox_cap = 4
    s3.tick(w3)
    var w4 = World[BK]()
    _seed(w4, N)
    var s4 = EntityActorScheduler[BK, Parallel, Relay]()
    s4.mailbox_cap = 4
    s4.tick(w4)
    var acc3 = w3.get[Acc](Entity(0, 0))
    print("  mailbox cap 4 — delivered", s3.delivered, " dropped", s3.dropped,
          " actor0 count", acc3.count)
    s.eqi(acc3.count, 4, "a capped inbox holds exactly its cap")
    s.eqi(s3.dropped, N - 4, "and the overflow is counted, not hidden")
    s.eqi(
        acc3.sum, 1 + 2 + 3 + 4,
        "the messages KEPT are the lowest sender ids: dropping the newest is"
        " what makes the cap order-independent",
    )
    s.eqi(_digest(w4, N), _digest(w3, N), "overflow is identical under parallel dispatch")
    s.eqi(s4.dropped, s3.dropped, "and drops exactly as many")

    # messages to entities that do not exist
    var w5 = World[BK]()
    _seed(w5, 4)
    var s5 = EntityActorScheduler[BK, Serial, Ghost]()
    s5.tick(w5)
    print("  ghost targets — delivered", s5.delivered, " dropped", s5.dropped)
    s.eqi(s5.delivered, 0, "messages to non-existent entities are discarded")
    s.eqi(s5.dropped, 0, "and are not counted as backpressure drops")
    s.check(not s5.truncated, "and do not keep the drain loop spinning")

    s.finish()
