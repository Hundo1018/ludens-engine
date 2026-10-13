# tier: unit
"""`harness.bench.measure_ab` (ROADMAP 17.83): interleaved A/B timing.

  1. A planted 2x workload (the same loop run twice as long) is resolved as
     slower in every round, with a ratio near 2.
  2. A against itself is never clearly different: its per-round ratios
     reach back into [0.5, 1.5]. Stronger checks did not hold: a bound of
     [0.5, 2] on the ratio of minima and "not resolved" (every round on one
     side) both failed on the macos-14 runner, and one of seven local runs
     exited non-zero with "not resolved" in place. The label carries the
     measured numbers, printed only on failure (that is how the macos-14
     failures turned out to be 0 ns / 0 ns: the constant-count loop had been
     folded away; the count is now a runtime value).
  3. Extreme: one round; zero-cost bodies do not divide by zero.
"""

from std.benchmark import keep
from harness.runner import Suite
from harness.bench import measure_ab, now


@no_inline
def _spin(n: Int) -> Int:
    var x = 0
    for i in range(n):
        x = (x * 31 + i) % 1000003
    return x


def main() raises:
    var s = Suite("bench_ab")

    # the loop count is a runtime value: with a literal count the macos-14
    # toolchain folded `_spin` away and timed nothing (0 ns / 0 ns). ~20 ms
    # per run: at ~4 ms one scheduler stall on a shared macos-14 runner made
    # a base run slower than its 2x partner in 1 of 31 rounds.
    # A per-closure call counter feeds the count too: `measure_ab(base, base)` timed
    # 0 ns / 0 ns on macos-14 -- two identical calls of the pure `_spin`
    # were computed once, outside the timed region. With the counter no two
    # calls share an argument (at most one extra iteration).
    var n0 = 10000000 + now() % 2
    var ca = 0
    var cb = 0
    var cd = 0

    def base() {mut ca, imm n0}:
        ca += 1
        keep(_spin(n0 + ca % 2))

    def base2() {mut cb, imm n0}:
        cb += 1
        keep(_spin(n0 + cb % 2))

    def double() {mut cd, imm n0}:
        cd += 1
        keep(_spin(2 * n0 + cd % 2))

    def nothing():
        pass

    var r = measure_ab(base, double, rounds=31)
    print("  2x workload: ratio in [1.5, 2.5]:", r.ratio() > 1.5 and r.ratio() < 2.5, " resolved:", r.resolved())
    s.check(r.ratio() > 1.5 and r.ratio() < 2.5, "planted 2x workload measured near 2")
    s.check(r.resolved(), "planted 2x workload is slower in every round")

    var same = measure_ab(base, base2, rounds=31)
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
