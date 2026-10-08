"""Fixed-size counter bank indexed by comptime ids (Phase 17.10 support).

Every "capacity/budget overflow" and "numerical failure" row in
`docs/ARCHITECTURE.md` §2 ends in "recorded by: `diag` counter" -- a drop or a
quarantine must never be silent, but it also must never allocate or format a
string on the hot path that hit it. A flat `Array[Int64, N]` indexed by a
`comptime` id is the cheapest possible "it happened, N times" record: one
bounds-checked add, no `Dict`, no `String` key.

Ids are plain `comptime Int` constants rather than an enum (Mojo has no `enum`
in this toolchain) so they can be used directly as the `Array` index and as a
bracket parameter. `_name(id)` mirrors the id order for `dump()`; if you add an
id, add its name to that function and bump `COUNT`.

`LogRing`, `DrawQueue` and `TraceBuffer` each also keep their OWN `dropped: Int`
field (see their modules) so they stay unit-testable in isolation without a
`Counters` instance in scope. Wiring a container's local counter into a shared
`Counters` bank (so `NAN_QUARANTINED` etc. show up next to `LOG_DROPPED`) is
the solver/world owner's job, once it exists and has a `Counters` field of its
own -- `diag` itself deliberately stays a set of independently-constructible
primitives (`LogRing`, `Counters`, `TraceBuffer`, `DrawQueue`, `FrameArena`)
rather than bundling them into one aggregate type up front: the capacities
each one needs are a property of the caller (how big a world, how much
debug-draw), not of `diag`, so `diag` doesn't guess at them.
"""

comptime NAN_QUARANTINED: Int = 0
"""A body's state went non-finite and the solver zeroed/force-slept it."""
comptime CCD_BUDGET_EXCEEDED: Int = 1
"""A continuous-collision sweep ran out of its iteration budget."""
comptime LOG_DROPPED: Int = 2
"""`LogRing` was full; a record was dropped (see `diag/log.mojo`)."""
comptime DRAW_DROPPED: Int = 3
"""`DrawQueue` was full; a command was dropped (see `diag/draw.mojo`)."""
comptime TRACE_DROPPED: Int = 4
"""`TraceBuffer` was full; a span event was dropped (see `diag/trace.mojo`)."""
comptime ARENA_OVERFLOW: Int = 5
"""`FrameArena` ran out of space for a typed `alloc` (see `diag/arena.mojo`)."""
comptime POOL_GROWN: Int = 6
"""An `ecs.pool.Pool` had no free slot and grew by one (see `ecs/pool.mojo`)."""
comptime POOL_EXHAUSTED: Int = 7
"""A fixed-capacity `ecs.pool.Pool` had no free slot and refused `acquire()`
(see `ecs/pool.mojo`)."""
comptime EVENT_DROPPED_UNREAD: Int = 8
"""`scheduler.events.Channel` recycled its double buffer while a reader's
cursor was still behind it; that reader's events for this cycle were dropped
(see `scheduler/events.mojo`)."""
comptime PARALLEL_FALLBACK_SERIAL: Int = 9
"""`physics.solver6.ContactScene6.step(cfg.parallel=True)` fell back to the
serial path because soft bodies, `ccd`, or `colored` solving were also
requested in the same step (audit F23 -- the island-parallel path assumes
none of those)."""
comptime COLOR_OVERFLOW: Int = 10
"""`physics.solver6.ContactScene6.step(cfg.colored=True)` hit a body touched
by 64 differently-coloured pairs (audit E7 -- `1 << col` on an `Int` stops
being a valid single-bit mask past 63); the whole step's colored partition
was abandoned and the pairs solved serially instead."""
comptime CG_NOT_CONVERGED: Int = 11
"""`physics.fem.FemBody`'s implicit Newmark solve's conjugate-gradient pass
(`numerics.cg.cg`) did not converge within its iteration budget (audit E19);
the velocity delta it produced was discarded rather than applied, so the
body keeps last step's velocity instead of one derived from a
possibly-diverged solve."""
comptime GAMELOOP_DEBT_DROPPED: Int = 12
"""`scheduler.gameloop.FixedLoop.advance` hit `max_steps` with accumulated
time still owed (audit E22/F16 -- a frame-rate spike); the excess debt was
dropped rather than carried into the next frame, so `alpha` stays in
`[0, 1)` instead of drifting unbounded."""

comptime FRAGMENT_EVICTED: Int = 13
"""`physics.fracture.FractureSet.enforce_budget` removed a free fragment
because the live count exceeded the budget (ROADMAP 17.5)."""

comptime COUNT: Int = 14


def _name(id: Int) -> String:
    if id == NAN_QUARANTINED:
        return "nan_quarantined"
    elif id == CCD_BUDGET_EXCEEDED:
        return "ccd_budget_exceeded"
    elif id == LOG_DROPPED:
        return "log_dropped"
    elif id == DRAW_DROPPED:
        return "draw_dropped"
    elif id == TRACE_DROPPED:
        return "trace_dropped"
    elif id == ARENA_OVERFLOW:
        return "arena_overflow"
    elif id == POOL_GROWN:
        return "pool_grown"
    elif id == POOL_EXHAUSTED:
        return "pool_exhausted"
    elif id == EVENT_DROPPED_UNREAD:
        return "event_dropped_unread"
    elif id == PARALLEL_FALLBACK_SERIAL:
        return "parallel_fallback_serial"
    elif id == COLOR_OVERFLOW:
        return "color_overflow"
    elif id == CG_NOT_CONVERGED:
        return "cg_not_converged"
    elif id == GAMELOOP_DEBT_DROPPED:
        return "gameloop_debt_dropped"
    elif id == FRAGMENT_EVICTED:
        return "fragment_evicted"
    else:
        return "counter_" + String(id)


struct Counters(Movable):
    """A `COUNT`-slot bank of monotonic `Int64` counters, indexed by the
    `comptime Int` ids above. Owned by whoever owns the world; passed `mut`."""

    var values: Array[Int64, COUNT]

    def __init__(out self):
        self.values = Array[Int64, COUNT](fill=0)

    def incr(mut self, id: Int, by: Int64 = 1):
        self.values[id] += by

    def get(self, id: Int) -> Int64:
        return self.values[id]

    def reset(mut self):
        self.values = Array[Int64, COUNT](fill=0)

    def dump(self) -> String:
        """Render every nonzero counter as `name: value` lines. Engine code
        never prints (`docs/ARCHITECTURE.md` §2 rule 1) -- callers print this
        themselves in tests/examples."""
        var out = String("")
        for i in range(COUNT):
            if self.values[i] != 0:
                out += _name(i) + ": " + String(self.values[i]) + "\n"
        return out^
