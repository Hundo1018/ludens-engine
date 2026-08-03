"""Work stealing vs static fan-out: what dynamic load balancing is worth.

`std.algorithm.parallelize` decides the split before any task runs, so a round
costs as much as the unluckiest block. `ws_parallel_for` starts from the same
split but lets idle workers drain other ranges (`test_workstealing` proves
every index still runs exactly once).

The comparison only means something against a COST DISTRIBUTION, so the same
task count is run three ways:

  uniform  — every task costs the same. Static partitioning is already optimal
             here, so this row prices what stealing's atomics cost when there
             is nothing to rebalance. It is the honesty row.
  skewed   — cost rises linearly with the index, the classic triangular
             workload: the worker holding the high block does far more work.
  spiky    — a handful of very expensive tasks scattered among cheap ones,
             which is what a physics island list actually looks like when one
             island is a big stack and the rest are single boxes.

Read `static` against `stealing` within a row; `serial` is the reference for
whether threading paid for itself at all.
"""

from std.algorithm import parallelize
from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from scheduler.workstealing import ws_parallel_for

comptime N = 512
comptime REPS = 5

comptime COST_UNIFORM = 0
comptime COST_SKEWED = 1
comptime COST_SPIKY = 2


def _cost(i: Int, kind: Int) -> Int:
    """Iteration count for task `i` under a cost distribution."""
    if kind == COST_UNIFORM:
        return 4000
    elif kind == COST_SKEWED:
        return 40 + i * 30  # triangular: last task ~380x the first
    else:
        # spiky: ~3% of tasks are 60x the rest
        return 60000 if (i % 32) == 0 else 1000


def _spin(i: Int, kind: Int) -> Int:
    var acc = 0
    for k in range(_cost(i, kind)):
        acc += (i + k) & 3
    return acc


def _run_serial(kind: Int) raises -> Int:
    var sink = List[Int]()
    for _ in range(N):
        sink.append(0)
    var p = sink.unsafe_ptr()
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for i in range(N):
            p[i] = _spin(i, kind)
        var t1 = Int(perf_counter_ns())
        if t1 - t0 < best:
            best = t1 - t0
    keep(p[0])
    return best


def _run_static(kind: Int, workers: Int) raises -> Int:
    var sink = List[Int]()
    for _ in range(N):
        sink.append(0)
    var p = sink.unsafe_ptr()

    @parameter
    def body(i: Int):
        p[i] = _spin(i, kind)

    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        parallelize[body](N, workers)
        var t1 = Int(perf_counter_ns())
        if t1 - t0 < best:
            best = t1 - t0
    keep(p[0])
    return best


def _run_steal(kind: Int, workers: Int) raises -> Int:
    var sink = List[Int]()
    for _ in range(N):
        sink.append(0)
    var p = sink.unsafe_ptr()

    @parameter
    def body(i: Int):
        p[i] = _spin(i, kind)

    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        ws_parallel_for[body](N, workers)
        var t1 = Int(perf_counter_ns())
        if t1 - t0 < best:
            best = t1 - t0
    keep(p[0])
    return best


def _warmup() raises:
    """The FIRST parallelize in a process pays worker-pool creation, which
    lands entirely on whichever row happens to be timed first and survives
    min-of-reps. Burn it here so every row below starts from a live pool."""
    var junk = List[Int]()
    for _ in range(64):
        junk.append(0)
    var jp = junk.unsafe_ptr()

    @parameter
    def w_body(i: Int):
        var acc = 0
        for k in range(2000):
            acc += (i + k) & 3
        jp[i] = acc

    for _ in range(3):
        parallelize[w_body](64, 16)
    keep(jp[0])


def main() raises:
    _warmup()
    var kinds = List[Int]()
    kinds.append(COST_UNIFORM)
    kinds.append(COST_SKEWED)
    kinds.append(COST_SPIKY)

    var names = List[String]()
    names.append("uniform")
    names.append("skewed")
    names.append("spiky")

    var widths = List[Int]()
    widths.append(2)
    widths.append(4)
    widths.append(8)
    widths.append(12)

    var t = BenchTable(
        "work stealing vs static fan-out, by task-cost distribution"
    )
    for ki in range(len(kinds)):
        var kind = kinds[ki]
        var nm = names[ki]
        t.add(nm + " serial", N, "task", _run_serial(kind), N)
        for wi in range(len(widths)):
            var w = widths[wi]
            t.add(
                nm + " static   w=" + String(w), N, "task",
                _run_static(kind, w), N,
            )
            t.add(
                nm + " stealing w=" + String(w), N, "task",
                _run_steal(kind, w), N,
            )
    t.print_report()
