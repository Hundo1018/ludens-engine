# tier: unit
"""`harness.bench.measure_ab` (ROADMAP 17.83): interleaved A/B timing.

  1. A planted 2x workload (the same loop run twice as long) is resolved as
     slower in every round, with a ratio near 2.
  2. A against itself is not resolved: over 31 rounds with alternating
     order some favour each side. (A bound on the ratio of minima failed on
     the macos-14 runner even at [0.5, 2] -- performance and efficiency
     cores make the minimum of identical work unstable -- while a
     one-sided result for identical work needs all 31 rounds to fall the
     same way, about 2^-30 for symmetric noise.)
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
    s.check(not same.resolved(), "A vs A is not resolved (rounds fall both ways)")

    var one = measure_ab(base, double, rounds=1, warmup=0)
    s.check(one.ratio() > 1.0, "one round still orders a 2x workload")
    var zero = measure_ab(nothing, nothing, rounds=3)
    s.check(zero.ratio() >= 0, "zero-cost bodies give a finite ratio")
    s.finish()
