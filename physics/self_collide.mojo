"""Cloth self-collision: the difference between a flag and a garment.

Both cloth solvers in this engine — the PBD one in `gpu_cloth.mojo` and the VBD
one in `vbd_cloth.mojo` — collide cloth with the world and not with itself, so a
sheet folded over passes straight through its own back face. That is fine for a
banner and disqualifying for clothing, which is the whole reason this exists.

The method is vertex-vertex repulsion under a thickness, applied as a symmetric
position correction in the same style as the XPBD constraints it sits beside. It
is deliberately the simplest correct thing rather than full triangle-triangle
proximity: on a grid whose particle spacing is the rest length, vertex-vertex at
a thickness below that spacing already stops a fold from passing through, and it
composes with the existing constraint loop instead of needing its own solver.
What it does NOT do is stop a fast edge from tunnelling between two vertices in
one step — `collision/toi.mojo` is where that would come from, and the gap is
stated here rather than discovered later.

TOPOLOGICAL NEIGHBOURS ARE EXCLUDED, and this is the part that decides whether
the feature helps or ruins the simulation. A particle's structural and shear
springs hold it at rest length from its immediate grid neighbours; if the
repulsion also pushes those apart it fights the springs directly, and the sheet
inflates or buzzes. Only pairs more than `SKIP` cells apart in grid coordinates
are considered — far enough that no spring connects them, close enough that a
fold is still caught.

Broad phase is a uniform hash rather than a BVH. Cloth particles are all the
same size and roughly the same spacing, which is exactly the case a uniform grid
is best at and a tree is worst at; the engine's BVH variants stay where they
earn their keep, in the rigid-body broadphase.
"""

from std.math import sqrt
from geometry.vec import Real

comptime SKIP = 2  # grid-distance below which a pair is spring-connected


struct SelfCollider(Movable, ImplicitlyDeletable):
    """A uniform hash over cloth particles, rebuilt each step.

    Rebuilt rather than refitted: cloth moves far per step relative to its
    spacing, so an incremental structure would spend more on updates than a
    rebuild costs. The cell lists are kept as flat `List[Int]` buckets in a
    single array with per-cell starts, so a rebuild is two counting passes and
    no allocation per cell."""

    var cell: Real
    var nbuckets: Int
    var start: List[Int]
    var items: List[Int]

    def __init__(out self, cell: Real, nbuckets: Int = 8192):
        self.cell = cell
        self.nbuckets = nbuckets
        self.start = List[Int]()
        self.items = List[Int]()

    def _hash(self, ix: Int, iy: Int, iz: Int) -> Int:
        var h = (ix * 92837111) ^ (iy * 689287499) ^ (iz * 283923481)
        var m = h % self.nbuckets
        return m + self.nbuckets if m < 0 else m

    def _cellof(self, v: Float32) -> Int:
        var q = Real(v) / self.cell
        var i = Int(q)
        return i - 1 if q < 0 and Real(i) != q else i

    def rebuild(
        mut self, px: List[Float32], py: List[Float32], pz: List[Float32]
    ):
        var n = len(px)
        self.start = List[Int](capacity=self.nbuckets + 1)
        for _ in range(self.nbuckets + 1):
            self.start.append(0)
        var count = List[Int](capacity=self.nbuckets)
        for _ in range(self.nbuckets):
            count.append(0)
        for i in range(n):
            count[
                self._hash(
                    self._cellof(px[i]), self._cellof(py[i]), self._cellof(pz[i])
                )
            ] += 1
        var acc = 0
        for b in range(self.nbuckets):
            self.start[b] = acc
            acc += count[b]
        self.start[self.nbuckets] = acc
        self.items = List[Int](capacity=acc)
        for _ in range(acc):
            self.items.append(0)
        var cursor = List[Int](capacity=self.nbuckets)
        for b in range(self.nbuckets):
            cursor.append(self.start[b])
        for i in range(n):
            var b = self._hash(
                self._cellof(px[i]), self._cellof(py[i]), self._cellof(pz[i])
            )
            self.items[cursor[b]] = i
            cursor[b] += 1


def resolve_self_collisions(
    mut px: List[Float32], mut py: List[Float32], mut pz: List[Float32],
    w: List[Float32], width: Int, thickness: Real,
    mut grid: SelfCollider,
) -> Int:
    """One repulsion pass. Returns the number of pairs corrected, so a caller
    (and a test) can tell "nothing was touching" from "nothing was done".

    Corrections are weighted by inverse mass and applied symmetrically, so a
    pinned particle absorbs none of the displacement and momentum is not
    injected — the same convention as every other positional constraint here.
    """
    grid.rebuild(px, py, pz)
    var t2 = thickness * thickness
    var hits = 0
    var n = len(px)
    for i in range(n):
        var ci = grid._cellof(px[i])
        var cj = grid._cellof(py[i])
        var ck = grid._cellof(pz[i])
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                for dz in range(-1, 2):
                    var b = grid._hash(ci + dx, cj + dy, ck + dz)
                    for s in range(grid.start[b], grid.start[b + 1]):
                        var j = grid.items[s]
                        if j <= i:
                            continue  # each pair once
                        # topological exclusion: a spring already holds these
                        var ri = i // width
                        var cix = i % width
                        var rj = j // width
                        var cjx = j % width
                        var dr = ri - rj if ri > rj else rj - ri
                        var dc = cix - cjx if cix > cjx else cjx - cix
                        if dr <= SKIP and dc <= SKIP:
                            continue
                        var ex = Real(px[i] - px[j])
                        var ey = Real(py[i] - py[j])
                        var ez = Real(pz[i] - pz[j])
                        var d2 = ex * ex + ey * ey + ez * ez
                        if d2 >= t2:
                            continue
                        var wi = Real(w[i])
                        var wj = Real(w[j])
                        var wsum = wi + wj
                        if wsum <= 0:
                            continue  # both pinned: nothing to move
                        var d = Real(0)
                        var nx = Real(0)
                        var ny = Real(1)
                        var nz = Real(0)
                        if d2 > 1e-12:
                            d = Real(sqrt(Float64(d2)))
                            nx = ex / d
                            ny = ey / d
                            nz = ez / d
                        # Exactly coincident particles have no direction to
                        # separate along. Pushing along a fixed axis is
                        # arbitrary but deterministic, and doing nothing would
                        # leave them welded together forever.
                        var pen = thickness - d
                        var si = pen * wi / wsum
                        var sj = pen * wj / wsum
                        px[i] += Float32(nx * si)
                        py[i] += Float32(ny * si)
                        pz[i] += Float32(nz * si)
                        px[j] -= Float32(nx * sj)
                        py[j] -= Float32(ny * sj)
                        pz[j] -= Float32(nz * sj)
                        hits += 1
    return hits
