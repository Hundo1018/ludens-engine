"""Scoped profiling spans + Chrome Trace / Perfetto JSON export (Phase 17.10).

Probed on Mojo 1.1.0 / modular 26.6.0 which of two candidate forms is the
reliable way to time a lexical scope
(probed 2026-09-27 on Mojo 1.1.0):

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


@fieldwise_init
struct CounterSample(Copyable, Movable):
    """One value of a named counter at a time (ROADMAP 17.80): exported as a
    Chrome `C` event, i.e. a counter track in Perfetto."""

    var name: String
    var t_ns: Int
    var value: Int


struct TraceBuffer(Movable):
    """Fixed-capacity buffer of finished spans, plus an open-span stack for
    nesting. `tid` tags every event (for multi-thread Chrome-trace tracks);
    defaults to 0 for a single-threaded caller.

    ROADMAP 17.80: with `-D LUDENS_TRACE` the buffer can also be switched off
    and on at run time (`enabled`; one branch per span when off), keep the
    newest spans instead of the oldest when full (`ring`), and hold counter
    samples (`sample`). Spans opened while disabled are tracked by depth
    only, so toggling between `begin` and `end` never unbalances nesting."""

    var events: List[SpanEvent]
    var capacity: Int
    var dropped: Int
    var _open: List[SpanEvent]
    var _open_depth: List[Int]
    var _depth: Int
    var tid: Int
    var enabled: Bool
    var ring: Bool
    var _head: Int  # ring mode: index of the oldest event once full
    var samples: List[CounterSample]
    var _reported: Int  # `dropped` already handed out by `take_dropped`

    def __init__(out self, capacity: Int, tid: Int = 0):
        self.events = List[SpanEvent](capacity=capacity)
        self.capacity = capacity
        self.dropped = 0
        self._open = List[SpanEvent]()
        self._open_depth = List[Int]()
        self._depth = 0
        self.tid = tid
        self.enabled = True
        self.ring = False
        self._head = 0
        self.samples = List[CounterSample]()
        self._reported = 0

    def begin(mut self, name: String):
        """Push an open span. No-op unless `-D LUDENS_TRACE`."""
        comptime if TRACE_ON:
            self._depth += 1
            if not self.enabled:
                return
            self._open.append(SpanEvent(name, Int(perf_counter_ns()), 0, self.tid))
            self._open_depth.append(self._depth)

    def end(mut self):
        """Close the most recently opened span (LIFO). No-op unless
        `-D LUDENS_TRACE`; also a no-op (not an error) if nothing is open, so
        a stray `end()` on an off build never mismatches."""
        comptime if TRACE_ON:
            if self._depth == 0:
                return
            var d = self._depth
            self._depth -= 1
            if len(self._open) == 0 or self._open_depth[len(self._open_depth) - 1] != d:
                return  # this level was opened while disabled
            _ = self._open_depth.pop()
            var ev = self._open.pop()
            ev.t_end_ns = Int(perf_counter_ns())
            self._push(ev^)

    def add_lanes(mut self, name: String, t_begin: List[Int], t_end: List[Int]) -> Int:
        """Record already-timed work items (ROADMAP 17.80 (c)): items ran on
        anonymous workers of a parallel fan-out, so each is placed on the
        first lane whose last item ended before it began (items sorted by
        start), and lane k becomes thread track `tid + 1 + k` in the Chrome
        export. The lane count is the concurrency the items actually had.
        Returns it (0 when tracing is off). No-op unless `-D LUDENS_TRACE`."""
        comptime if TRACE_ON:
            if not self.enabled:
                return 0
            var n = len(t_begin)
            var order = List[Int](capacity=n)
            for i in range(n):
                order.append(i)
            # insertion sort by start time (fan-outs are small: islands, chunks)
            for i in range(1, n):
                var k = order[i]
                var j = i - 1
                while j >= 0 and t_begin[order[j]] > t_begin[k]:
                    order[j + 1] = order[j]
                    j -= 1
                order[j + 1] = k
            var lane_end = List[Int]()
            for k in order:
                var lane = -1
                for l in range(len(lane_end)):
                    if lane_end[l] <= t_begin[k]:
                        lane = l
                        break
                if lane < 0:
                    lane = len(lane_end)
                    lane_end.append(0)
                lane_end[lane] = t_end[k]
                self._push(SpanEvent(name, t_begin[k], t_end[k], self.tid + 1 + lane))
            return len(lane_end)
        return 0

    def _push(mut self, var ev: SpanEvent):
        if len(self.events) < self.capacity:
            self.events.append(ev^)
        elif self.ring and self.capacity > 0:
            self.events[self._head] = ev^
            self._head = (self._head + 1) % self.capacity
            self.dropped += 1
        else:
            self.dropped += 1

    def sample(mut self, name: String, value: Int):
        """Record a counter value now (17.80). No-op unless `-D LUDENS_TRACE`
        and `enabled`; bounded by `capacity` like spans (drop-newest)."""
        comptime if TRACE_ON:
            if not self.enabled:
                return
            if len(self.samples) < self.capacity:
                self.samples.append(CounterSample(name, Int(perf_counter_ns()), value))
            else:
                self.dropped += 1

    def take_dropped(mut self) -> Int:
        """Drops since the last call -- what a caller adds to its shared
        `Counters` under `TRACE_DROPPED`."""
        var d = self.dropped - self._reported
        self._reported = self.dropped
        return d

    def ordered(self) -> List[Int]:
        """Indices of `events` oldest first (differs from storage order
        only in ring mode after wrapping)."""
        var out = List[Int](capacity=len(self.events))
        var n = len(self.events)
        var start = self._head if (self.ring and n == self.capacity) else 0
        for k in range(n):
            out.append((start + k) % n)
        return out^

    def scoped[origin: MutOrigin, //](
        ref[origin] self, name: String
    ) -> ScopedSpan[origin]:
        """`with trace.scoped("phase"): ...` -- see module docstring for why
        this is `__enter__`/`__exit__`-based rather than `__deinit__`-based."""
        return ScopedSpan[origin](Pointer(to=self), name)

    def clear(mut self):
        self.events.clear()
        self._open.clear()
        self._open_depth.clear()
        self._depth = 0
        self._head = 0
        self.samples.clear()
        self.dropped = 0
        self._reported = 0

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
        var order = self.ordered()
        for k in order:
            ref e = self.events[k]
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
        for ref c in self.samples:
            if not first:
                out += ","
            first = False
            out += '{"name":"' + c.name + '","ph":"C","ts":' + String(c.t_ns // 1000)
            out += ',"pid":0,"args":{"value":' + String(c.value) + "}}"
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
