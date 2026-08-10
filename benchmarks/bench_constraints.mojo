"""The unified constraint solver: what one system buys over separate passes,
and what the honest friction cone costs.

The first block set out to show that separate passes fight — each group solved
as if the other were not there — and it DOES NOT show that. Driven to equal
work, one system and two alternating passes reach the same violation at every
sweep count that matters, on both a heavily coupled system and the disjoint
control. Worse for the unified side: alternating passes keep going down to
machine zero while one system stalls near 3e-8, because it warm-starts its
accumulated impulses and then recomputes each residual by re-dotting a
velocity that has had impulses of order 1 added to and subtracted from it.
That cancellation is the floor, and restarting from zero every pass avoids it.

So the case for solving everything together is not iteration count, and this
table is here to say so rather than to be quietly dropped. The case is that
the friction cone COUPLES rows: `|f_t| <= mu * f_n` cannot be evaluated in a
pass that does not know `f_n`, so separate passes do not merely converge
slower to the right answer, they cannot express it. That is what
`test_constraints` checks and what the tables below price.

The tables then price the cone seam. Elliptic friction solves its two tangent
rows as a pair with a radial projection; pyramidal clamps each independently.
Pyramidal is cheaper per row, and the question is by how much — the accuracy
difference is already established (sqrt(2) too much friction on the diagonal,
up to 35 degrees of misalignment), so what is left is what correctness costs.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.math import sqrt
from harness.bench import BenchTable
from geometry.vec import Real
from physics.constraints import (
    ConstraintSet, CONE_PYRAMIDAL, CONE_ELLIPTIC
)

comptime REPS = 3
comptime ITERS = 60


def _mass(n: Int) -> List[Real]:
    var h = List[Real]()
    for r in range(n):
        for c in range(n):
            # slightly coupled, so H is not trivially diagonal
            h.append(Real(1.0) if r == c else (Real(0.1) if abs(r - c) == 1 else Real(0)))
    return h^


def _vec(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def _contacts(n: Int, pairs: Int, cone: Int) raises -> ConstraintSet:
    var cs = ConstraintSet(n)
    cs.cone = cone
    for k in range(pairs):
        var base = (k * 3) % n
        var jn = _vec(n)
        jn[base] = 1
        var nr = cs.add_contact(jn, 0)
        var j1 = _vec(n)
        j1[(base + 1) % n] = 1
        var j2 = _vec(n)
        j2[(base + 2) % n] = 1
        _ = cs.add_tangents(j1, j2, nr, 0.5)
    return cs^


def _cone_rows(mut t: BenchTable, n: Int, pairs: Int) raises:
    for c in range(2):
        var cone = CONE_PYRAMIDAL if c == 0 else CONE_ELLIPTIC
        var best = Int.MAX
        for _ in range(REPS):
            var t0 = Int(perf_counter_ns())
            for _ in range(ITERS):
                var cs = _contacts(n, pairs, cone)
                var qd = _vec(n)
                for i in range(n):
                    qd[i] = -1.0 + Real(i) * 0.13
                cs.solve(_mass(n), qd, 20)
                keep(qd[0])
            var dt = Int(perf_counter_ns()) - t0
            if dt < best:
                best = dt
        var nm = (
            String(pairs) + " contacts, pyramidal" if c == 0
            else String(pairs) + " contacts, elliptic"
        )
        t.add(nm, n, "solve", best, ITERS)


def _row(n: Int, i: Int, coupled: Bool) -> List[Real]:
    """A constraint direction. Coupled rows OVERLAP heavily, which is the only
    situation in which the two schemes can differ: rows on disjoint
    coordinates are independent problems and any correct solver handles them
    identically."""
    var j = _vec(n)
    j[i] = 1
    if coupled:
        for k in range(n):
            if k != i:
                j[k] = 0.85
    return j^


def _violation(unified: Bool, coupled: Bool, sweeps: Int) raises -> Real:
    """Worst constraint violation after `sweeps` passes over every row.

    Unified interleaves the groups; separate runs group A to convergence and
    then group B, which is what two independent resolve passes amount to.
    Both see the same total number of row updates."""
    var n = 6
    var qd = _vec(n)
    for i in range(n):
        qd[i] = -1.2 + Real(i) * 0.3

    # group A: joint limits.  group B: contacts.
    var a_idx = List[Int]()
    var b_idx = List[Int]()
    a_idx.append(0)
    a_idx.append(1)
    b_idx.append(2)
    b_idx.append(3)

    if unified:
        var cs = ConstraintSet(n)
        for k in range(len(a_idx)):
            _ = cs.add_limit(_row(n, a_idx[k], coupled), 0)
        for k in range(len(b_idx)):
            _ = cs.add_contact(_row(n, b_idx[k], coupled), 0)
        cs.solve(_mass(n), qd, sweeps)
    else:
        for _ in range(sweeps):
            var ca = ConstraintSet(n)
            for k in range(len(a_idx)):
                _ = ca.add_limit(_row(n, a_idx[k], coupled), 0)
            ca.solve(_mass(n), qd, 1)
            var cb = ConstraintSet(n)
            for k in range(len(b_idx)):
                _ = cb.add_contact(_row(n, b_idx[k], coupled), 0)
            cb.solve(_mass(n), qd, 1)

    var worst = Real(0)
    for k in range(len(a_idx)):
        var r = _row(n, a_idx[k], coupled)
        var v = Real(0)
        for i in range(n):
            v += r[i] * qd[i]
        if -v > worst:
            worst = -v
    for k in range(len(b_idx)):
        var r = _row(n, b_idx[k], coupled)
        var v = Real(0)
        for i in range(n):
            v += r[i] * qd[i]
        if -v > worst:
            worst = -v
    return worst


def _compare() raises:
    for ci in range(2):
        var coupled = ci == 0
        print(
            "  " + ("strongly coupled rows" if coupled else "disjoint rows (control)")
        )
        print("    sweeps    separate passes      one system")
        for k in range(5):
            var sw = 2 << k
            var sep = _violation(False, coupled, sw)
            var uni = _violation(True, coupled, sw)
            print("    ", sw, "     ", sep, "     ", uni)


def main() raises:
    print("Separate passes vs one system: worst remaining violation, equal work")
    _compare()
    print("")

    var t = BenchTable("Friction cone: what the honest projection costs")
    comptime for li in range(3):
        comptime NL = 6 if li == 0 else (18 if li == 1 else 48)
        _cone_rows(t, NL, 2)
        _cone_rows(t, NL, NL // 3)
    t.print_report()
