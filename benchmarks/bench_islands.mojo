"""Island-parallel solver: serial vs threaded on a many-island scene.

16 separated 4-box towers = 16 independent islands (64 dynamic bodies).
`test_islands_par` proves the two paths are bit-identical; the first table
shows what the worker threads buy (and what they cost on a single big island,
where there is nothing to parallelise — honesty row).

The second table is the CORE-SCALING (Amdahl) curve: the same 16-island scene
solved with the fan-out width pinned to 1, 2, 4, 6, 8, 12, 16 and 20 workers.
`workers` changes only the schedule — every width is bit-identical to serial
(gated in `test_islands_par`) — so the curve compares one computation at
different widths rather than different computations. Speedup is read against
the `workers=1` row.

Read the shape against the host topology: this is an i7-1280P, 6 P-cores
(12 threads) + 8 E-cores = 20 logical CPUs, so perfect linear scaling is not
the expected result past the P-core count — the E-cores are slower, and with
16 islands over N workers the partition also stops dividing evenly.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 300


def _towers(n_towers: Int, height: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 100, 1, 100)),
        Vec3(100, 1, 100),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for t in range(n_towers):
        var x = Real(t) * 3
        for i in range(height):
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    return sc^


def _run(
    mut sc: ContactScene6[QuatBody6], parallel: Bool, workers: Int = 0
) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, parallel=parallel, workers=workers)
    return Int(perf_counter_ns()) - t0


def main() raises:
    # The FIRST parallelize in a process pays worker-pool creation. That cost
    # lands entirely on whichever row is timed first and survives min-of-reps,
    # which silently inflated the workers=1 point in an earlier revision. Burn
    # it before any timing so every row starts from a live pool.
    var warm = _towers(16, 4)
    _ = _run(warm, True, 4)

    var t = BenchTable("island-parallel solver: serial vs threads")
    # many small islands: the parallel win case
    var s16 = _towers(16, 4)
    t.add("serial 16 towers x4", 64, "step", _run(s16, False), STEPS)
    var p16 = _towers(16, 4)
    t.add("parallel 16 towers x4", 64, "step", _run(p16, True), STEPS)
    # one big island: nothing to parallelise (thread overhead honesty row)
    var s1 = _towers(1, 8)
    t.add("serial 1 tower x8", 8, "step", _run(s1, False), STEPS)
    var p1 = _towers(1, 8)
    t.add("parallel 1 tower x8", 8, "step", _run(p1, True), STEPS)
    t.print_report()

    # ---- core-scaling (Amdahl) curve on the 16-island scene ----------------
    var cs = BenchTable(
        "island-parallel core scaling: 16 islands at pinned worker counts"
    )
    var widths = List[Int]()
    widths.append(1)
    widths.append(2)
    widths.append(4)
    widths.append(6)
    widths.append(8)
    widths.append(12)
    widths.append(16)
    widths.append(20)
    # serial baseline in the same table, so the thread-launch tax at
    # workers=1 (fan-out with no parallelism to win) is visible too.
    # min-of-REPS: a scaling curve is read point-to-point, so per-point
    # scheduler noise would masquerade as curve shape. The scene has to be
    # rebuilt per run (step_soft mutates it), so this cannot use `measure`.
    comptime REPS = 3

    def _best(parallel: Bool, workers: Int) raises -> Int:
        var best = Int.MAX
        for _ in range(REPS):
            var sc = _towers(16, 4)
            var ns = _run(sc, parallel, workers)
            if ns < best:
                best = ns
        return best

    cs.add("serial (no fan-out)", 64, "step", _best(False, 0), STEPS)
    for wi in range(len(widths)):
        var w = widths[wi]
        cs.add("workers=" + String(w), 64, "step", _best(True, w), STEPS)
    cs.print_report()
