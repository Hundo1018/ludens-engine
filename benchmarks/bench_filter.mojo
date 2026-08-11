"""Collision filtering and contact events: the regime where filtering pays.

A first attempt at this table compared one pile of crates against the same pile
with layers assigned, and made filtering look like a 45% slowdown. It was
measuring the wrong thing: filtering crates out of each other's masks lets them
interpenetrate, so the pile collapses into a different, messier arrangement
with a different contact count. That is a comparison of two SCENES, not of a
feature's cost.

What filtering is actually for is populations that share space and must not
interact — a player layer and an enemy layer standing in the same room, debris
that collides with the world but not with itself. So both rows below start from
the SAME two interpenetrating populations. The second scene is the one you
wanted; the first is what you get without the feature.

The `asleep=` column says where the difference comes from, and it is not the
contact count: 254 contacts against 192 is a 32% difference, nowhere near the
measured factor. The filtered scene reaches rest and every one of its 192
crates goes to sleep. The unfiltered one cannot — crates spawned inside each
other are pushed apart, drift back, and are pushed again — so 104 of them are
still awake and being solved after two seconds. Filtering does not make contact
resolution faster; it makes the difference between a scene that settles and one
that never does.

The event rows are a clean like-for-like: identical scene, identical filtering,
`events_on` toggled. The diff sorts the contact set every step, which is why it
is off by default, and this is what that costs.

Run with: `mojo run -I build benchmarks/bench_filter.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from harness.bench import BenchTable, now

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)

comptime _WORLD: UInt32 = 1
comptime _RED: UInt32 = 2
comptime _BLUE: UInt32 = 4


def build(n: Int, filtered: Bool, events: Bool) -> ContactScene6[QuatBody6]:
    """Two populations of `n` crates each, occupying the SAME volume: crate `i`
    of one sits a quarter-cell from crate `i` of the other. Filtered, each
    population ignores itself and the other, and both still land on the floor.
    """
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = events
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30), True,
    )
    var per_row = 8
    for pop in range(2):
        for i in range(n):
            var ix = i % per_row
            var iz = (i // per_row) % per_row
            var iy = i // (per_row * per_row)
            var off = Real(pop) * 0.12
            var b = sc.add(
                QuatBody6.at_rest(
                    Vec3(
                        Real(ix) * 0.48 - 2.0 + off,
                        0.3 + Real(iy) * 0.52,
                        Real(iz) * 0.48 - 2.0 + off,
                    ),
                    Inertia3.box(2, 0.25, 0.25, 0.25),
                ),
                Vec3(0.25, 0.25, 0.25), False,
            )
            if filtered:
                var cat = _RED if pop == 0 else _BLUE
                sc.set_filter(b, cat, _WORLD)  # world only, neither population
    return sc^


def run(
    mut table: BenchTable, name: String, n: Int, filtered: Bool,
    events: Bool, steps: Int,
):
    var sc = build(n, filtered, events)
    for _ in range(60):  # settle: the interesting cost is the resting state
        sc.step_soft(DT, G, broadphase=True)
    var t0 = now()
    for _ in range(steps):
        sc.step_soft(DT, G, broadphase=True)
    var t1 = now()
    var acc = Real(0)
    var asleep = 0
    for i in range(len(sc.bodies)):
        acc += sc.bodies[i].position()[1]
        if sc.sleeping[i]:
            asleep += 1
    keep(acc)
    table.add(
        name + " contacts=" + String(len(sc.cache))
        + " asleep=" + String(asleep),
        2 * n, "step", t1 - t0, steps,
    )


def main() raises:
    var table = BenchTable(
        "Collision filtering: two populations sharing one volume"
    )
    var w = build(32, True, False)  # warm-up: first fan-out pays pool creation
    for _ in range(4):
        w.step_soft(DT, G, broadphase=True)

    run(table, "unfiltered (both populations collide)", 96, False, False, 60)
    run(table, "filtered (each ignores the other)", 96, True, False, 60)
    run(table, "filtered + events", 96, True, True, 60)
    run(table, "unfiltered + events", 96, False, True, 60)
    table.print_report()
