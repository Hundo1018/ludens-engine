"""System-as-actor scheduler: each system is an actor with an inbox (dataflow).

Systems communicate by message instead of by an implied run-order: a system reads
the world and its inbox, mutates the world, and *returns* messages addressed to
other systems (by system index). Each tick:

  1. **Kickoff** — every system runs once with an empty inbox, so source systems
     can produce the first messages.
  2. **Drain** — messages are routed into recipient inboxes; every system with
     mail runs again, possibly emitting more; repeat until quiescent (or
     `MAX_ROUNDS`).

Dispatch over the (few) system actors is the swappable `DispatchPolicy`. Because
systems share the world, the `Parallel` policy is only safe when the systems that
run *concurrently in the same round* write disjoint component types — the standard
parallel-ECS rule. Under that discipline `Serial` and `Parallel` agree.

Two Mojo-nightly details: systems are a compile-time *type* pack, so the per-actor
index is comptime — the runtime dispatch index is bridged back with a
`comptime for k ... if i == k` ladder. And each pack member's associated message
type is nominally distinct in the generic body, so the shared mailbox element type
(`Systems[0].M`) is `rebind`-ed to `Systems[k].M` at each call (identical concrete
type at instantiation).
"""

from ecs.world import World
from ecs.storage import StorageBackend
from .scheduler import Scheduler
from .policy import DispatchPolicy
from .dispatch import Dispatch, Task, dispatch_for
from .message import (
    MessageType,
    Envelope,
    empty_envelopes,
    empty_inboxes,
    has_messages,
)

comptime MAX_ROUNDS = 16  # safety cap on per-tick message cascades


trait ActorSystem:
    """A system actor. `M` is the message type it exchanges with other systems;
    `handle` reads the world + its `inbox`, mutates the world, and returns
    envelopes for other systems (`target` is a system index)."""

    comptime M: MessageType

    @staticmethod
    def handle[B: StorageBackend](
        mut world: World[B], inbox: List[Self.M]
    ) -> List[Envelope[Self.M]]: ...


def _route_by_index[M: MessageType](
    outboxes: List[List[Envelope[M]]], mut inboxes: List[List[M]]
):
    """Deliver each envelope to inbox[target], where target is the system index.
    Sender-ascending order keeps delivery deterministic across dispatch policies."""
    for i in range(len(outboxes)):
        for j in range(len(outboxes[i])):
            var env = outboxes[i][j]
            if 0 <= env.target < len(inboxes):
                inboxes[env.target].append(env.payload)


struct _SystemTask[Bk: StorageBackend, *Systems: ActorSystem](Task):
    """One system actor per item for a host `Dispatch` (ROADMAP 17.75)."""

    comptime M = Self.Systems[0].M
    var world: Pointer[World[Self.Bk], MutUntrackedOrigin]
    var inboxes: Pointer[List[List[Self.M]], MutUntrackedOrigin]
    var outboxes: Pointer[List[List[Envelope[Self.M]]], MutUntrackedOrigin]
    var run_all: Bool

    def __init__(out self, mut world: World[Self.Bk], mut inboxes: List[List[Self.M]], mut outboxes: List[List[Envelope[Self.M]]], run_all: Bool):
        self.world = Pointer(to=world).unsafe_origin_cast[MutUntrackedOrigin]()
        self.inboxes = Pointer(to=inboxes).unsafe_origin_cast[MutUntrackedOrigin]()
        self.outboxes = Pointer(to=outboxes).unsafe_origin_cast[MutUntrackedOrigin]()
        self.run_all = run_all

    def run(self, i: Int):
        comptime K = len(Self.Systems)
        comptime for k in range(K):
            if i == k and (self.run_all or len(self.inboxes[][k]) > 0):
                var produced = Self.Systems[k].handle[Self.Bk](
                    self.world[], rebind[List[Self.Systems[k].M]](self.inboxes[][k])
                )
                for j in range(len(produced)):
                    self.outboxes[][k].append(rebind[Envelope[Self.M]](produced[j]))


struct SystemActorScheduler[
    Bk: StorageBackend, D: DispatchPolicy, *Systems: ActorSystem
](Scheduler):
    comptime B = Self.Bk  # satisfy the trait's associated backend type
    comptime M = Self.Systems[0].M  # all systems share one message type
    comptime K = len(Self.Systems)  # number of system actors

    var host: Optional[Dispatch]  # ROADMAP 17.75: overrides `D` when set

    def __init__(out self):
        self.host = None

    def tick(mut self, mut world: World[Self.B]):
        comptime M = Self.M
        comptime K = Self.K

        var inboxes = empty_inboxes[M](K)
        var force_all = True  # kickoff: run every system once, even with no mail
        var rounds = 0

        while True:
            var outboxes = empty_envelopes[M](K)
            var run_all = force_all

            def worker(i: Int) {mut world, imm inboxes, mut outboxes, imm run_all}:
                # bridge the runtime dispatch index to the comptime system index
                comptime for k in range(K):
                    if i == k and (run_all or len(inboxes[k]) > 0):
                        var produced = Self.Systems[k].handle[Self.B](
                            world, rebind[List[Self.Systems[k].M]](inboxes[k])
                        )
                        for j in range(len(produced)):
                            outboxes[k].append(rebind[Envelope[M]](produced[j]))

            if self.host:
                var st = _SystemTask[Self.B, *Self.Systems](world, inboxes, outboxes, run_all)
                dispatch_for(self.host.value(), st, K)
                _ = len(inboxes)  # keep alive past the untracked-pointer use
                _ = len(outboxes)
            else:
                Self.D.run(worker, K)

            var next_in = empty_inboxes[M](K)
            _route_by_index[M](outboxes, next_in)
            inboxes = next_in^
            force_all = False
            rounds += 1
            if rounds >= MAX_ROUNDS or not has_messages[M](inboxes):
                break
