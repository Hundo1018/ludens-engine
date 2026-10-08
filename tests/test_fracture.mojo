# tier: integration
"""Destruction and fracture in the production solver (ROADMAP 17.5).

Fragments are real hull bodies of a `ContactScene6`, bonded by breakable welds.

  ordinary     a bonded Voronoi wall stands on the ground without a single
               bond failing, then a heavy ball is shot at it: bonds break, the
               fragments around the impact are driven through, the wall is
               punched open (no fragment left in the line of the shot), and
               most of the wall still stands. A two-fragment cantilever shows
               the break threshold both ways (holds above the load, breaks
               below it) and a break is reported exactly once, also over a
               `scheduler.events.Channel`.
  integration  debris dropped on a rigid crate, a static ledge and a soft body
               collides with all three, settles, and every fragment falls
               asleep, as many small islands (a bonded structure is one);
               a concave solid (L slab) goes through the whole chain -- voxelise,
               decompose, Voronoi-fracture each part, spawn, bond -- and
               comes to rest asleep; a runtime plane cut of a bonded fragment
               re-anchors its bonds to the pieces; the free-fragment budget
               evicts sleeping and small ones first and counts them.
  extreme      one seed = one fragment and no bonds; a flat (coplanar) cell is
               not spawned; one cut producing 1000 fragments conserves volume
               and runs; a cut plane that misses changes nothing; thousand-cell
               Voronoi conserves volume; coincident seeds and zero thresholds
               are handled / raise at the boundary.
"""

from std.math import sqrt
from harness.runner import Suite
from harness.meshes import l_prism
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.polytope import Polytope
from geometry.fracture_cut import (
    FragmentSet,
    scatter_seeds,
    voronoi_fracture,
    voronoi_fracture_parts,
    cut_by_planes,
)
from geometry.convex_decomp import voxelize, SplitDecomposer, decompose_with
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody
from physics.joints6 import JOINT_BROKEN
from physics.fracture import FractureSet, EVENT_BOND_BROKEN, debris_config
from diag.counters import FRAGMENT_EVICTED
from scheduler.events import Channel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0),
        True,
    ).index()


def _cells(src: Polytope, n: Int, seed: Int, minv: Float64) -> FragmentSet:
    var seeds = scatter_seeds(src.bounds(), n, seed, 0.0, 0.0, 0.0, 0.0)
    var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(src, seeds, 0, minv, fs)
    return fs^


# --------------------------------------------------------------- ORDINARY
def case_wall(mut s: Suite) raises:
    var sc = ContactScene6[QuatBody6]()
    var ground = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0),
        True,
    )
    var wall = Polytope.box(0, 1.0, 0, 1.5, 1.0, 0.15)  # 3 x 2 x 0.3 m
    var seeds = scatter_seeds(wall.bounds(), 40, 5, 0.0, 1.0, -0.15, 0.5)
    var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(wall, seeds, 0, 1e-5, fs)
    s.almost(fs.total_volume(), wall.volume(), "Voronoi cells tile the wall", 1e-9)
    var set = FractureSet(2000, 0)
    var first = set.spawn(sc, fs, ZERO, Quat.identity(), ZERO, ZERO)
    var nb = set.bond_neighbors(sc, first, 5e4)
    var na = set.anchor(sc, first, ground, ZERO, Quat.identity(), 0.0, -1.0, 0.0, 0.0, 1e-6, 5e4)
    print("  wall:", set.fragments(), "fragments", nb, "bonds", na, "footing anchors")
    s.check(set.fragments() >= 35, "the wall became ~40 fragments")
    s.check(nb > set.fragments() and na >= 3, "bonded: more bonds than fragments, footing anchored")
    s.eqi(sc.joints[set.bond_joint[0]].kind, 4, "bonds are WELD joints")

    var settle_broken = 0
    for _ in range(90):
        sc.step_soft(DT, G)
        settle_broken += set.poll(sc)
    s.eqi(settle_broken, 0, "the bonded wall stands: no bond fails under gravity")
    s.eqi(set.live_bonds(), nb + na, "all bonds intact")
    var in_line_before = 0
    for i in range(set.fragments()):
        var p = sc.bset.bodies[set.body[i]].position()
        if abs(p[0]) < 0.3 and abs(p[1] - 1.0) < 0.3 and abs(p[2]) < 0.2:
            in_line_before += 1
    s.check(in_line_before >= 1, "something stood in the line of the shot")
    var bonds0 = set.live_bonds()

    var ball = sc.add_sphere(
        QuatBody6(Vec3(0, 1.0, -3, 0), Quat.identity(), Vec3(0, 0, 50, 0), ZERO, Inertia3.sphere(100, 0.3)),
        0.3,
        False,
    )
    var broken = 0
    for _ in range(240):
        sc.step_soft(DT, G)
        broken += set.poll(sc)
    var thrown = 0
    var in_line_after = 0
    for i in range(set.fragments()):
        var p = sc.bset.bodies[set.body[i]].position()
        if p[2] > 0.5:
            thrown += 1
        if abs(p[0]) < 0.3 and abs(p[1] - 1.0) < 0.3 and abs(p[2]) < 0.2:
            in_line_after += 1
    var finite = True
    for i in range(set.fragments()):
        var p = sc.bset.bodies[set.body[i]].position()
        if not (p[0] == p[0] and p[1] == p[1] and p[2] == p[2]):
            finite = False
    print("  shot: broke", broken, "bonds, thrown through", thrown, ", left in line", in_line_after, ", live bonds", set.live_bonds(), "of", bonds0, ", ball z", sc.bset.bodies[ball.index()].position()[2])
    s.check(broken >= 20, "the shot breaks bonds")
    s.eqi(set.live_bonds(), bonds0 - broken, "events account for every released bond")
    s.check(thrown >= 10, "fragments are driven through the wall")
    s.eqi(in_line_after, 0, "the wall is punched open along the line of the shot")
    s.check(set.live_bonds() >= 5 and set.live_bonds() < bonds0, "part of the structure survives")
    s.check(finite, "every fragment pose is finite")


