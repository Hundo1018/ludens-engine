"""Entity-as-actor scheduler: every entity is an actor with a mailbox.

Each tick has two stages, both driven by the swappable `DispatchPolicy`:

  1. **Wake** — every actor in the population runs `update` once: it advances its
     own state (e.g. integrates its position) and may *send* messages addressed to
     other entities. An actor mutates **only its own entity's already-present
     components** (an in-place overwrite on a disjoint storage slot), so the wake
     loop is safe to run in parallel and is bit-identical to the serial order.
  2. **Drain** — sent messages are routed (serially, in ascending actor order) into
     recipient inboxes; every actor with mail runs `receive`, which may send more.
     This repeats until no messages remain (or `MAX_ROUNDS`), so an effect emitted
     this tick is fully applied this tick — matching what an imperative system
     would compute, which is what makes the parity test hold.

The actor population is the set of entities carrying the handler's `Key`
component (`world.query1[H.Key]()`); messages are routed by entity id.
"""

from ecs.world import World
from ecs.storage import StorageBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from .scheduler import Scheduler
from .policy import DispatchPolicy
from .message import (
    MessageType,
    Envelope,
    empty_envelopes,
    empty_inboxes,
    has_messages,
)

comptime MAX_ROUNDS = 16  # safety cap on per-tick message cascades


trait EntityHandler:
    """One entity's behavior. `Key` selects the actor population (entities that
    carry this component); `M` is the message type these actors exchange."""

    comptime M: MessageType
    comptime Key: ComponentType

    @staticmethod
    def update[B: StorageBackend](
        mut world: World[B], e: Entity, mut outbox: List[Envelope[Self.M]]
    ): ...

    @staticmethod
    def receive[B: StorageBackend](
        mut world: World[B],
        e: Entity,
        inbox: List[Self.M],
        mut outbox: List[Envelope[Self.M]],
    ): ...


def _route[M: MessageType](
    outboxes: List[List[Envelope[M]]],
    mut inboxes: List[List[M]],
    slot_of: List[Int],
    max_id: Int,
    cap: Int,
    mut dropped: Int,
) -> Int:
    """Deliver each envelope to its recipient's inbox, in ascending sender order
    (deterministic regardless of how the wake/drain loop was dispatched).

    `cap` bounds a single inbox; 0 means unbounded. Overflow drops the NEWEST
    message and counts it. Dropping the newest rather than the oldest is what
    keeps the result independent of dispatch order: senders are visited in
    ascending order, so "the first `cap` messages by sender id" is a property of
    the message set, while "the last `cap`" would depend on which sends arrived
    before the mailbox filled. A bound that silently reordered under load would
    be worse than no bound at all — it would break replay.

    Returns the number of messages delivered, so the caller can tell a quiet
    tick from a saturated one."""
    var delivered = 0
    for i in range(len(outboxes)):
        for j in range(len(outboxes[i])):
            var env = outboxes[i][j]
            if 0 <= env.target <= max_id:
                var s = slot_of[env.target]
                if s >= 0:
                    if cap > 0 and len(inboxes[s]) >= cap:
                        dropped += 1
                        continue
                    inboxes[s].append(env.payload)
                    delivered += 1
    return delivered


struct EntityActorScheduler[
    Bk: StorageBackend, D: DispatchPolicy, H: EntityHandler
](Scheduler):
    comptime B = Self.Bk  # satisfy the trait's associated backend type

    # Backpressure and its observability. A message system that silently
    # truncates is the kind of bug that only shows up as "the simulation
    # diverged on one machine": every limit here is therefore reported, not
    # merely enforced.
    var max_rounds: Int  # cascade depth cap per tick; 0 = MAX_ROUNDS
    var mailbox_cap: Int  # per-inbox bound; 0 = unbounded
    var rounds_used: Int  # cascade rounds the last tick actually needed
    var truncated: Bool  # the last tick hit `max_rounds` with mail still queued
    var dropped: Int  # messages discarded by `mailbox_cap`, cumulative
    var delivered: Int  # messages delivered, cumulative

    def __init__(out self):
        self.max_rounds = 0
        self.mailbox_cap = 0
        self.rounds_used = 0
        self.truncated = False
        self.dropped = 0
        self.delivered = 0

    def tick(mut self, mut world: World[Self.B]):
        comptime M = Self.H.M
        self.rounds_used = 0
        self.truncated = False
        var cap = self.mailbox_cap
        var limit = self.max_rounds if self.max_rounds > 0 else MAX_ROUNDS
        var actors = world.query1[Self.H.Key]()
        var n = len(actors)
        if n == 0:
            return

        # entity id -> slot in `actors`, for routing messages addressed by id
        var max_id = 0
        for i in range(n):
            if actors[i].id > max_id:
                max_id = actors[i].id
        var slot_of = List[Int](capacity=max_id + 1)
        for _ in range(max_id + 1):
            slot_of.append(-1)
        for i in range(n):
            slot_of[actors[i].id] = i

        # --- stage 1: wake every actor once (own-entity mutation + initial sends) ---
        var outboxes = empty_envelopes[M](n)

        @parameter
        def wake(i: Int):
            Self.H.update[Self.B](world, actors[i], outboxes[i])

        Self.D.run[wake](n)

        var inboxes = empty_inboxes[M](n)
        self.delivered += _route[M](
            outboxes, inboxes, slot_of, max_id, cap, self.dropped
        )

        # --- stage 2: drain message cascades until quiescent ---
        var rounds = 0
        while rounds < limit and has_messages[M](inboxes):
            var next_out = empty_envelopes[M](n)

            @parameter
            def deliver(i: Int):
                if len(inboxes[i]) > 0:
                    Self.H.receive[Self.B](
                        world, actors[i], inboxes[i], next_out[i]
                    )

            Self.D.run[deliver](n)

            var next_in = empty_inboxes[M](n)
            self.delivered += _route[M](
                next_out, next_in, slot_of, max_id, cap, self.dropped
            )
            inboxes = next_in^
            rounds += 1
        self.rounds_used = rounds
        self.truncated = has_messages[M](inboxes)
