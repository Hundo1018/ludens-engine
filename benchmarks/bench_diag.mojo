"""Benchmarks for `diag/*.mojo` (Phase 17.9 / 17.10 / 17.32 / 17.34).

Four tables:

  (a) log call cost — a disabled level (`Level.TRACE`, above the default
      `LOG_LEVEL=Level.INFO`) vs no call at all vs an enabled level
      (`Level.ERROR`). The zero-cost claim for `diag/log.mojo` is that the
      first two rows land within noise of each other.
  (b) `FrameArena` vs `List`-per-frame over an N sweep (64..65536 records per
      frame) — the regime where per-frame allocation dominates.
  (c) `DrawQueue[dtype]` push+tick throughput.
  (d) trace span overhead around a small workload, traced vs untraced.
      `LUDENS_TRACE` defaults off, so a default run of this file shows the
      OFF cost; rerun as
      `mojo run -D LUDENS_TRACE -I build benchmarks/bench_diag.mojo` for the
      ON numbers — one compiled binary only sees one value of the switch
      (see `diag/trace.mojo`).

Run: `mojo run -I build benchmarks/bench_diag.mojo`.
"""

from std.benchmark import keep
from std.sys import size_of
from harness.bench import BenchTable, now
from diag.level import Level, TRACE_ON
from diag.log import LogRing, log
from diag.arena import FrameArena
from diag.draw import DrawQueue
from diag.trace import TraceBuffer

comptime REPS = 3
comptime TRACE_LABEL = "on" if TRACE_ON else "off"


# --- (a) log call cost: disabled level vs no call vs enabled level ----------


def bench_log(mut t: BenchTable):
    comptime N = 200_000

    # baseline: no diag call at all, same accumulate-a-counter shape.
    var best_none = Int.MAX
    for _ in range(REPS):
        var acc = 0
        var t0 = now()
        for i in range(N):
            acc += i
        var t1 = now()
        keep(acc)
        if t1 - t0 < best_none:
            best_none = t1 - t0
    t.add("no call (baseline)", N, "call", best_none, N)

    # disabled level: TRACE (5) is above the default LOG_LEVEL (INFO=3), so
    # `log[Level.TRACE]`'s body is `comptime if`-eliminated to nothing.
    var best_off = Int.MAX
    for _ in range(REPS):
        var ring = LogRing[N]()
        var t2 = now()
        for i in range(N):
            log[Level.TRACE](ring, i, "bench", "disabled", 0.0, 0.0)
        var t3 = now()
        keep(ring.count())
        if t3 - t2 < best_off:
            best_off = t3 - t2
    t.add("disabled level (TRACE)", N, "call", best_off, N)

    # enabled level: ERROR (1) is always <= LOG_LEVEL, so every call actually
    # builds a LogRecord and pushes it. Ring is sized to N so no call hits the
    # drop branch -- this measures the enabled call path, not the drop path
    # (drops are covered by tests/test_diag_log.mojo's extreme cases).
    var best_on = Int.MAX
    for _ in range(REPS):
        var ring2 = LogRing[N]()
        var t4 = now()
        for i in range(N):
            log[Level.ERROR](ring2, i, "bench", "enabled", 0.0, 0.0)
        var t5 = now()
        keep(ring2.count())
        if t5 - t4 < best_on:
            best_on = t5 - t4
    t.add("enabled level (ERROR)", N, "call", best_on, N)


# --- (b) FrameArena vs List-per-frame ---------------------------------------


@fieldwise_init
struct Rec(Copyable, Movable):
    """A stand-in for a small per-frame scratch record (contact candidate,
    batched-query result, ...) -- shape doesn't matter, only that it is small
    and POD-like, which is the common case for frame-scratch data."""

    var a: Int
    var b: Int
    var d: Float32