def case_threshold(mut s: Suite) raises:
    # a weld between a static anchor and a fragment, loaded by its own weight:
    # break force = floor_g * m * g, so 3x the load holds and 0.3x breaks
    for variant in range(2):
        var sc2 = ContactScene6[QuatBody6]()
        var anchor = sc2.add(
            QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)),
            Vec3(0.1, 0.1, 0.1, 0),
            True,
        )
        var cube2 = Polytope.box(0, 4.0, 0, 0.5, 0.5, 0.5)
        var fs2 = FragmentSet(List[Polytope](), List[Int](), List[Int]())
        fs2.cells.append(cube2.copy())
        fs2.seed.append(0)
        fs2.part.append(0)
        var set2 = FractureSet(1000, 0)
        var f0 = set2.spawn(sc2, fs2, ZERO, Quat.identity(), ZERO, ZERO)
        sc2.set_can_sleep(set2.bid[0], False)
        # weld the cube's top face (y = 4.5) to the anchor
        var n = set2.anchor(
            sc2, f0, anchor, ZERO, Quat.identity(), 0.0, 1.0, 0.0, 4.5, 1e-6, 1e-3,
            Real(3.0) if variant == 0 else Real(0.3),
        )
        s.eqi(n, 1, "the top face is a footprint")
        var reports = 0
        var channel = Channel[Int]()
        var reader = channel.register_reader()
        var got = List[Int]()
        for _ in range(90):
            sc2.step_soft(DT, G)
            _ = set2.poll(sc2)
            for k in range(len(set2.events)):
                if set2.events[k].kind == EVENT_BOND_BROKEN:
                    channel.send(set2.events[k].bond)
                    reports += 1
            channel.update()
            channel.read(reader, got)
        var y = sc2.bset.bodies[set2.body[0]].position()[1]
        if variant == 0:
            s.eqi(reports, 0, "threshold 3x the load: holds")
            s.check(y > 3.9, "...and the cube still hangs")
        else:
            s.eqi(reports, 1, "threshold 0.3x the load: breaks, reported once")
            s.eqi(len(got), 1, "...once on the event channel as well")
            s.check(y < 3.0, "...and the cube falls")
            s.eqi(set2.live_bonds(), 0, "no live bond left")
            s.eqi(set2.free_count(), 1, "the fragment is free")


