"""False sharing: what cache-line contention costs, and when it is invisible.

The core-scaling curves (`bench_islands`, `bench_colored`) showed the solver
saturating near 1.5-1.6x. Amdahl accounts for most of it (only ~40% of a step
is inside the parallel region); this benchmark answers the other half of the
question — whether the parallel region itself pays for coherence traffic.

Every row does the SAME work and produces the SAME totals (checked at the end
of the run). Only the *address spacing* of the per-worker accumulators moves:

  stride 1  — accumulators packed adjacently: up to 8 workers land on one
              64-byte line, so each write invalidates that line in every other
              core's cache. No logical conflict at all — pure false sharing.
  stride 2  — 4 accumulators per line.
  stride 8  — exactly one accumulator per line: contention eliminated.
  stride 16 — one per two lines, present to show that stride 8 is already
              enough. If 16 is no better than 8, the effect is a cache-line
              property and not a "wider is always better" gradient.

Three access families, because HOW the write is emitted decides whether the
contention is even observable:

  atomic  — `Atomic.fetch_add` on the shared slot. Every increment must own
            the line, so this is the honest measurement of the effect.
  plain   — a non-atomic `p[i] += v` in a loop. The compiler is free to keep
            the accumulator in a register and write back once, which collapses
            thousands of contended stores into one. Rows are included because
            the NULL RESULT is the point: a naive false-sharing microbenchmark
            measures the optimizer, not the hardware.
  local   — accumulate in a local, store once at the end. The pattern every
            parallel kernel should actually use, and the reason well-written
            fan-out code is usually immune to this whole class of problem.
"""

from std.algorithm import parallelize
from std.atomic import Atomic
from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable

comptime LINE_INTS = 8  # 64-byte cache line / 8-byte Int64
comptime ITERS = 20000
comptime REPS = 5

comptime MODE_ATOMIC = 0
comptime MODE_PLAIN = 1
comptime MODE_LOCAL = 2


def _run(workers: Int, stride: Int, mode: Int) raises -> Int:
    var slots = List[Int64]()
    for _ in range(workers * stride + LINE_INTS):
        slots.append(0)
    var p = slots.unsafe_ptr()

    @parameter
    def body(w: Int):
        var base = p + w * stride
        if mode == MODE_ATOMIC:
            for k in range(ITERS):
                _ = Atomic.fetch_add(base, Int64((w + k) & 3))
        elif mode == MODE_PLAIN:
            for k in range(ITERS):
                base[0] += Int64((w + k) & 3)
        else:
            var acc = Int64(0)
            for k in range(ITERS):
                acc += Int64((w + k) & 3)
            base[0] = acc

    var best = Int.MAX
    for _ in range(REPS):
        for i in range(len(slots)):
            slots[i] = 0
        var t0 = Int(perf_counter_ns())
        parallelize[body](workers, workers)
        var t1 = Int(perf_counter_ns())
        if t1 - t0 < best:
            best = t1 - t0
    var total = Int64(0)
    for w in range(workers):
        total += slots[w * stride]
    keep(total)
    return best


def _expected(workers: Int) -> Int64:
    var total = Int64(0)
    for w in range(workers):
        for k in range(ITERS):
            total += Int64((w + k) & 3)
    return total


def _verify(workers: Int, stride: Int, mode: Int) raises -> Bool:
    var slots = List[Int64]()
    for _ in range(workers * stride + LINE_INTS):
        slots.append(0)
    var p = slots.unsafe_ptr()

    @parameter
    def body(w: Int):
        var base = p + w * stride
        if mode == MODE_ATOMIC:
            for k in range(ITERS):
                _ = Atomic.fetch_add(base, Int64((w + k) & 3))
        elif mode == MODE_PLAIN:
            for k in range(ITERS):
                base[0] += Int64((w + k) & 3)
        else:
            var acc = Int64(0)
            for k in range(ITERS):
                acc += Int64((w + k) & 3)
            base[0] = acc

    parallelize[body](workers, workers)
    var got = Int64(0)
    for w in range(workers):
        got += slots[w * stride]
    return got == _expected(workers)


def main() raises:
    var t = BenchTable(
        "false sharing: per-worker accumulators at increasing address stride"
    )
    var widths = List[Int]()
    widths.append(2)
    widths.append(4)
    widths.append(8)
    widths.append(12)

    var strides = List[Int]()
    strides.append(1)
    strides.append(2)
    strides.append(8)
    strides.append(16)

    for wi in range(len(widths)):
        var w = widths[wi]
        for si in range(len(strides)):
            var s = strides[si]
            var tag = " (1/line)" if s == LINE_INTS else ""
            t.add(
                "atomic  w=" + String(w) + " stride=" + String(s) + tag,
                w, "incr", _run(w, s, MODE_ATOMIC), ITERS,
            )
        # the same sweep with plain stores, to show it measures the optimizer
        t.add(
            "plain   w=" + String(w) + " stride=1",
            w, "incr", _run(w, 1, MODE_PLAIN), ITERS,
        )
        t.add(
            "plain   w=" + String(w) + " stride=8 (1/line)",
            w, "incr", _run(w, LINE_INTS, MODE_PLAIN), ITERS,
        )
        t.add(
            "local   w=" + String(w) + " (store once)",
            w, "incr", _run(w, 1, MODE_LOCAL), ITERS,
        )
    t.print_report()

    var ok = True
    for wi in range(len(widths)):
        var w = widths[wi]
        for si in range(len(strides)):
            if not _verify(w, strides[si], MODE_ATOMIC):
                ok = False
                print("  MISMATCH atomic w=", w, " stride=", strides[si])
        if not _verify(w, 1, MODE_LOCAL):
            ok = False
            print("  MISMATCH local w=", w)
    print("  every stride agrees on the total (atomic + local):", ok)