def bench_arena_vs_list(mut t: BenchTable, n: Int, frames: Int) raises:
    # naive: a fresh List built (and dropped) every frame.
    var best_list = Int.MAX
    for _ in range(REPS):
        var acc = 0
        var t0 = now()
        for f in range(frames):
            var recs = List[Rec]()
            for i in range(n):
                recs.append(Rec(i, f, Float32(i)))
            acc += len(recs)
        var t1 = now()
        keep(acc)
        if t1 - t0 < best_list:
            best_list = t1 - t0
    t.add("List per-frame", n, "record", best_list, n * frames)

    # FrameArena: one allocation up front, bump-reset every frame.
    var arena = FrameArena(n * size_of[Rec]() + 64)
    var best_arena = Int.MAX
    for _ in range(REPS):
        var acc2 = 0
        var t2 = now()
        for f in range(frames):
            arena.reset()
            var span = arena.alloc[Rec](n)
            for i in range(n):
                span[i] = Rec(i, f, Float32(i))
            acc2 += len(span)
        var t3 = now()
        keep(acc2)
        if t3 - t2 < best_arena:
            best_arena = t3 - t2
    t.add("FrameArena per-frame", n, "record", best_arena, n * frames)


# --- (c) DrawQueue push+tick throughput -------------------------------------


def bench_draw_queue(mut t: BenchTable, n: Int, frames: Int):
    comptime dt = DType.float32
    var white = SIMD[DType.float32, 4](1, 1, 1, 1)
    var best = Int.MAX
    for _ in range(REPS):
        var q = DrawQueue[dt](n)
        var t0 = now()
        for _ in range(frames):
            for i in range(n):
                q.point(SIMD[dt, 4](Scalar[dt](i), 0, 0, 0), white)
            q.tick()
        var t1 = now()
        keep(q.count())
        if t1 - t0 < best:
            best = t1 - t0
    t.add("DrawQueue push+tick", n, "cmd", best, n * frames)


# --- (d) trace span overhead: traced vs untraced ----------------------------
#
# A span in this engine wraps a whole SOLVER PHASE (collect pairs / narrowphase
# / solve / integrate / sleep -- see `.campaign/diag_design.md`), not a single
# scalar op: a handful of spans per frame, each covering real work. So the
# fair comparison is per-PHASE overhead against a representative phase size,
# not per-element -- wrapping a single `%` in a span would make ANY profiler's
# overhead look enormous and would not be how this gets used.


def _phase_work(mut acc: Int, base: Int, count: Int):
    for i in range(count):
        acc += (base + i) * (base + i) % 97


def bench_trace_overhead(mut t: BenchTable, spans: Int, work_per_span: Int) raises:
    var total = spans * work_per_span
    var trace = TraceBuffer(spans + 8)
    var best_traced = Int.MAX
    var acc = 0
    for _ in range(REPS):
        var t0 = now()
        for sidx in range(spans):
            with trace.scoped("phase"):
                _phase_work(acc, sidx, work_per_span)
        var t1 = now()
        if t1 - t0 < best_traced:
            best_traced = t1 - t0
    keep(acc)
    t.add("traced (" + TRACE_LABEL + ")", total, "op", best_traced, total)

    var best_plain = Int.MAX
    var acc2 = 0
    for _ in range(REPS):
        var t2 = now()
        for sidx in range(spans):
            _phase_work(acc2, sidx, work_per_span)
        var t3 = now()
        if t3 - t2 < best_plain:
            best_plain = t3 - t2
    keep(acc2)
    t.add("untraced baseline", total, "op", best_plain, total)


def main() raises:
    var t1 = BenchTable(
        "diag: log call cost -- disabled level vs no call vs enabled level"
    )
    bench_log(t1)
    t1.print_report()

    var t2 = BenchTable(
        "diag: FrameArena vs List-per-frame (N sweep, allocation-dominated"
        " regime)"
    )
    var ns = [64, 256, 1024, 4096, 16384, 65536]
    var frames_for = [400, 400, 200, 100, 50, 20]
    for i in range(len(ns)):
        bench_arena_vs_list(t2, ns[i], frames_for[i])
    t2.print_report()

    var t3 = BenchTable("diag: DrawQueue push+tick throughput")
    bench_draw_queue(t3, 10000, 50)
    t3.print_report()

    var t4 = BenchTable(
        "diag: trace span overhead per solver-phase-sized span, traced ("
        + TRACE_LABEL
        + ") vs untraced -- rerun with -D LUDENS_TRACE for the other value"
    )
    bench_trace_overhead(t4, 2000, 20_000)
    t4.print_report()