# ------------------------------------------------------------- INTEGRATION
def _debris_scene(frags: FragmentSet, bricks: Bool) raises -> List[Float64]:
    """Debris dropped on a rigid crate, a static ledge and a soft body.
    Returns [fragments, asleep among the debris that fell on rigid bodies,
    how many of those, islands, on crate, on ledge, lowest centre, soft top
    moved, crate sag, max speed, finite]. (The third batch lands on the soft
    body, which never sleeps and keeps whatever rests on it awake, so it is
    counted for everything except sleep.)"""
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var crate = sc.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(30, 0.5, 0.25, 0.5)),
        Vec3(0.5, 0.25, 0.5, 0),
        False,
    )
    _ = sc.add(
        QuatBody6.at_rest(Vec3(2.0, 0.15, 0, 0), Inertia3.box(1, 0.4, 0.15, 0.4)),
        Vec3(0.4, 0.15, 0.4, 0),
        True,
    )
    var sb = SoftBody.box_lattice(Vec3(-4.0, 0.3, 0, 0), Vec3(0.3, 0.3, 0.3, 0), 4, 2.0, 1e-4)
    _ = sc.add_soft(sb^)
    var soft_top0 = Float64(sc.softs[0].top_y())
    var set = FractureSet(800, 0)
    var light = FractureSet(60, 0)  # a 2 kg soft cube is not asked to carry 800 kg
    var offs = List[Float64]()
    for q in [0.0, 1.6, 0.0, 2.0, 1.4, 0.0, -4.0, 1.6, 0.0]:
        offs.append(q)
    for k in range(3):
        var at = Vec3(Real(offs[3 * k]), Real(offs[3 * k + 1]), Real(offs[3 * k + 2]), 0)
        if k < 2:
            _ = set.spawn(sc, frags, at, Quat.identity(), ZERO, ZERO)
        else:
            _ = light.spawn(sc, frags, at, Quat.identity(), ZERO, ZERO)
    var n = set.fragments()
    var nl = light.fragments()
    var crate0 = Float64(sc.bset.bodies[crate.index()].position()[1])
    var cfg = debris_config()
    for _ in range(600):
        sc.step(DT, G, cfg)
    var out = List[Float64]()
    var lowest = Float64(1e30)
    var finite = 1.0
    var on_crate = 0
    var on_ledge = 0
    var asleep = 0
    var rigid = 0
    var vmax = Float64(0)
    for i in range(n):
        var p = sc.bset.bodies[set.body[i]].position()
        if not (p[0] == p[0] and p[1] == p[1] and p[2] == p[2]):
            finite = 0.0
        lowest = min(lowest, Float64(p[1]))
        if abs(p[0]) < 0.6 and p[1] > 0.5:
            on_crate += 1
        if abs(p[0] - 2.0) < 0.5 and p[1] > 0.3:
            on_ledge += 1
        rigid += 1
        if sc.bset.sleeping[set.body[i]]:
            asleep += 1
        vmax = max(vmax, Float64(length(sc.bset.bodies[set.body[i]].vel)))
    for i in range(nl):
        var p = sc.bset.bodies[light.body[i]].position()
        if not (p[0] == p[0] and p[1] == p[1] and p[2] == p[2]):
            finite = 0.0
        lowest = min(lowest, Float64(p[1]))
        vmax = max(vmax, Float64(length(sc.bset.bodies[light.body[i]].vel)))
    out.append(Float64(n + nl))
    out.append(Float64(asleep))
    out.append(Float64(rigid))
    out.append(Float64(sc.island_count()))
    out.append(Float64(on_crate))
    out.append(Float64(on_ledge))
    out.append(lowest)
    out.append(soft_top0 - Float64(sc.softs[0].top_y()))
    out.append(abs(Float64(sc.bset.bodies[crate.index()].position()[1]) - crate0))
    out.append(vmax)
    out.append(finite)
    var soft_ok = 1.0
    for i in range(len(sc.softs[0].pts)):
        var x = sc.softs[0].pts[i].x
        if not (x[0] == x[0] and x[1] == x[1] and x[2] == x[2]) or x[1] < -0.05:
            soft_ok = 0.0
    out.append(soft_ok)
    return out^


