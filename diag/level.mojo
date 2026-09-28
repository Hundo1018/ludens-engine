"""Compile-time log level and trace switches (Phase 17.32 / 17.10 foundation).

Verified on Mojo 1.1.0 / modular 26.6.0 (probed 2026-09-27):
`get_defined_int["NAME", default]()`
and `is_defined["NAME"]()` from `std.sys` are resolved at the FINAL `mojo run`/
`mojo build` invocation, even for code living inside a precompiled `.mojoc`
package built earlier by `scripts/build_engine.sh`. That is what makes a single
project-wide `-D LUDENS_LOG_LEVEL=N` / `-D LUDENS_TRACE` flag able to reach into
`diag`'s precompiled package and flip every `comptime if` gated on `LOG_LEVEL`/
`TRACE_ON` below, everywhere in the engine, with no rebuild of `diag` itself.

`LOG_LEVEL`/`TRACE_ON` are `comptime` values, not mutable globals: they are
baked in at compile time and never change at runtime, so they don't violate the
"no global mutable state" rule in `docs/ARCHITECTURE.md` -- there is nothing to
mutate.

Default level is `INFO` (3): error/warn/info calls compile in, debug/trace are
compiled out unless the caller passes `-D LUDENS_LOG_LEVEL=4` or `5`. Trace
spans default OFF (opt-in via `-D LUDENS_TRACE`) because even a compiled-out
span still costs a struct construction plus two method calls (see
`diag/trace.mojo` and `benchmarks/bench_diag.mojo`), unlike a disabled log call
which costs exactly nothing (see `diag/log.mojo`).
"""

from std.sys import get_defined_int, is_defined


struct Level:
    """Severity/verbosity levels, lowest to highest volume. `LOG_LEVEL` is the
    highest level that is COMPILED IN; a `log[level](...)` call site with
    `level > LOG_LEVEL` has an empty function body after `comptime if`."""

    comptime OFF: Int = 0
    comptime ERROR: Int = 1
    comptime WARN: Int = 2
    comptime INFO: Int = 3
    comptime DEBUG: Int = 4
    comptime TRACE: Int = 5


comptime LOG_LEVEL: Int = get_defined_int["LUDENS_LOG_LEVEL", Level.INFO]()
"""Highest compiled-in log level for this build. `-D LUDENS_LOG_LEVEL=5` compiles
in everything including TRACE; `-D LUDENS_LOG_LEVEL=0` compiles out all of it."""

comptime TRACE_ON: Bool = is_defined["LUDENS_TRACE"]()
"""Whether `diag/trace.mojo` spans record anything. Off by default."""

comptime DEBUG_DRAW_ON: Bool = is_defined["LUDENS_DEBUG_DRAW"]()
"""Whether solver-owned debug-draw emission (ROADMAP 17.0h) runs at all.
Off by default -- gates a `comptime if` around the whole emit call, so a
release build without `-D LUDENS_DEBUG_DRAW` pays nothing beyond the
`DrawQueue` field itself sitting empty."""


def level_name(level: Int) -> String:
    """Render a `Level` constant for `LogRing.dump()`. Engine code never prints
    directly (`docs/ARCHITECTURE.md` §2 rule 1) -- this only formats a String
    for a test/example/dump to print."""
    if level == Level.OFF:
        return "OFF"
    elif level == Level.ERROR:
        return "ERROR"
    elif level == Level.WARN:
        return "WARN"
    elif level == Level.INFO:
        return "INFO"
    elif level == Level.DEBUG:
        return "DEBUG"
    elif level == Level.TRACE:
        return "TRACE"
    else:
        return "UNKNOWN(" + String(level) + ")"
