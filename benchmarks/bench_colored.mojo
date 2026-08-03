"""Within-island parallelism: graph-colored sweeps vs plain Gauss-Seidel.

One box pyramid is ONE island, so island-parallelism (bench_islands) gets
nothing there; coloring parallelises inside it. `test_colored` proves the
colored schedule is deterministic and thread-count-invariant; this table
shows what the worker threads buy on a big single island — and what the
schedule + fan-out overhead costs on a small one (honesty row).
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)
comptime STEPS = 60  # settle phase: all bodies awake (sleep would skew rows)


def _pyramid(rows: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 60, 1, 60)),
        Vec3(60, 1, 60),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(rows):
        for j in range(rows - i):
            var x = Real(j) * 0.52 + Real(i) * 0.26 - Real(rows) * 0.26
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    return sc^


def _run(
    mut sc: ContactScene6[QuatBody6],
    par: Bool,
    col: Bool,
    its: Int,
    workers: Int = 0,
) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(
            DT, G, iters=its, parallel=par, colored=col, workers=workers
        )
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("single big island: plain GS vs colored (threads)")
    var rows = 15
    var n = rows * (rows + 1) // 2
    var s0 = _pyramid(rows)
    t.add("serial GS it4 " + String(n), n, "step", _run(s0, False, False, 4), STEPS)
    var c0 = _pyramid(rows)
    t.add("colored serial it4 " + String(n), n, "step", _run(c0, False, True, 4), STEPS)
    var p0 = _pyramid(rows)
    t.add("colored par it4 " + String(n), n, "step", _run(p0, True, True, 4), STEPS)
    # quality-matched row: the colored schedule needs ~2x iterations to
    # converge as well as the serial wavefront (else residual jitter keeps
    # the island awake — see test_colored's sleep gate)
    var q0 = _pyramid(rows)
    t.add("colored par it8 " + String(n), n, "step", _run(q0, True, True, 8), STEPS)
    # small island: schedule + fan-out overhead (honesty row)
    var s1 = _pyramid(6)
    t.add("serial GS it4 21", 21, "step", _run(s1, False, False, 4), STEPS)
    var p1 = _pyramid(6)
    t.add("colored par it4 21", 21, "step", _run(p1, True, True, 4), STEPS)
    t.print_report()

    # ---- core-scaling curve on the colored (within-island) axis ------------
    # Different parallel structure from bench_islands: there the unit of work
    # is a whole island, here it is one pair inside a color, so the fan-out is
    # finer-grained and re-entered once per color per iteration. Comparing the
    # two curves shows what task granularity costs.
    comptime REPS = 3
    var cs = BenchTable(
        "colored solver core scaling: one big island at pinned worker counts"
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

    # `rows` is passed in rather than captured: a nested def cannot infer the
    # capture convention of an outer `var` on this nightly.
    def _best(par: Bool, workers: Int, r: Int) raises -> Int:
        var best = Int.MAX
        for _ in range(REPS):
            var sc = _pyramid(r)
            var ns = _run(sc, par, True, 4, workers)
            if ns < best:
                best = ns
        return best

    cs.add("colored serial (no fan-out)", n, "step", _best(False, 0, rows), STEPS)
    for wi in range(len(widths)):
        var w = widths[wi]
        cs.add("workers=" + String(w), n, "step", _best(True, w, rows), STEPS)
    cs.print_report()
