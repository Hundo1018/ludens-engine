"""Strand extensions (ROADMAP 17.57): snapshots, scene collision, strand-
strand interaction and guide-hair interpolation for a `StrandSet`. Free
functions, applied after `StrandSet.step`, which stays as it was.

  * `strands_write` / `strands_read`: particle positions and velocities
    through the `StateWriter` / `StateReader` pair (the rest of a strand set
    is its construction); continuing from a restored copy is bit for bit.
  * `strands_collide(strands, scene, dt, mu)`: root to tip, put every
    particle back at rest length from its predecessor, then push it out of
    every collider of a `ContactScene6` (`fem_scene.point_contact`:
    box through its entry face, sphere / capsule radially, other shapes
    through the collider registry) with position-level Coulomb friction; the
    particle velocity takes the correction over the step. One-way: strands
    are light and do not push bodies.
  * `strands_interact(strands, cell, k)`: hair-hair friction in the manner
    of Petrovic et al. 2005: particle velocities are averaged per voxel of
    size `cell` (a hash map, no O(n^2) pairs) and every non-root particle's
    velocity moves toward its voxel's average by `k` in [0, 1]. Momentum
    within a voxel is kept (the average of the changes is zero for equal
    particle masses).
  * `interpolate_strand(guides, weights, root)`: a rendered strand from
    simulated guides: the weighted sum of the guides' particle offsets from
    their roots, placed at `root` (weights normalised). One guide with
    weight 1 reproduces that guide translated to `root`.
"""

from geometry.vec import Real, Vec3, length, dot
from .rigid6 import Body6
from .solver6 import ContactScene6
from .state_io import StateWriter, StateReader
from .strand import StrandSet
from .fem_scene import point_contact
from .soft_couple import soft_fric


def strands_write[W: StateWriter](s: StrandSet, mut w: W):
    w.wi(len(s.x))
    for i in range(len(s.x)):
        w.wv(s.x[i])
        w.wv(s.v[i])
        w.wf(s.twist[i])


def strands_read[R: StateReader](mut s: StrandSet, mut r: R) raises:
    var n = r.ri()
    if n != len(s.x):
        raise Error("strands_read: particle count differs from this strand set")
    for i in range(n):
        s.x[i] = r.rv()
        s.v[i] = r.rv()
        s.twist[i] = r.rf()


def strands_collide[B: Body6](mut s: StrandSet, scene: ContactScene6[B], dt: Real, mu: Real = 0.3) raises -> Int:
    """Push particles out of the scene's colliders; returns contacts made."""
    if not (dt > 0) or not (mu >= 0):
        raise Error("strands_collide: dt > 0 and mu >= 0")
    var hits = 0
    for st in range(len(s.start)):
        var l = s.seg[st]
        for k in range(1, s.count[st]):
            var i = s.start[st] + k
            var x = s.x[i]
            var v = s.v[i]
            # back to rest length from the (already corrected) predecessor,
            # as the strand step does, before pushing out
            var prev = s.x[i - 1]
            var d = x - prev
            var dl = length(d)
            if dl > 1e-12:
                var y = prev + d * (l / dl)
                v = v + (y - x) * (1 / dt)
                x = y
            for b in range(len(scene.bset.bodies)):
                if scene.bset.is_removed(b):
                    continue
                var res = point_contact(scene, b, x, x - v * dt, s.radius, dt)
                if not res[0]:
                    continue
                var nw = res[1]
                if mu > 0:
                    nw = soft_fric(scene.bset, b, x, x - v * dt, nw, res[2], dt, mu)
                v = v + (nw - x) * (1 / dt)
                x = nw
                hits += 1
            s.x[i] = x
            s.v[i] = v
    return hits


def _key(p: Vec3, inv: Real) -> Int:
    var ix = Int(p[0] * inv + 1e6) - 1000000
    var iy = Int(p[1] * inv + 1e6) - 1000000
    var iz = Int(p[2] * inv + 1e6) - 1000000
    return (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791)


def strands_interact(mut s: StrandSet, cell: Real, k: Real) raises:
    """Voxel velocity smoothing between strands (module note)."""
    if not (cell > 0) or not (k >= 0 and k <= 1):
        raise Error("strands_interact: cell > 0 and k in [0, 1]")
    var inv = 1 / cell
    var sums = Dict[Int, Int]()  # voxel key -> slot
    var acc = List[Vec3]()
    var cnt = List[Int]()
    var slot = List[Int](length=len(s.x), fill=-1)
    for st in range(len(s.start)):
        for q in range(1, s.count[st]):
            var i = s.start[st] + q
            var key = _key(s.x[i], inv)
            var j = sums.get(key, -1)
            if j < 0:
                j = len(acc)
                sums[key] = j
                acc.append(Vec3(0, 0, 0, 0))
                cnt.append(0)
            acc[j] = acc[j] + s.v[i]
            cnt[j] += 1
            slot[i] = j
    for i in range(len(s.x)):
        var j = slot[i]
        if j < 0 or cnt[j] < 2:
            continue
        var avg = acc[j] * (1 / Real(cnt[j]))
        s.v[i] = s.v[i] + (avg - s.v[i]) * k


def interpolate_strand(guides: List[List[Vec3]], weights: List[Real], root: Vec3) raises -> List[Vec3]:
    """A rendered strand from guides (module note). Guides must have the
    same particle count; raises on mismatch, no guides or zero total
    weight."""
    if len(guides) == 0 or len(weights) != len(guides):
        raise Error("interpolate_strand: one weight per guide, at least one guide")
    var n = len(guides[0])
    var wsum = Real(0)
    for g in range(len(guides)):
        if len(guides[g]) != n:
            raise Error("interpolate_strand: guides differ in particle count")
        wsum += weights[g]
    if not (abs(wsum) > 0):
        raise Error("interpolate_strand: weights sum to zero")
    var out = List[Vec3](capacity=n)
    for k in range(n):
        var off = Vec3(0, 0, 0, 0)
        for g in range(len(guides)):
            off = off + (guides[g][k] - guides[g][0]) * (weights[g] / wsum)
        out.append(root + off)
    return out^