def case_debris(mut s: Suite) raises:
    """Free fragments collide with a rigid crate, a static ledge and a soft
    body, then settle. Two kinds of debris: BRICKS (a 3 x 3 x 3 grid cut of a
    block: box-shaped pieces, which settle exactly and sleep) and Voronoi
    SHARDS (irregular hulls, whose resting contact is looser)."""
    var block = Polytope.box(0, 0, 0, 0.5, 0.5, 0.5)
    var planes = List[Float64]()
    for ax in range(3):
        for k in range(2):
            for z in range(3):
                planes.append(1.0 if z == ax else 0.0)
            planes.append(Float64(k) / 3.0 * 1.0 - 1.0 / 6.0)
    var bricks = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    var pcs = cut_by_planes(block, planes, 0.0)
    for i in range(len(pcs)):
        bricks.cells.append(pcs[i].copy())
        bricks.seed.append(i)
        bricks.part.append(0)
    s.eqi(bricks.count(), 27, "a 3x3x3 grid cut makes 27 bricks")
    var r = _debris_scene(bricks, True)
    print(
        "  bricks:", Int(r[0]), "fragments, asleep", Int(r[1]), "of", Int(r[2]), "on rigid bodies, islands", Int(r[3]),
        ", on crate", Int(r[4]), ", on ledge", Int(r[5]), ", lowest centre", r[6],
        ", soft top moved", r[7], ", crate sag", r[8], ", max speed", r[9],
    )
    s.check(r[10] > 0.5, "bricks: poses finite")
    s.check(r[6] > 0.05, "bricks: none sank through the floor")
    s.check(r[4] >= 5, "bricks: piled on the rigid crate")
    s.check(r[5] >= 3, "bricks: lie on the static ledge")
    s.check(abs(r[7]) > 0.02 and r[11] > 0.5, "bricks: the soft body was struck, and stayed sound")
    s.check(r[8] < 0.02, "bricks: the crate carried the load")
    s.check(r[1] >= r[2] * 0.9, "bricks: the debris on rigid bodies fell asleep (>= 90 %)")
    s.check(r[3] >= 3, "bricks: as several islands (nothing bonds them)")

    var shards = _cells(block, 24, 11, 1e-4)
    var q = _debris_scene(shards, False)
    print(
        "  shards:", Int(q[0]), "fragments, asleep", Int(q[1]), "of", Int(q[2]), "on rigid bodies, islands", Int(q[3]),
        ", on crate", Int(q[4]), ", on ledge", Int(q[5]), ", lowest centre", q[6],
        ", soft top moved", q[7], ", crate sag", q[8], ", max speed", q[9],
    )
    s.check(q[10] > 0.5, "shards: poses finite")
    s.check(q[6] > 0.0, "shards: none sank through the floor")
    s.check(q[4] >= 5, "shards: piled on the rigid crate")
    s.check(q[5] >= 3, "shards: lie on the static ledge")
    s.check(abs(q[7]) > 0.02 and q[11] > 0.5, "shards: the soft body was struck, and stayed sound")
    s.check(q[9] < 1.0, "shards: all slowed below 1 m/s (soft-body pile included)")
    s.check(q[1] >= q[2] * 0.9, "shards: the debris on rigid bodies fell asleep (>= 90 %)")
    s.check(q[3] >= 3, "shards: as several islands")


def case_concave_chain(mut s: Suite) raises:
    """L slab -> voxelise -> decompose -> Voronoi each part -> spawn -> bond."""
    var m = l_prism(0.4)
    var g = voxelize(m.v, m.t, 20)
    var parts = decompose_with(SplitDecomposer(6, 0.03, 10), g)
    s.eqi(parts.count(), 2, "the L decomposes into two parts")
    var seeds = scatter_seeds(Polytope.box(1, 1, 0.2, 1, 1, 0.2).bounds(), 30, 5, 0.0, 0.0, 0.0, 0.0)
    var fs = voronoi_fracture_parts(parts.hulls, seeds, 1e-5)
    print("  L chain: parts", parts.count(), "fragments", fs.count(), "volume", fs.total_volume(), "parts volume", parts.total_volume())
    s.almost(fs.total_volume(), parts.total_volume(), "fragments tile the parts", 1e-6)
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var set = FractureSet(1000, 0)
    var first = set.spawn(sc, fs, Vec3(0, 0.6, 0, 0), Quat.identity(), ZERO, ZERO)
    var n_same = set.bond_neighbors(sc, first, 2e6)
    var n_cross = set.bond_overlapping(sc, first, 2e6)
    print("  L chain: bonds within parts", n_same, "across parts", n_cross)
    s.check(n_same > 0 and n_cross > 0, "bonds inside parts and across the decomposition seam")
    for _ in range(300):
        sc.step_soft(DT, G)
        _ = set.poll(sc)
    var asleep = 0
    var lowest = Float64(1e30)
    for i in range(set.fragments()):
        if sc.bset.sleeping[set.body[i]]:
            asleep += 1
        lowest = min(lowest, Float64(sc.bset.bodies[set.body[i]].position()[1]))
    s.eqi(asleep, set.fragments(), "the bonded concave slab comes to rest asleep")
    s.eqi(sc.island_count(), 1, "one island: it is one structure")
    s.check(lowest > 0.05, "resting above the floor")


