"""Scoped profiling spans + Chrome Trace / Perfetto JSON export (Phase 17.10).

Probed on Mojo 1.1.0 / modular 26.6.0 which of two candidate forms is the
reliable way to time a lexical scope
(`/tmp/claude-1000/probe_diag2/p3_with_ctx.mojo`, `p4_del_timing.mojo`,
`p5_scoped_span.mojo`):

  * RAII-by-`__deinit__` is UNRELIABLE for this: Mojo destroys values ASAP
    after their last use, not at the end of the enclosing scope. A probe
    struct whose `__deinit__` printed "deinit" fired the moment the value's
    last field was read, before unrelated code later in the same block ran --
    so a span meant to cover "this whole block" would actually stop timing
    early, silently, the instant nothing else touched it.
  * The `with` statement's `__enter__`/`__exit__` protocol IS reliable: a
    probe with two nested `with Span(...):` blocks entered/exited in correct
    LIFO order, deterministically at the block boundaries, matching what a
    profiler needs.

So every span in this module goes through `__enter__`/`__exit__` (via
`TraceBuffer.scoped(name)` used in a `with` statement) or, when a `with` block
doesn't fit the call site, the equivalent explicit `begin(name)`/`end()` pair
that `scoped` itself is built on. Both push/pop the same open-span stack, so
they nest correctly with each other.

`LUDENS_TRACE` (from `diag/level.mojo`) gates `begin`/`end`'s bodies with
`comptime if TRACE_ON`, not `scoped`'s: `scoped` always constructs the same
`ScopedSpan` type and always goes through `__enter__`/`__exit__`, so a single
call site compiles unconditionally, but the actual timestamp-and-push work
inside `begin`/`end` disappears when tracing is off. In
`benchmarks/bench_diag.mojo`'s solver-phase-sized table the "off" row lands
within noise of not tracing at all (the compiler inlines the now-empty
`begin`/`end` bodies away); the "on" row's real per-span cost -- constructing
a `SpanEvent`, two `List` push/pops, one `String` copy of the span name -- is
still only a few percent of a realistically-sized phase, which is the number
that table exists to check (see that file and `docs/CATEGORY.md` §2.2 for why
a single scalar op per span would be the wrong thing to benchmark instead).

Capacity policy matches `LogRing`/`DrawQueue`: drop-newest + count
(`dropped`), never silently discard.
"""

from std.time import perf_counter_ns
from .level import TRACE_ON


@fieldwise_init
struct SpanEvent(Copyable, Movable):
    var name: String
    var t_begin_ns: Int
    var t_end_ns: Int
    var tid: Int


@fieldwise_init
struct SpanStat(Copyable, Movable):
    """Aggregated stats for every event sharing one `name` (see `.stats()`)."""

    var name: String
    var count: Int
    var total_ns: Int
    var max_ns: Int


struct TraceBuffer(Movable):
    """Fixed-capacity buffer of finished spans, plus an open-span stack for
    nesting. `tid` tags every event (for multi-thread Chrome-trace tracks);
    defaults to 0 for a single-threaded caller."""

    var events: List[SpanEvent]
    var capacity: Int
    var dropped: Int
    var _open: List[SpanEvent]
    var tid: Int

    def __init__(out self, capacity: Int, tid: Int = 0):
        self.events = List[SpanEvent](capacity=capacity)
        self.capacity = capacity
        self.dropped = 0
        self._open = List[SpanEvent]()
        self.tid = tid

    def begin(mut self, name: String):
        """Push an open span. No-op unless `-D LUDENS_TRACE`."""
        comptime if TRACE_ON:
            self._open.append(SpanEvent(name, Int(perf_counter_ns()), 0, self.tid))

    def end(mut self):
        """Close the most recently opened span (LIFO). No-op unless
        `-D LUDENS_TRACE`; also a no-op (not an error) if nothing is open, so
        a stray `end()` on an off build never mismatches."""
        comptime if TRACE_ON:
            if len(self._open) == 0:
                return
            var ev = self._open.pop()
            ev.t_end_ns = Int(perf_counter_ns())
            if len(self.events) < self.capacity:
                self.events.append(ev^)
            else:
                self.dropped += 1

    def scoped[origin: MutOrigin, //](
        ref[origin] self, name: String
    ) -> ScopedSpan[origin]:
        """`with trace.scoped("phase"): ...` -- see module docstring for why
        this is `__enter__`/`__exit__`-based rather than `__deinit__`-based."""
        return ScopedSpan[origin](Pointer(to=self), name)

    def clear(mut self):
        self.events.clear()
        self._open.clear()
        self.dropped = 0

    def stats(self) -> List[SpanStat]:
        """Per-name count/total/max over `events`. O(events * distinct names)
        -- fine for the handful of named phases a solver step has; not meant
        for a buffer full of uniquely-named spans."""
        var out = List[SpanStat]()
        for ref e in self.events:
            var dur = e.t_end_ns - e.t_begin_ns
            var found = -1
            for i in range(len(out)):
                if out[i].name == e.name:
                    found = i
                    break
            if found == -1:
                out.append(SpanStat(e.name, 1, dur, dur))
            else:
                out[found].count += 1
                out[found].total_ns += dur
                if dur > out[found].max_ns:
                    out[found].max_ns = dur
        return out^

    def to_chrome_json(self) -> String:
        """Chrome Trace Event Format ("complete" `X` events, `ts`/`dur` in
        microseconds) -- load in `chrome://tracing` or Perfetto."""
        var out = String("[")
        var first = True
        for ref e in self.events:
            if not first:
                out += ","
            first = False
            var ts_us = e.t_begin_ns // 1000
            var dur_us = (e.t_end_ns - e.t_begin_ns) // 1000
            out += '{"name":"' + e.name + '"'
            out += ',"ph":"X"'
            out += ',"ts":' + String(ts_us)
            out += ',"dur":' + String(dur_us)
            out += ',"pid":0'
            out += ',"tid":' + String(e.tid)
            out += "}"
        out += "]"
        return out^


struct ScopedSpan[origin: MutOrigin](Movable):
    var trace: Pointer[TraceBuffer, Self.origin]
    var name: String

    def __init__(out self, trace: Pointer[TraceBuffer, Self.origin], name: String):
        self.trace = trace
        self.name = name

    def __enter__(mut self) -> ref[self] Self:
        self.trace[].begin(self.name)
        return self

    def __exit__(mut self):
        self.trace[].end()
