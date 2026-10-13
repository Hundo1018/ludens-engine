# tier: unit
"""`harness.bench.measure_ab` (ROADMAP 17.83): interleaved A/B timing.

  1. A planted 2x workload (the same loop run twice as long) is resolved as
     slower in every round, with a ratio near 2.
  2. A against itself is never clearly different: its per-round ratios
     reach back into [0.5, 1.5]. Stronger checks did not hold: a bound of
     [0.5, 2] on the ratio of minima and "not resolved" (every round on one
     side) both failed on the macos-14 runner, and one of seven local runs
     exited non-zero with "not resolved" in place. The label carries the
     measured numbers, printed only on failure.
  3. Extreme: one round; zero-cost bodies do not divide by zero.
"""

from std.benchmark import keep
from harness.runner import Suite
from harness.bench import measure_ab


@no_inline
def _spin(n: Int) -> Int:
    var x = 0
    for i in range(n):
        x = (x * 31 + i) % 1000003
    return x


def main() raises:
    var s = Suite("bench_ab")

    def base():
        keep(_spin(200000))

    def double():
        keep(_spin(400000))

    def nothing():
        pass

    var r = measure_ab(base, double, rounds=31)
    print("  2x workload: ratio in [1.5, 2.5]:", r.ratio() > 1.5 and r.ratio() < 2.5, " resolved:", r.resolved())
    s.check(r.ratio() > 1.5 and r.ratio() < 2.5, "planted 2x workload measured near 2")
    s.check(r.resolved(), "planted 2x workload is slower in every round")

    var same = measure_ab(base, base, rounds=31)
    # the label carries the numbers so a failure on another machine shows
    # them (a passing check prints no label, so the golden is unaffected)
    s.check(
        same.ratio_lo <= 1.5 and same.ratio_hi >= 0.5,
        "A vs A never clearly different (per-round ratios reach [0.5, 1.5]); ratio " + String(same.ratio())
        + ", per-round " + String(same.ratio_lo) + " .. " + String(same.ratio_hi)
        + ", ns " + String(same.a_ns) + " / " + String(same.b_ns),
    )

    var one = measure_ab(base, double, rounds=1, warmup=0)
    s.check(one.ratio() > 1.0, "one round still orders a 2x workload")
    var zero = measure_ab(nothing, nothing, rounds=3)
    s.check(zero.ratio() >= 0, "zero-cost bodies give a finite ratio")
    s.finish()