def case_runtime_cut(mut s: Suite) raises:
    """Cut a bonded fragment: pieces conserve volume, re-anchor the bonds."""
    var sc = ContactScene6[QuatBody6]()
    var ground = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0),
        True,
    )
    var slab = Polytope.box(0, 0.25, 0, 1.0, 0.25, 0.5)
    var seeds = List[Float64]()
    for q in [-0.5, 0.25, 0.0, 0.5, 0.25, 0.0]:
        seeds.append(q)
    var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(slab, seeds, 0, 0.0, fs)
    var set = FractureSet(1500, 0)
    var first = set.spawn(sc, fs, ZERO, Quat.identity(), ZERO, ZERO)
    _ = set.bond_neighbors(sc, first, 5e6)
    var na = set.anchor(sc, first, ground, ZERO, Quat.identity(), 0.0, -1.0, 0.0, 0.0, 1e-6, 5e6)
    s.eqi(set.live_bonds(), 1 + na, "two halves bonded to each other and the ground")
    for _ in range(30):
        sc.step_soft(DT, G)
    var vol0 = set.vol[0] + set.vol[1]
    var bonds0 = set.live_bonds()
    # cut fragment 0 by a vertical plane through its centre
    var c = sc.bset.bodies[set.body[0]].position()
    var pieces = set.cut_fragment(sc, 0, c, Vec3(1, 0, 0, 0))
    s.eqi(pieces, 2, "the plane splits the fragment in two")
    s.eqi(set.alive_count(), 3, "three live fragments: one half and two pieces")
    var vsum = Float64(0)
    for i in range(set.fragments()):
        if set.alive[i]:
            vsum += set.vol[i]
    s.almost(vsum, vol0, "the cut conserves volume", 1e-9)
    s.eqi(set.live_bonds(), bonds0, "every bond was re-anchored to a piece")
    var finite = True
    for _ in range(120):
        sc.step_soft(DT, G)
        _ = set.poll(sc)
    for i in range(set.fragments()):
        if set.alive[i]:
            var p = sc.bset.bodies[set.body[i]].position()
            if not (p[1] == p[1]) or p[1] < -0.01:
                finite = False
    s.check(finite, "pieces stay finite and above the floor")
    s.eqi(set.live_bonds(), bonds0, "the structure still holds after the cut")
    # a plane that misses the fragment changes nothing
    var alive_before = set.alive_count()
    var far = set.cut_fragment(sc, 2, Vec3(50, 0, 0, 0), Vec3(1, 0, 0, 0))
    s.eqi(far, 1, "a plane that misses leaves one piece")
    s.eqi(set.alive_count(), alive_before, "...and nothing changed")


def case_budget(mut s: Suite) raises:
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var set = FractureSet(800, 12)
    var block = Polytope.box(0, 0, 0, 0.5, 0.5, 0.5)
    var fs = _cells(block, 30, 2, 1e-4)
    _ = set.spawn(sc, fs, Vec3(0, 0.6, 0, 0), Quat.identity(), ZERO, ZERO)
    var n0 = set.alive_count()
    var evicted = 0
    for _ in range(240):
        sc.step_soft(DT, G)
        evicted += set.enforce_budget(sc)
    s.check(n0 >= 25, "a pile of free fragments")
    s.eqi(set.free_count(), 12, "the budget caps free fragments")
    s.eqi(evicted, n0 - 12, "everything beyond the budget was evicted")
    s.eqi(Int(sc.counters.get(FRAGMENT_EVICTED)), evicted, "evictions are counted in diag")
    # smallest-first among equally asleep: survivors are no smaller than the evicted
    var smallest_alive = Float64(1e30)
    var largest_dead = Float64(0)
    for i in range(set.fragments()):
        if set.alive[i]:
            smallest_alive = min(smallest_alive, set.vol[i])
        else:
            largest_dead = max(largest_dead, set.vol[i])
    s.check(smallest_alive >= largest_dead * 0.999, "the smallest fragments went first")
    for _ in range(30):
        sc.step_soft(DT, G)  # the scene still steps with removed bodies
    s.eqi(set.free_count(), 12, "stable afterwards")


