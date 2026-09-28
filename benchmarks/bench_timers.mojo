"""`TimerQueue` seam: `TimerHeap` (array binary min-heap) vs `TimerWheel`
(two-level ring) — schedule throughput and advance/drain cost, N = 1e2..1e6.

Table 1 is `schedule()` alone: O(log N) heap push vs O(1) wheel bucket
append, isolated from any `advance()` cost.

Table 2 is the regime `docs/design/wave-a-services.md` 17.35 calls out: N
timers scattered NEAR the current tick (within a 256-tick window, matching
`TimerWheel`'s near-ring size), then one `advance()` call that drains all of
them, ns/timer. This is where the wheel is supposed to win — O(1) bucket
append + O(1) amortized per-tick scan vs the heap's O(log N) per pop — and
is where the crossover N (if any) shows up.

Table 3 holds N fixed and instead sweeps the SCATTER WINDOW — near (256
ticks, inside the wheel's near ring), medium (20000 ticks, forces the far
ring + a cascade), far (300000 ticks, beyond the two-level horizon, the
aliasing-revisit tradeoff documented in `scheduler/timers.mojo`). The heap
does not care where timers are due, only how many are live, so its row
should be flat; the wheel's should not be — that contrast is the honest
half of the seam's story, not just the win.

Run: `flock /tmp/claude-1000/bench.lock pixi run mojo run -I build
benchmarks/bench_timers.mojo` (benchmarks are single-lane on this machine,
docs/design/wave-a-services.md preamble).
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from scheduler.timers import TimerQueue, TimerHeap, TimerWheel, TimerFire
from scheduler.rng import Pcg32, Rng, range_i

def _sizes() -> List[Int]:
    return [100, 1_000, 10_000, 100_000, 1_000_000]


def _fill_scattered[Q: TimerQueue](mut q: Q, n: Int, window: Int, seed: UInt64) raises:
    var rng = Pcg32.seeded(seed)
    for i in range(n):
        var after = range_i(rng, 1, window)
        _ = q.schedule(after, i)


def _bench_schedule[Q: TimerQueue](mut table: BenchTable, variant: String, n: Int) raises:
    var rng = Pcg32.seeded(0xABCDEF)
    var afters = List[Int]()
    for _ in range(n):
        afters.append(range_i(rng, 1, 256))
    var q = Q()
    var t0 = now()
    for i in range(n):
        _ = q.schedule(afters[i], i)
    var t1 = now()
    table.add(variant, n, "schedule", t1 - t0, n)


def _bench_drain[Q: TimerQueue](
    mut table: BenchTable, variant: String, n: Int, window: Int, op: String
) raises:
    var q = Q()
    _fill_scattered[Q](q, n, window, 0x123456)
    var fired = List[TimerFire]()
    var t0 = now()
    q.advance(window, fired)
    var t1 = now()
    keep(len(fired))
    table.add(variant, n, op, t1 - t0, n)


def main() raises:
    var ns = _sizes()

    var t1 = BenchTable("TimerQueue -- schedule() throughput")
    for i in range(len(ns)):
        _bench_schedule[TimerHeap](t1, "heap", ns[i])
        _bench_schedule[TimerWheel](t1, "wheel", ns[i])
    t1.print_report()

    var t2 = BenchTable("TimerQueue -- advance()/drain, N near-due timers (window=256)")
    for i in range(len(ns)):
        _bench_drain[TimerHeap](t2, "heap", ns[i], 256, "drain_near")
        _bench_drain[TimerWheel](t2, "wheel", ns[i], 256, "drain_near")
    t2.print_report()

    comptime N_FIXED = 200_000
    var t3 = BenchTable(
        "TimerQueue -- advance()/drain, N=200000 fixed, scatter window swept"
    )
    _bench_drain[TimerHeap](t3, "heap", N_FIXED, 256, "window_near")
    _bench_drain[TimerWheel](t3, "wheel", N_FIXED, 256, "window_near")
    _bench_drain[TimerHeap](t3, "heap", N_FIXED, 20_000, "window_medium")
    _bench_drain[TimerWheel](t3, "wheel", N_FIXED, 20_000, "window_medium")
    _bench_drain[TimerHeap](t3, "heap", N_FIXED, 300_000, "window_far")
    _bench_drain[TimerWheel](t3, "wheel", N_FIXED, 300_000, "window_far")
    t3.print_report()
