"""Leveled + categorized log ring, fixed capacity, drop counting (Phase 17.32).

`docs/ARCHITECTURE.md` §2 rule 1: engine packages never `print`. `LogRing`
accumulates records instead; a test, example or (later) an in-game console
reads `dump()` and prints it. `log[level](...)` is the write path: `level` is
a bracket parameter, not a runtime argument, so `comptime if level <= LOG_LEVEL`
(from `diag/level.mojo`) can make a disabled call's body EMPTY at compile time
-- verified zero-cost in `benchmarks/bench_diag.mojo`'s log table (a call at a
disabled level costs the same as no call at all, within noise).

`LogRecord` carries two raw `Float64` payload slots (`a`, `b`) instead of
asking every call site to format a message string with interpolated numbers.
Formatting happens once, in `dump()`, not on every hot-path call -- consistent
with `String.format`/t-strings being fine to use OFF the hot path.

Capacity policy: **drop-newest**, matching the general "capacity/budget
overflow" row in `docs/ARCHITECTURE.md` §2 (drop the thing that didn't fit,
count it, never silently lose the count). This ring does NOT overwrite the
oldest record when full, despite the "ring" name -- the alternative
(drop-oldest / overwrite, so the ring always holds the MOST RECENT N records)
was considered and rejected here: drop-newest keeps `dump()`'s order stable
across a test run (the first `capacity` records are always exactly the first
`capacity` records logged, regardless of how many more arrived after), which
is what the extreme-case tests in `tests/test_diag_log.mojo` assert. A
drop-oldest variant would be a legitimate alternate policy for a live
in-game console (recent history matters more than the start of the run) but
is not needed by any current caller, so it is not built speculatively (project
"no tech exclusion" principle taken seriously in the other direction: this
would be a second policy with no consumer, not a proven capability).

Storage is a `List[LogRecord]` preallocated to `capacity` via
`List(capacity=...)`, not `Array[LogRecord, capacity]`: `Array(fill=...)` needs
a default `LogRecord` to fill unused slots with, and a log ring that emits
occasionally has no natural default record. `List(capacity=n)` reserves the
identical backing allocation up front with zero reallocation as long as the
drop-newest cap above is respected, so there is no perf difference -- only one
fewer required-but-meaningless default value.
"""

from .level import LOG_LEVEL, level_name


@fieldwise_init
struct LogRecord(Copyable, Movable, Writable):
    var tick: Int
    var level: Int
    var category: String
    var message: String
    var a: Float64
    var b: Float64

    def write_to(self, mut writer: Some[Writer]):
        writer.write("[", self.tick, "] ", level_name(self.level))
        writer.write("/", self.category, ": ", self.message)
        if self.a != 0.0 or self.b != 0.0:
            writer.write(" (a=", self.a, " b=", self.b, ")")


struct LogRing[capacity: Int](Movable):
    """Fixed-capacity, drop-newest ring of `LogRecord`. `capacity` is a
    compile-time parameter so the backing `List` is reserved once and never
    reallocates for the life of the ring (as long as callers don't exceed it --
    exceeding it is exactly what `dropped` is for)."""

    var records: List[LogRecord]
    var dropped: Int

    def __init__(out self):
        self.records = List[LogRecord](capacity=Self.capacity)
        self.dropped = 0

    def push(mut self, var record: LogRecord):
        if len(self.records) < Self.capacity:
            self.records.append(record^)
        else:
            self.dropped += 1

    def clear(mut self):
        self.records.clear()
        self.dropped = 0

    def count(self) -> Int:
        return len(self.records)

    def dump(self) -> String:
        """Render every retained record, one per line, plus a trailing drop
        count if any records were dropped. Callers print this themselves --
        see the module docstring for why `LogRing` itself never prints."""
        var out = String("")
        for ref r in self.records:
            out += String(r) + "\n"
        if self.dropped > 0:
            out += "(" + String(self.dropped) + " dropped)\n"
        return out^


def log[cap: Int, //, level: Int](
    mut ring: LogRing[cap],
    tick: Int,
    category: String,
    message: String,
    a: Float64 = 0.0,
    b: Float64 = 0.0,
):
    """Log at a compile-time `level` (use `Level.ERROR`/`.WARN`/etc from
    `diag/level.mojo`). When `level > LOG_LEVEL`, this function's body is
    `comptime if`-eliminated entirely: no record is built, no bounds check
    runs, nothing is pushed -- the call costs exactly what an empty function
    call costs, which `benchmarks/bench_diag.mojo` shows is indistinguishable
    from not calling it at all."""
    comptime if level <= LOG_LEVEL:
        ring.push(LogRecord(tick, level, category, message, a, b))
