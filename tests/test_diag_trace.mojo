# tier: unit
"""`TraceBuffer` contract: scoped `with` spans, nesting, per-name stats,
Chrome-trace JSON export, capacity/drop counting, and the compile-time
`LUDENS_TRACE` switch.

`LUDENS_TRACE` defaults OFF, and a single compiled test binary can only see
one value of that switch -- so this file branches on `TRACE_ON` itself
(`comptime if`) rather than picking one behavior, and is meaningful (and
passes) either way `pixi run mojo run -I build tests/test_diag_trace.mojo` is
invoked:

  * default (no `-D` flag, what `pixi run test` runs): proves the DISABLED
    case -- `begin`/`end`/`scoped` record nothing, matching `diag/log.mojo`'s
    "a disabled level/switch does no work" contract.
  * `-D LUDENS_TRACE` (what the acceptance run for this file also exercises
    manually, alongside `benchmarks/bench_diag.mojo`'s on-vs-off numbers):
    proves the ENABLED case -- real timestamps, correct LIFO nesting order,
    `stats()` aggregation, Chrome-trace JSON shape, and capacity/drop
    counting with real events.
"""

from harness.runner import Suite
from diag.level import TRACE_ON
from diag.trace import TraceBuffer


def main() raises:
    var s = Suite("diag_trace")

    # --- flag-independent: a fresh/empty buffer never crashes ---
    var t0 = TraceBuffer(16)
    s.eqi(len(t0.events), 0, "0 events: fresh buffer is empty")
    var stats0 = t0.stats()
    s.eqi(len(stats0), 0, "0 events: stats() empty")
    s.check(t0.to_chrome_json() == "[]", "0 events: chrome json is an empty array")
    t0.end()  # stray end() with nothing open must never crash, on or off.
    s.eqi(len(t0.events), 0, "stray end() with nothing open is a safe no-op")

    comptime if TRACE_ON:
        # --- ordinary + nesting: outer wraps inner, LIFO begin/end order ---
        var t = TraceBuffer(16)
        with t.scoped("outer"):
            with t.scoped("inner"):
                pass
        s.eqi(len(t.events), 2, "enabled: both spans recorded")
        # inner closes before outer (LIFO), so inner is appended first.
        s.check(t.events[0].name == "inner", "enabled: inner closes (and is recorded) first")
        s.check(t.events[1].name == "outer", "enabled: outer closes (and is recorded) second")
        s.check(t.events[0].t_begin_ns >= t.events[1].t_begin_ns, "enabled: inner starts no earlier than outer")
        s.check(t.events[0].t_end_ns <= t.events[1].t_end_ns, "enabled: inner ends no later than outer")

        # --- explicit begin/end form, same underlying stack ---
        t.begin("manual")
        t.end()
        s.eqi(len(t.events), 3, "enabled: explicit begin/end recorded a span")

        # --- stats(): two spans named "repeat", aggregated count/total/max ---
        var t2 = TraceBuffer(16)
        with t2.scoped("repeat"):
            pass
        with t2.scoped("repeat"):
            pass
        var stats = t2.stats()
        s.eqi(len(stats), 1, "stats: one distinct name aggregates to one row")
        s.eqi(stats[0].count, 2, "stats: count is 2 for two spans of the same name")
        s.check(stats[0].total_ns >= 0, "stats: total_ns is nonnegative")
        s.check(stats[0].max_ns >= 0, "stats: max_ns is nonnegative")

        # --- to_chrome_json(): well-formed enough to carry the span name ---
        var j = t2.to_chrome_json()
        s.check(j[byte=0] == "[", "chrome json: starts with '['")
        s.check("repeat" in j, "chrome json: contains the span name")
        s.check('"ph":"X"' in j, "chrome json: complete-event phase marker present")

        # --- extreme: exactly-full, then overflow drop-newest + count ---
        var full = TraceBuffer(2)
        with full.scoped("a"):
            pass
        with full.scoped("b"):
            pass
        s.eqi(len(full.events), 2, "exactly-full: both spans stored")
        s.eqi(full.dropped, 0, "exactly-full: nothing dropped yet")
        with full.scoped("c"):
            pass
        s.eqi(len(full.events), 2, "overflow: count stays at capacity")
        s.eqi(full.dropped, 1, "overflow: exactly one drop counted")

        # --- clear() resets events, open stack, and drop count ---
        full.clear()
        s.eqi(len(full.events), 0, "clear: events reset")
        s.eqi(full.dropped, 0, "clear: dropped reset")
    else:
        # --- disabled by default: begin/end and scoped/with record nothing ---
        var t = TraceBuffer(16)
        t.begin("manual")
        t.end()
        s.eqi(len(t.events), 0, "disabled: manual begin/end recorded nothing")
        with t.scoped("phase"):
            pass
        s.eqi(len(t.events), 0, "disabled: scoped with-block recorded nothing")
        t.begin("outer")
        with t.scoped("inner"):
            pass
        t.end()
        s.eqi(len(t.events), 0, "disabled: nested manual+with spans still record nothing")

    s.finish()
