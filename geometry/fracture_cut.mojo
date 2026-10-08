"""Pre-fracture patterns and runtime cuts on convex solids (ROADMAP 17.5).

Three ways to turn one convex polytope into many, all built from the single
primitive `polytope_split` (so they inherit its watertightness):

  * `voronoi_fracture`  Voronoi cells of a seed set -- the pre-cut pattern.
    Each cell is the source solid cut by the bisector plane against every
    neighbour that can reach it; the cap of each cut carries the NEIGHBOUR'S
    seed index as its tag, which is how a bond between two fragments later
    finds the seam they share (`Polytope.tag_patch`).
  * `voronoi_fracture_parts`  the same, applied to every part of a convex
    decomposition (`convex_decomp`), so a concave solid is fractured too.
  * `cut_by_planes`  the runtime cut: any number of planes at once, a piece
    is split by every plane that crosses it (a 3-axis grid of 9 planes per
    axis gives a thousand pieces from one call).

EXACT NEIGHBOUR PRUNING: a bisector plane lies `|s_j - s_i| / 2` from seed i, so
it can only matter while that is less than the cell's current radius around
`s_i`. A cell is first cut by its nearest few seeds (which shrinks it fast) and
then by exactly the seeds still inside twice its radius -- no neighbour that
could change the cell is skipped, and the thousand-seed case does not pay the
all-pairs cost.
"""

from std.math import sqrt
from .polytope import Polytope, polytope_split


@fieldwise_init
struct FragmentSet(Movable):
    """Fragments of one fracture: the convex `cells`, the `seed` index that
    produced each, and the `part` of the source decomposition it came from."""

    var cells: List[Polytope]
    var seed: List[Int]
    var part: List[Int]

    def count(self) -> Int:
        return len(self.cells)

    def total_volume(self) -> Float64:
        var v = Float64(0)
        for i in range(len(self.cells)):
            v += self.cells[i].volume()
        return v


struct _Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed * 6364136223846793005 + 1442695040888963407

    def next(mut self) -> Float64:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return Float64(self.s >> 11) / Float64(1 << 53)


def scatter_seeds(
    bounds: List[Float64],
    n: Int,
    rng_seed: Int,
    focus_x: Float64,
    focus_y: Float64,
    focus_z: Float64,
    focus: Float64,
) -> List[Float64]:
    """`n` seeds (flat x, y, z) inside `bounds` = [min, max]. `focus` in
    [0, 1) pulls them toward (focus_x, focus_y, focus_z) -- an impact point --
    so cells are small where the hit lands and large far from it; 0 is
    uniform. Deterministic in `rng_seed`."""
    var out = List[Float64](capacity=3 * n)
    var r = _Rng(UInt64(rng_seed) + 1)
    for _ in range(n):
        for a in range(3):
            var u = r.next()
            var lo = bounds[a]
            var hi = bounds[3 + a]
            var x = lo + u * (hi - lo)
            var fa = focus_x if a == 0 else (focus_y if a == 1 else focus_z)
            if focus > 0:
                # blend toward the focus point, more strongly for small u^2
                x = x + (fa - x) * focus * (1 - u * u)
            out.append(x)
    return out^


