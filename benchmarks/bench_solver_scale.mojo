"""Production 6-DOF solver: O(n²) brute pair collection vs the `BroadPhase`
seam (ROADMAP 17.0e), at small N and at scale.

`_collect_pairs` used to double-loop every body pair; `broadphase=True` now
swaps that for `self.bp` -- ANY `BroadPhase` backend `ContactScene6[B, BP]`
is instantiated with (`collision.contact_gen`; `test_solver_bp_seam` proves
every dim-3 backend is bit-identical to brute). Table 1 (unchanged) is the
brute-vs-BVH crossover at small N: brute wins with no build/query overhead,
BVH wins once the O(n²) enumeration dominates.

Table 2 is the seam MATRIX at scale (N = 64..4096, the spec's regime): BVH
(rebuild every step) vs DBVH (persistent, frame-coherent), SAP and a hash
grid, all over the same grid-of-towers scene. Advantage-regime rule
(project memory): measure where each is MEANT to win, not one N -- DBVH's
whole reason to exist is that most towers do not move between frames, so its
per-step cost should fall well below a from-scratch BVH rebuild as N grows.

Table 3 targets SAP and the hash grid specifically, uniform body sizes vs a
20:1 size spread: SAP sweeps one axis, so a few huge boxes stay "active"
across the whole pass and degrade it toward O(n); a hash grid sized for the
small bodies pays for the same huge box in every cell it spans. Neither
backend's docstring claims to be spread-proof -- this is the measurement
that would catch it if either quietly stopped being O(n) under spread.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from harness.bench import BenchTable
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase
from collision.bp_sap import SapBroadPhase
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_tree import OctreeBroadPhase
from diag.level import TRACE_ON

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 80


def _grid(side: Int) raises -> ContactScene6[QuatBody6]:
    """side×side separated 2-box stacks on one ground plane. Total dynamic
    bodies = 2·side². Stacks are 3 m apart so only within-stack pairs touch —
    the O(n²) loop still visits all ~2n² of them; the BVH prunes to O(n)."""
    var sc = ContactScene6[QuatBody6]()
    var g = Real(side) * 3
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, g, 1, g)),
        Vec3(g, 1, g, 0),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for a in range(side):
        for b in range(side):
            var x = Real(a) * 3 - g * 0.5
            var z = Real(b) * 3 - g * 0.5
            for i in range(2):
                _ = sc.add(
                    QuatBody6.at_rest(
                        Vec3(x, 0.3 + 0.52 * Real(i), z, 0), bi
                    ),
                    Vec3(0.25, 0.25, 0.25, 0),
                    False,
                )
    return sc^


def _run(mut sc: ContactScene6[QuatBody6], bp: Bool) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, broadphase=bp)
    return Int(perf_counter_ns()) - t0


def _grid_bp[BP: BroadPhase](side: Int) -> ContactScene6[QuatBody6, BP]:
    """`_grid`, generic over the seam's broadphase backend."""
    var sc = ContactScene6[QuatBody6, BP]()
    var g = Real(side) * 3
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, g, 1, g)),
        Vec3(g, 1, g, 0), True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for a in range(side):
        for b in range(side):
            var x = Real(a) * 3 - g * 0.5
            var z = Real(b) * 3 - g * 0.5
            for i in range(2):
                _ = sc.add(
                    QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), z, 0), bi),
                    Vec3(0.25, 0.25, 0.25, 0), False,
                )
    return sc^


def _run_bp[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP]) -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, broadphase=True)
    return Int(perf_counter_ns()) - t0


def _spread_scene[BP: BroadPhase](n: Int, spread: Bool) -> ContactScene6[QuatBody6, BP]:
    """`n` dynamic boxes in a single row over one long, NARROW floor strip
    (half-extent scales with `n` only along the row axis, not both floor
    axes -- a square floor here would be `n`-by-`n`, and inserting that into
    a hash grid sized for the small bodies is exactly the "box spanning many
    cells" hazard F17/E17 flags, i.e. the bug this scene means to expose
    would instead blow up the harness). 6 m apart so most pairs are non-
    neighbours. `spread=True` makes every 8th box a 20x half-extent (4.0 vs
    the 0.2 baseline) -- the size-spread advantage-regime scene for
    `SapBroadPhase`/`SpatialHashBroadPhase`."""
    var sc = ContactScene6[QuatBody6, BP]()
    var g = Real(n) * 6 + 20
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, g, 1, 10)),
        Vec3(g, 1, 10, 0), True,
    )
    for i in range(n):
        var x = Real(i) * 6 - g * 0.5
        var half = Real(0.2)
        if spread and i % 8 == 0:
            half = Real(4.0)
        _ = sc.add(
            QuatBody6.at_rest(Vec3(x, 3, 0, 0), Inertia3.box(2, half, half, half)),
            Vec3(half, half, half, 0), False,
        )
    return sc^


