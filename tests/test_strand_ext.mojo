# tier: integration
"""Strand snapshots, scene collision, interaction and guide interpolation
(ROADMAP 17.57, `physics.strand_ext`).

  1. Ordinary: a strand set snapshotted after 1 s (`strands_write`) and
     restored into a fresh set continues 60 steps bit for bit. One guide
     with weight 1 reproduces that guide at the new root exactly; two
     guides at 0.5 give the mean of their offsets.
  2. Integration: 16 strands hanging over a static box in the scene
     (`strands_collide`): no particle ends inside the box (deeper than the
     strand radius plus 1 mm); the worst segment stretches 7 % at the box
     edge (the push after the length fix lengthens the segment it moves, as
     in `StrandSet.step`): asserted < 10 %. Strands
     swinging with different start velocities: `strands_interact` (2 cm
     voxels, k 0.3) cuts the spread of particle velocities within a voxel
     (printed: mean deviation from the voxel average with and without)
     and keeps each voxel's momentum (1e-5).
  3. Extreme: dt <= 0 / mu < 0, cell <= 0 / k outside [0, 1], a guide count
     mismatch and zero total weight raise; restoring into a set with a
     different particle count raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6, QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import BinWriter, BinReader
from physics.strand import StrandSet
from physics.strand_ext import strands_write, strands_read, strands_collide, strands_interact, interpolate_strand

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0, 0)


def _set(n: Int) raises -> StrandSet:
    var ss = StrandSet(0.1, 0.5, 0.9, 0.003)
    var bone = Pose6(Vec3(0, 1.0, 0, 0), Quat(0, 0, 0, 1))
    for k in range(n):
        _ = ss.add(0, bone, Vec3(Real(k % 4) * 0.05 - 0.075, 0, Real(k // 4) * 0.05 - 0.075, 0), Vec3(0.3, -1, 0, 0), 12, 0.04)
    return ss^


def _spread(s: StrandSet, cell: Real) -> Tuple[Real, Vec3]:
    """(mean |v - voxel average| over particles in shared voxels, sum of
    velocities of those particles)."""
    var sums = Dict[Int, Int]()
    var acc = List[Vec3]()
    var cnt = List[Int]()
    var slot = List[Int](length=len(s.x), fill=-1)
    for st in range(len(s.start)):
        for q in range(1, s.count[st]):
            var i = s.start[st] + q
            var p = s.x[i]
            var key = (Int(p[0] / cell + 1e6) * 73856093) ^ (Int(p[1] / cell + 1e6) * 19349663) ^ (Int(p[2] / cell + 1e6) * 83492791)
            var j = sums.get(key, -1)
            if j < 0:
                j = len(acc)
                sums[key] = j
                acc.append(Vec3(0, 0, 0, 0))
                cnt.append(0)
            acc[j] = acc[j] + s.v[i]
            cnt[j] += 1
            slot[i] = j
    var dev = Real(0)
    var m = 0
    var tot = Vec3(0, 0, 0, 0)
    for i in range(len(s.x)):
        var j = slot[i]
        if j < 0 or cnt[j] < 2:
            continue
        dev += length(s.v[i] - acc[j] * (1 / Real(cnt[j])))
        tot = tot + s.v[i]
        m += 1
    return (dev / Real(max(m, 1)), tot)


def main() raises:
    var s = Suite("strand_ext")
    var bones: List[Pose6] = [Pose6(Vec3(0, 1.0, 0, 0), Quat(0, 0, 0, 1))]

    # ---- snapshot ------------------------------------------------------------------------------------
    var a = _set(8)
    for _ in range(120):
        a.step(DT, G, bones)
    var w = BinWriter()
    strands_write(a, w)
    var b = _set(8)
    var r = BinReader(w.b.copy())
    strands_read(b, r)
    for _ in range(60):
        a.step(DT, G, bones)
        b.step(DT, G, bones)
    var same = True
    for i in range(len(a.x)):
        same = same and a.x[i] == b.x[i] and a.v[i] == b.v[i]
    s.check(same, "restored strands continue bit for bit")

    # ---- guides --------------------------------------------------------------------------------------
    var g1: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(0, -1, 0, 0), Vec3(0.2, -2, 0, 0)]
    var g2: List[Vec3] = [Vec3(1, 0, 0, 0), Vec3(1.4, -1, 0, 0), Vec3(1.4, -2, 0.2, 0)]
    var gs: List[List[Vec3]] = [g1.copy(), g2.copy()]
    var only1 = interpolate_strand(gs, [1.0, 0.0], Vec3(5, 5, 5, 0))
    var half = interpolate_strand(gs, [0.5, 0.5], Vec3(0, 0, 0, 0))
    var exact = True
    for k in range(3):
        exact = exact and only1[k] == g1[k] + Vec3(5, 5, 5, 0)
    print("  guide blend 0.5 / 0.5, tip", half[2], " (mean offset (0.3, -2, 0.1))")
    s.check(exact and length(half[2] - Vec3(0.3, -2, 0.1, 0)) < 1e-6, "one guide reproduces it at the new root; two blend their offsets")

    # ---- collision with a scene box -----------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    var box = sc.add(QuatBody6.at_rest(Vec3(0.15, 0.6, 0, 0), Inertia3.box(1, 0.2, 0.1, 0.2)), Vec3(0.2, 0.1, 0.2, 0), True)
    var c = _set(16)
    var hits = 0
    for _ in range(240):
        c.step(DT, G, bones)
        hits += strands_collide(c, sc, DT, 0.3)
    var inside = 0
    for i in range(len(c.x)):
        var lp = sc.bset.bodies[box.index()].to_local(c.x[i])
        if abs(lp[0]) < 0.2 + c.radius - 1e-3 and abs(lp[1]) < 0.1 + c.radius - 1e-3 and abs(lp[2]) < 0.2 + c.radius - 1e-3:
            inside += 1
    print("  16 strands over a box, 2 s: contacts", hits, " particles inside", inside, " max stretch", c.max_stretch())
    s.check(hits > 0 and inside == 0 and c.max_stretch() < 0.1, "strands drape over the box: none inside, stretch < 10 %")

    # ---- interaction --------------------------------------------------------------------------------
    var plain = Real(0)
    var mixed = Real(0)
    var momentum_ok = True
    for mode in range(2):
        var d = _set(16)
        for st in range(len(d.start)):
            for q in range(1, d.count[st]):
                d.v[d.start[st] + q] = Vec3(Real(st % 3) - 1, 0, Real(st % 5) * 0.5 - 1, 0)
        for _ in range(30):
            d.step(DT, Vec3(0, 0, 0, 0), bones)
        if mode == 1:
            var before = _spread(d, 0.02)
            strands_interact(d, 0.02, 0.3)
            var after = _spread(d, 0.02)
            mixed = after[0]
            momentum_ok = length(after[1] - before[1]) <= 1e-5 * max(length(before[1]), Real(1))
            plain = before[0]
    print("  voxel velocity spread before", plain, " after interaction", mixed)
    s.check(mixed < 0.75 * plain and momentum_ok, "interaction pulls voxel neighbours together (k 0.3) and keeps their momentum")

    # ---- extremes -----------------------------------------------------------------------------------
    var raised = 0
    try:
        _ = strands_collide(c, sc, 0, 0.3)
    except:
        raised += 1
    try:
        _ = strands_collide(c, sc, DT, -1)
    except:
        raised += 1
    try:
        strands_interact(c, 0, 0.3)
    except:
        raised += 1
    try:
        strands_interact(c, 0.02, 1.5)
    except:
        raised += 1
    var short: List[Vec3] = [Vec3(0, 0, 0, 0)]
    var bad: List[List[Vec3]] = [g1.copy(), short.copy()]
    try:
        _ = interpolate_strand(bad, [0.5, 0.5], Vec3(0, 0, 0, 0))
    except:
        raised += 1
    try:
        _ = interpolate_strand(gs, [0.0, 0.0], Vec3(0, 0, 0, 0))
    except:
        raised += 1
    var w2 = BinWriter()
    strands_write(a, w2)
    var small = _set(2)
    var r2 = BinReader(w2.b.copy())
    try:
        strands_read(small, r2)
    except:
        raised += 1
    s.check(raised == 7, "bad arguments and a particle-count mismatch raise")
    s.finish()
