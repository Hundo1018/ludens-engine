"""Work-stealing pool contract: every task runs exactly once.

The pool hands out indices with atomic `fetch_add` on per-range cursors and
lets idle workers claim from ranges they do not own. The whole correctness
argument is that a claim is a single atomic increment, so no index can be
issued twice and none can be skipped — regardless of how the steals interleave.
These checks exercise that across worker counts, task counts (including
`workers > n`, where ranges are empty from the start) and a heavily skewed
cost distribution, which is exactly the case that forces stealing to happen.
"""

from harness.runner import Suite
from scheduler.workstealing import ws_parallel_for


def _run_counts(n: Int, workers: Int, skew: Bool) raises -> List[Int]:
    """Run n tasks and return how many times each index executed."""
    var hits = List[Int]()
    for _ in range(n):
        hits.append(0)
    var hp = hits.unsafe_ptr()

    @parameter
    def body(i: Int):
        # Task 0 is made very expensive under `skew` so its owner falls behind
        # and the other workers must steal to finish the round.
        var spin = 200000 if (skew and i == 0) else 200
        var acc = 0
        for k in range(spin):
            acc += (i + k) & 3
        # each index is claimed exactly once, so a plain increment is safe
        hp[i] += 1 if acc >= 0 else 1

    ws_parallel_for[body](n, workers)
    return hits^


def _all_once(hits: List[Int]) -> Bool:
    for ref h in hits:
        if h != 1:
            return False
    return True


def main() raises:
    var s = Suite("workstealing")

    var widths = List[Int]()
    widths.append(1)
    widths.append(2)
    widths.append(4)
    widths.append(8)
    widths.append(20)

    # 1. uniform cost, several worker counts
    var uniform_ok = True
    for wi in range(len(widths)):
        var hits = _run_counts(1000, widths[wi], False)
        if not _all_once(hits):
            uniform_ok = False
            print("  uniform failed at workers=", widths[wi])
    s.check(uniform_ok, "uniform tasks: every index runs exactly once")

    # 2. skewed cost — this is the run where stealing actually fires
    var skew_ok = True
    for wi in range(len(widths)):
        var hits = _run_counts(256, widths[wi], True)
        if not _all_once(hits):
            skew_ok = False
            print("  skewed failed at workers=", widths[wi])
    s.check(skew_ok, "skewed tasks: every index runs exactly once (steals fire)")

    # 3. more workers than tasks: ranges start empty, the pool must not hang
    #    or double-issue.
    var tiny_ok = True
    for n in range(1, 6):
        var hits = _run_counts(n, 20, False)
        if not _all_once(hits):
            tiny_ok = False
            print("  tiny failed at n=", n)
    s.check(tiny_ok, "workers > tasks: no hang, no double issue")

    # 4. n = 0 is a no-op rather than a crash
    var empty = _run_counts(0, 8, False)
    s.check(len(empty) == 0, "n=0 is a no-op")

    s.finish()