# ----------------------------------------------------------------- EXTREME
def case_single(mut s: Suite) raises:
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var block = Polytope.box(0, 0.5, 0, 0.5, 0.5, 0.5)
    var fs = _cells(block, 1, 0, 0.0)
    s.eqi(fs.count(), 1, "one seed: one cell")
    s.almost(fs.total_volume(), block.volume(), "...that is the whole solid", 1e-12)
    var set = FractureSet(800, 0)
    var first = set.spawn(sc, fs, ZERO, Quat.identity(), ZERO, ZERO)
    s.eqi(set.bond_neighbors(sc, first, 1e6), 0, "a single fragment has no bonds")
    for _ in range(120):
        sc.step_soft(DT, G)
    s.almost(Float64(sc.bset.bodies[set.body[0]].position()[1]), 0.5, "it rests like the block it is", 0.03)

    # coincident seeds: the duplicate gets nothing, volume is still conserved
    var seeds = List[Float64]()
    for q in [0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.4, 0.5, 0.0]:
        seeds.append(q)
    var fs2 = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(block, seeds, 0, 0.0, fs2)
    s.eqi(fs2.count(), 2, "coincident seeds make one cell, not two")
    s.almost(fs2.total_volume(), block.volume(), "...volume still conserved", 1e-9)

    # a flat cell is not a body
    var flat = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    flat.cells.append(Polytope.box(0, 5, 0, 0.5, 0.0, 0.5))
    flat.seed.append(0)
    flat.part.append(0)
    var set2 = FractureSet(800, 0)
    var n_before = len(sc.bset.bodies)
    _ = set2.spawn(sc, flat, ZERO, Quat.identity(), ZERO, ZERO)
    s.eqi(set2.fragments(), 0, "a coplanar (flat) cell is skipped")
    s.eqi(len(sc.bset.bodies), n_before, "...and adds no body")

    var bad = 0
    try:
        _ = set.bond_neighbors(sc, 0, 0.0)
    except:
        bad += 1
    try:
        _ = set.cut_fragment(sc, 0, ZERO, ZERO)
    except:
        bad += 1
    try:
        _ = set.cut_fragment(sc, 99, ZERO, Vec3(1, 0, 0, 0))
    except:
        bad += 1
    s.eqi(bad, 3, "zero stress, zero normal and an unknown fragment raise")


def case_thousand(mut s: Suite) raises:
    # a thousand Voronoi cells from one pre-fracture
    var block = Polytope.box(0, 0, 0, 1, 1, 1)
    var fs = _cells(block, 1000, 7, 0.0)
    print("  voronoi:", fs.count(), "cells, volume", fs.total_volume(), "of", block.volume())
    s.check(fs.count() >= 990, "a thousand seeds make ~a thousand cells")
    s.almost(fs.total_volume(), block.volume(), "1000 cells conserve volume", 1e-9)

    # a thousand pieces from ONE runtime cut of a body: 9 x 9 x 9 grid planes
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var one = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    one.cells.append(Polytope.box(0, 0.6, 0, 0.6, 0.6, 0.6))
    one.seed.append(0)
    one.part.append(0)
    var set = FractureSet(800, 0)
    _ = set.spawn(sc, one, ZERO, Quat.identity(), ZERO, ZERO)
    var planes = List[Float64]()
    for ax in range(3):
        for k in range(9):
            var d = (Float64(k) + 1.0) / 10.0 * 1.2 - 0.6
            for z in range(3):
                planes.append(1.0 if z == ax else 0.0)
            planes.append(d)
    var v0 = set.vol[0]
    var pieces = set.cut_fragment_planes(sc, 0, planes)
    var vsum = Float64(0)
    for i in range(set.fragments()):
        if set.alive[i]:
            vsum += set.vol[i]
    print("  one cut:", pieces, "pieces, volume error", abs(vsum - v0))
    s.eqi(pieces, 1000, "27 planes cut one body into 1000 pieces")
    s.eqi(set.alive_count(), 1000, "all 1000 are bodies")
    s.almost(vsum, v0, "volume conserved through 27 cuts", 1e-9)
    var cube_ok = True
    for _ in range(20):
        sc.step_soft(DT, G)
    for i in range(set.fragments()):
        if set.alive[i]:
            var p = sc.bset.bodies[set.body[i]].position()
            if not (p[0] == p[0] and p[1] == p[1] and p[2] == p[2]):
                cube_ok = False
    s.check(cube_ok, "the 1000-piece pile steps without NaN")


def main() raises:
    var s = Suite("fracture")
    case_wall(s)
    case_threshold(s)
    case_debris(s)
    case_concave_chain(s)
    case_runtime_cut(s)
    case_budget(s)
    case_single(s)
    case_thousand(s)
    s.finish()
