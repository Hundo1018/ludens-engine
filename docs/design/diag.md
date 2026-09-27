# `diag` package design (17.33 / 17.32 / 17.34 / 17.9 / 17.10)

## Verified toolchain facts (Mojo 1.1.0, probe /tmp/claude-1000/probe_diag, 2026-09-27)
- `get_defined_int["NAME", default]()` / `is_defined["NAME"]()` (std.sys) are evaluated at the
  FINAL compile (`mojo run/build -D NAME=v`), even for non-generic functions inside a
  precompiled `.mojoc` package. → compile-time log level / feature switches work across packages.
- std `debug_assert(cond, msg)` is OFF by default; `-D ASSERT=all` turns it on; failure prints
  `At: file:line:col: Assert Error: msg` and crashes (terminate). → 17.33 uses std debug_assert,
  no custom wrapper for the terminate path. Test runner must pass `-D ASSERT=all`.

## Layering change
diag must be importable by geometry (assertions/counters in math code) → diag is layer 0 with
ZERO engine deps; geometry moves to layer 1, everything else +1. Debug-draw needs points but must
not import geometry: `DrawQueue[dtype: DType]` stores `SIMD[dtype, 4]` — geometry's Vec3 is
`SIMD[WorldType, 4]`, passes straight in (parametric type = Mojo feature, and stays correct if
17.8 switches WorldType to f64).

## No globals: explicit context
Mojo has no safe mutable globals; determinism also forbids hidden state. A `Diag` value is owned by
whoever owns the world (e.g. `ContactScene6.diag`) and passed `mut` to subsystems that emit.

## Modules
- `diag/level.mojo` — `comptime LOG_LEVEL = get_defined_int["LUDENS_LOG_LEVEL", 3]()`
  (0 off,1 error,2 warn,3 info,4 debug,5 trace); `Level` comptime constants.
- `diag/log.mojo` — `LogRecord{tick, level, category: StaticString, msg: String, a: Float64, b: Float64}`;
  `LogRing[capacity: Int]` fixed-capacity ring (Array-backed? List preallocated), drop-oldest vs
  drop-newest policy, `dropped` counter. `log[level: Int](mut ring, cat, msg)` → `comptime if level <= LOG_LEVEL`
  so disabled levels compile to nothing (benchmark: overhead at level off == 0 within noise).
  `dump(ring) -> String` for tests/examples (engine never prints).
- `diag/counters.mojo` — `Counters[n: Int]` = `Array[Int64, n]` indexed by comptime ids;
  standard ids: NAN_QUARANTINED, CCD_BUDGET_EXCEEDED, DRAW_DROPPED, TRACE_DROPPED, LOG_DROPPED, ...
- `diag/trace.mojo` — `TraceBuffer` of span events (name: StaticString, tid, t_begin_ns, t_end_ns);
  `scoped` span via a struct whose `__del__` records end (RAII — Mojo ASAP destruction: must use
  explicit `end()` or `with`-context manager `__enter__/__exit__`; probe which is reliable).
  `to_chrome_json()` → Chrome trace / Perfetto. Compile-time off switch `LUDENS_TRACE`.
- `diag/draw.mojo` — `DrawQueue[dtype]`: line/sphere/box/arrow/text/point commands with color + lifetime
  (frames); `tick()` ages & removes; capacity + drop counter.
- `diag/arena.mojo` (17.34) — `FrameArena` bump allocator over one allocation, `reset()` per frame;
  typed `alloc[T](n) -> Span`; used by DrawQueue / batched queries. Seam: List-per-frame vs arena.

## Wiring (定律 v3 — must be reached by production paths)
- solver6 end-of-step NaN/Inf scan → quarantine body + counter + warn log.
- solver6 emits debug-draw contacts / island colors when a comptime flag `LUDENS_DEBUG_DRAW` is on.
- profiling spans around solver phases (collect pairs / narrowphase / solve / integrate / sleep).
- capacity overflow in queues counts drops.