def voronoi_cell(src: Polytope, seeds: List[Float64], i: Int, min_volume: Float64) -> Polytope:
    """The part of convex `src` nearer seed `i` than any other seed (empty if
    there is none, or if its volume is below `min_volume`)."""
    var n = len(seeds) // 3
    var sx = seeds[3 * i]
    var sy = seeds[3 * i + 1]
    var sz = seeds[3 * i + 2]
    var cell = src.copy()
    var radius = cell.radius_from(sx, sy, sz)
    var d2 = List[Float64](capacity=n)
    var used = List[Bool](capacity=n)
    for j in range(n):
        var dx = seeds[3 * j] - sx
        var dy = seeds[3 * j + 1] - sy
        var dz = seeds[3 * j + 2] - sz
        d2.append(dx * dx + dy * dy + dz * dz)
        used.append(j == i)
    var eps = max(radius, 1e-12) * 1e-9
    # phase 1: nearest few seeds
    var order = List[Int]()
    var take = min(n - 1, 12)
    for _ in range(take):
        var bj = -1
        for j in range(n):
            if used[j]:
                continue
            if bj < 0 or d2[j] < d2[bj]:
                bj = j
        if bj < 0:
            break
        used[bj] = True
        order.append(bj)
    # phase 2 happens after phase 1 has shrunk the cell
    var phase = 0
    var cursor = 0
    while True:
        var j = -1
        if phase == 0:
            if cursor < len(order):
                j = order[cursor]
                cursor += 1
            else:
                phase = 1
                continue
        else:
            # any remaining seed whose bisector can still reach the cell
            var lim = 2 * radius
            for q in range(n):
                if not used[q] and d2[q] < lim * lim:
                    j = q
                    break
            if j < 0:
                break
            used[j] = True
        if d2[j] <= 1e-24:
            # coincident seeds: the lower index keeps the cell
            if j < i:
                return Polytope.empty()
            continue
        var dd = sqrt(d2[j])
        var nx = (seeds[3 * j] - sx) / dd
        var ny = (seeds[3 * j + 1] - sy) / dd
        var nz = (seeds[3 * j + 2] - sz) / dd
        var d = nx * (sx + seeds[3 * j]) / 2 + ny * (sy + seeds[3 * j + 1]) / 2 + nz * (sz + seeds[3 * j + 2]) / 2
        var r = polytope_split(cell, nx, ny, nz, d, j, eps)
        if r.back.is_empty():
            return Polytope.empty()
        cell = r^.into_back()
        if cell.nt() > 120:
            cell = cell.simplified(eps)
        radius = cell.radius_from(sx, sy, sz)
    if cell.volume() < min_volume:
        return Polytope.empty()
    return cell.simplified(eps)


def voronoi_fracture(
    src: Polytope, seeds: List[Float64], part: Int, min_volume: Float64, mut out: FragmentSet
):
    """Append the Voronoi cells of `seeds` inside convex `src` to `out`."""
    for i in range(len(seeds) // 3):
        var c = voronoi_cell(src, seeds, i, min_volume)
        if c.is_empty():
            continue
        out.cells.append(c^)
        out.seed.append(i)
        out.part.append(part)


def voronoi_fracture_parts(
    parts: List[Polytope], seeds: List[Float64], min_volume: Float64
) -> FragmentSet:
    """Voronoi fracture of every convex part (a concave solid's decomposition)."""
    var out = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    for p in range(len(parts)):
        voronoi_fracture(parts[p], seeds, p, min_volume, out)
    return out^


def cut_by_planes(src: Polytope, planes: List[Float64], min_volume: Float64) -> List[Polytope]:
    """Split convex `src` by every plane (flat `[nx, ny, nz, d]` per plane; `n`
    need not be unit): each piece is cut by each plane that crosses it. Cap
    tags are the plane index. Pieces under `min_volume` are dropped."""
    var pieces = List[Polytope]()
    pieces.append(src.copy())
    for k in range(len(planes) // 4):
        var nx = planes[4 * k]
        var ny = planes[4 * k + 1]
        var nz = planes[4 * k + 2]
        var d = planes[4 * k + 3]
        var nl = sqrt(nx * nx + ny * ny + nz * nz)
        if nl < 1e-300:
            continue
        nx /= nl
        ny /= nl
        nz /= nl
        d /= nl
        var next = List[Polytope]()
        for p in range(len(pieces)):
            var r = polytope_split(pieces[p], nx, ny, nz, d, k, 1e-9)
            if r.front.is_empty() or r.back.is_empty():
                next.append(pieces[p].copy())
            else:
                var pair = r^.into_pair()
                next.append(pair[0].copy())
                next.append(pair[1].copy())
        pieces = next^
    var out = List[Polytope]()
    for p in range(len(pieces)):
        if pieces[p].volume() >= min_volume:
            out.append(pieces[p].simplified(1e-9))
    return out^