def main() raises:
    var t = BenchTable("6-DOF solver pair collection: brute O(n²) vs BVH")
    var sides = List[Int]()
    sides.append(2)
    sides.append(4)
    sides.append(8)
    sides.append(12)
    sides.append(16)
    for si in range(len(sides)):
        var side = sides[si]  # N = 2·side² -> 8, 32, 128, 288, 512
        var n = 2 * side * side
        var sb = _grid(side)
        t.add("brute N=" + String(n), n, "step", _run(sb, False), STEPS)
        var sp = _grid(side)
        t.add("bvh   N=" + String(n), n, "step", _run(sp, True), STEPS)
    t.print_report()

    # Table 2: the full seam matrix, N = 64..4096 (2*side^2).
    var t2 = BenchTable("solver broadphase seam at scale: BVH vs DBVH vs SAP vs hash grid vs octree")
    var big_sides = List[Int]()
    big_sides.append(6)   # N=72
    big_sides.append(8)   # N=128
    big_sides.append(11)  # N=242
    big_sides.append(16)  # N=512
    big_sides.append(23)  # N=1058
    big_sides.append(32)  # N=2048
    big_sides.append(45)  # N=4050
    for si in range(len(big_sides)):
        var side = big_sides[si]
        var n = 2 * side * side
        var s_bvh = _grid_bp[BVHBroadPhase[3]](side)
        t2.add("bvh      N=" + String(n), n, "step", _run_bp(s_bvh), STEPS)
        var s_dbvh = _grid_bp[DbvhBroadPhase[3]](side)
        t2.add("dbvh     N=" + String(n), n, "step", _run_bp(s_dbvh), STEPS)
        var s_sap = _grid_bp[SapBroadPhase[3]](side)
        t2.add("sap      N=" + String(n), n, "step", _run_bp(s_sap), STEPS)
        var s_hash = _grid_bp[SpatialHashBroadPhase[3]](side)
        t2.add("hashgrid N=" + String(n), n, "step", _run_bp(s_hash), STEPS)
        var s_tree = _grid_bp[OctreeBroadPhase](side)
        t2.add("octree   N=" + String(n), n, "step", _run_bp(s_tree), STEPS)
    t2.print_report()

    # Table 3: SAP / hash grid under a 20:1 size spread, fixed N=1024.
    var t3 = BenchTable("SAP vs hash grid: uniform sizes vs 20:1 size spread (N=1024)")
    comptime SPREAD_N = 1024
    var sap_uniform = _spread_scene[SapBroadPhase[3]](SPREAD_N, False)
    t3.add("sap      uniform", SPREAD_N, "step", _run_bp(sap_uniform), STEPS)
    var sap_spread = _spread_scene[SapBroadPhase[3]](SPREAD_N, True)
    t3.add("sap      20:1 spread", SPREAD_N, "step", _run_bp(sap_spread), STEPS)
    var hash_uniform = _spread_scene[SpatialHashBroadPhase[3]](SPREAD_N, False)
    t3.add("hashgrid uniform", SPREAD_N, "step", _run_bp(hash_uniform), STEPS)
    var hash_spread = _spread_scene[SpatialHashBroadPhase[3]](SPREAD_N, True)
    t3.add("hashgrid 20:1 spread", SPREAD_N, "step", _run_bp(hash_spread), STEPS)
    t3.print_report()

    # Table 4 (ROADMAP 17.0h): diag overhead on the production step path.
    # `TRACE_ON` is resolved once per COMPILED binary (`-D LUDENS_TRACE` is a
    # build-time define), so "spans on vs off" is two separate invocations of
    # THIS file (one plain, one with the flag) compared externally -- not a
    # runtime toggle inside one `main()`. This table's rows are meant to be
    # read side by side across those two runs; each run interleaves several
    # independently-built scenes rather than timing one giant loop, so a
    # thermal/scheduler drift across the invocation doesn't bias one round.
    # The NaN scan itself is NOT a toggle (docs/ARCHITECTURE.md S2: a world
    # must keep stepping, so the end-of-step finite check is unconditional)
    # -- its share of the traced step is read from `sc.trace.stats()`'s
    # "nan_scan" entry under `-D LUDENS_TRACE` instead of an on/off delta.
    var t4 = BenchTable(
        "ROADMAP 17.0h: diag overhead (compare this table's ns/step across a "
        + "plain run and a -D LUDENS_TRACE run; NaN-scan share printed below "
        + "under -D LUDENS_TRACE)"
    )
    comptime OVERHEAD_SIDE = 16  # N = 2*16*16 = 512
    comptime OVERHEAD_ROUNDS = 3
    var last_scene = _grid(OVERHEAD_SIDE)
    for r in range(OVERHEAD_ROUNDS):
        var s = _grid(OVERHEAD_SIDE)
        t4.add("round=" + String(r), 512, "step", _run(s, True), STEPS)
        last_scene = s^
    t4.print_report()
    comptime if TRACE_ON:
        var stats = last_scene.trace.stats()
        var total_ns = 0
        var nan_ns = 0
        for i in range(len(stats)):
            total_ns += stats[i].total_ns
            if stats[i].name == "nan_scan":
                nan_ns = stats[i].total_ns
        if total_ns > 0:
            var pct = Real(nan_ns) * 100.0 / Real(total_ns)
            print(
                "nan_scan share of traced step time: " + String(nan_ns)
                + " ns / " + String(total_ns) + " ns total = "
                + String(pct) + "%"
            )
    else:
        print("(rebuild with -D LUDENS_TRACE to see the nan_scan share breakdown)")
