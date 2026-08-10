"""Reduced-coordinate contact: what the joint-space route costs.

Every contact impulse in generalised coordinates needs `J H⁻¹ Jᵀ` — a point
Jacobian, the CRBA mass matrix and a dense solve — where a maximal-coordinate
solver needs only the two bodies' inverse inertias. So the reduced route pays
a per-contact cost that scales with the whole articulated system, not with the
pair, and that is the axis worth measuring: cost per contact against LINK
COUNT, not against contact count.

What it buys is that the joint constraints are exact by construction: there is
no joint drift to correct, no constraint stabilisation, and no stiffness limit
from soft joints. The maximal path in `solver6` pays for those instead.

Rows separate the dynamics step from the contact pass so the contact overhead
is readable on its own rather than buried in the total.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0)
comptime DT: Real = 1.0 / 240.0
comptime STEPS = 200
comptime REPS = 3


def _chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink(
                Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0,
                Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
            )
        )
    return c^


def _row(mut t: BenchTable, n: Int, with_contact: Bool) raises:
    var pts = List[Int]()
    var locs = List[Vec3]()
    for i in range(n):
        pts.append(i)
        locs.append(Vec3(0, -1, 0))
    var zero = List[Real]()
    for _ in range(n):
        zero.append(0)
    # floor placed as a fixed FRACTION of the chain's reach, so the number of
    # links that can strike it is comparable across n rather than shrinking
    var floor_y = -0.85 * Real(n)

    var best = Int.MAX
    for _ in range(REPS):
        var c = _chain(n)
        c.q[0] = 1.2
        var t0 = Int(perf_counter_ns())
        for _ in range(STEPS):
            c.step(DT, zero, G)
            if with_contact:
                _ = c.resolve_ground(floor_y, 0.0, pts, locs, DT)
        var dt = Int(perf_counter_ns()) - t0
        keep(c.q[0])
        if dt < best:
            best = dt
    var name = "step + ground contact" if with_contact else "step only"
    t.add(name, n, "step", best, STEPS)


def main() raises:
    var t = BenchTable(
        "Reduced-coordinate contact: dynamics step vs step + contact resolution"
    )
    comptime for ni in range(4):
        comptime NL = 2 if ni == 0 else (4 if ni == 1 else (8 if ni == 2 else 16))
        _row(t, NL, False)
        _row(t, NL, True)
    t.print_report()
