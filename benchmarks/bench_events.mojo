"""Gameplay event bus seam (17.38): `Channel[E]` (pull, production) vs
`PushChannel[E]` (fan-out, comparison partner) — readers x events per frame.

Table 1 fixes N_EVENTS events sent per frame and sweeps the READER COUNT:
pull's per-frame cost is dominated by each reader's O(events since its
cursor) drain -- a sequence-number comparison per buffered event, per reader,
paid at `read()` time; push's is dominated by O(readers) COPIES made at
`send()` time, once per event, before any reader ever calls `read()`. Both
still visit every (reader, event) pair exactly once per frame -- the
difference is WHEN that work happens and its constant factor, not the
asymptotic total, which is why this table reports a ratio rather than
claiming one is asymptotically better.

Table 2 fixes the reader count and sweeps EVENTS PER FRAME, 1e2..1e6.

Run: `flock /tmp/claude-1000/bench.lock pixi run mojo run -I build
benchmarks/bench_events.mojo` (benchmarks are single-lane on this machine,
docs/design/wave-a-services.md preamble).
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from scheduler.events import Channel, PushChannel


@fieldwise_init
struct Evt(Copyable, Deinitable, Movable):
    var seq: Int


comptime FRAMES = 10


def _run_pull(events_per_frame: Int, readers: Int) raises -> Int:
    var ch = Channel[Evt]()
    var handles = List[Int]()
    for _ in range(readers):
        handles.append(ch.register_reader())
    var delivered = 0
    var t0 = now()
    for _ in range(FRAMES):
        for k in range(events_per_frame):
            ch.send(Evt(k))
        ch.update()
        for r in range(readers):
            var out = List[Evt]()
            ch.read(handles[r], out)
            delivered += len(out)
    var t1 = now()
    keep(delivered)
    return t1 - t0


def _run_push(events_per_frame: Int, readers: Int) raises -> Int:
    var ch = PushChannel[Evt]()
    var handles = List[Int]()
    for _ in range(readers):
        handles.append(ch.register_reader())
    var delivered = 0
    var t0 = now()
    for _ in range(FRAMES):
        for k in range(events_per_frame):
            ch.send(Evt(k))
        for r in range(readers):
            var out = List[Evt]()
            ch.read(handles[r], out)
            delivered += len(out)
    var t1 = now()
    keep(delivered)
    return t1 - t0


def _reader_counts() -> List[Int]:
    return [1, 2, 4, 8, 16, 32]


def _event_counts() -> List[Int]:
    return [100, 1_000, 10_000, 100_000, 1_000_000]


def bench_readers(mut table: BenchTable) raises:
    comptime EVENTS_T1 = 1000
    var rs = _reader_counts()
    for i in range(len(rs)):
        var readers = rs[i]
        var iters = EVENTS_T1 * readers * FRAMES
        var ns_pull = _run_pull(EVENTS_T1, readers)
        table.add("pull", readers, "delivery", ns_pull, iters)
        var ns_push = _run_push(EVENTS_T1, readers)
        table.add("push", readers, "delivery", ns_push, iters)


def bench_events_per_frame(mut table: BenchTable) raises:
    comptime READERS_T2 = 4
    var ns = _event_counts()
    for i in range(len(ns)):
        var n = ns[i]
        var iters = n * READERS_T2 * FRAMES
        var ns_pull = _run_pull(n, READERS_T2)
        table.add("pull", n, "delivery", ns_pull, iters)
        var ns_push = _run_push(n, READERS_T2)
        table.add("push", n, "delivery", ns_push, iters)


def main() raises:
    # Warm up the allocator/branch predictor before the first real row --
    # otherwise the very first configuration measured in the process pays a
    # one-time cold-start cost indistinguishable from a real result (seen
    # directly: readers=1 read ~38 ns/op before this warmup was added,
    # against ~4 ns/op for every other reader count in the same table).
    _ = _run_pull(1000, 1)
    _ = _run_push(1000, 1)

    var t1 = BenchTable("Event bus -- 1000 events/frame, reader count swept")
    bench_readers(t1)
    t1.print_report()

    var t2 = BenchTable("Event bus -- 4 readers, events/frame swept 1e2..1e6")
    bench_events_per_frame(t2)
    t2.print_report()
