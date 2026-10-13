"""Height-field generation (ROADMAP 17.69).

`terrain_height(x, z, p)` is a pure function of the world position and the
parameters: fBm (`noise.fbm2`), optionally ridged (1 - |n|, squared) and
domain-warped (the sample position displaced by two more fBm fields). Since
it reads only (x, z, seed), tiles generated separately agree bit for bit on
their shared edge, in any order and on any thread.

`height_tile` fills an (nx + 1) x (nz + 1) vertex grid for one tile
(row-major, x fastest), the layout `collision.HeightField` takes; this
package only produces the array (`collision` is a higher layer).

`thermal_erosion` moves material downhill wherever the slope to a
neighbour exceeds the talus angle (Musgrave 1989): each pass moves
`rate` x the excess, split among the steeper neighbours; mass is conserved.
It is a whole-tile pass, so eroded tiles are no longer seam-exact.
"""

from geometry.vec import Real
from .noise import fbm2


@fieldwise_init
struct TerrainParams(Copyable, ImplicitlyCopyable, Movable):
    var seed: Int
    var scale: Real  # world metres per noise unit
    var amplitude: Real  # metres
    var octaves: Int
    var ridged: Bool
    var warp: Real  # domain warp strength in noise units (0 = off)

    @staticmethod
    def default(seed: Int) -> Self:
        return Self(seed, 64, 20, 5, False, 0)


def terrain_height(x: Real, z: Real, p: TerrainParams) -> Real:
    var u = x / p.scale
    var v = z / p.scale
    if p.warp != 0:
        var wu = fbm2(u + 5.2, v + 1.3, p.seed + 101, 3)
        var wv = fbm2(u - 3.7, v + 9.1, p.seed + 202, 3)
        u += p.warp * wu
        v += p.warp * wv
    var n = fbm2(u, v, p.seed, p.octaves)
    if p.ridged:
        var r = 1 - abs(n)
        return p.amplitude * (r * r)
    return p.amplitude * n


def height_tile(tx: Int, tz: Int, nx: Int, nz: Int, cell: Real, p: TerrainParams) raises -> List[Real]:
    """Vertex heights of tile (tx, tz): vertices at world
    ((tx * nx + i) cell, (tz * nz + j) cell), i in [0, nx], j in [0, nz]."""
    if nx < 1 or nz < 1 or cell <= 0:
        raise Error("height_tile: nx, nz >= 1 and cell > 0")
    var h = List[Real](capacity=(nx + 1) * (nz + 1))
    for j in range(nz + 1):
        for i in range(nx + 1):
            h.append(terrain_height(Real(tx * nx + i) * cell, Real(tz * nz + j) * cell, p))
    return h^


def thermal_erosion(mut h: List[Real], nx: Int, nz: Int, cell: Real, talus: Real, rate: Real, passes: Int):
    """`h` is an (nx + 1) x (nz + 1) vertex grid; `talus` is the steepest
    stable slope (rise / run)."""
    var w = nx + 1
    var limit = talus * cell
    for _ in range(passes):
        var delta = List[Real](length=len(h), fill=0)
        for j in range(nz + 1):
            for i in range(w):
                var c = j * w + i
                var total = Real(0)
                var dmax = Real(0)
                var di: List[Int] = [-1, 1, 0, 0]
                var dj: List[Int] = [0, 0, -1, 1]
                for k in range(4):
                    var ii = i + di[k]
                    var jj = j + dj[k]
                    if ii < 0 or ii >= w or jj < 0 or jj > nz:
                        continue
                    var d = h[c] - h[jj * w + ii]
                    if d > limit:
                        total += d - limit
                        dmax = max(dmax, d - limit)
                if total <= 0:
                    continue
                var move = rate * dmax * Real(0.5)
                for k in range(4):
                    var ii = i + di[k]
                    var jj = j + dj[k]
                    if ii < 0 or ii >= w or jj < 0 or jj > nz:
                        continue
                    var d = h[c] - h[jj * w + ii]
                    if d > limit:
                        var share = move * (d - limit) / total
                        delta[c] -= share
                        delta[jj * w + ii] += share
        for c in range(len(h)):
            h[c] += delta[c]


def max_slope(h: List[Real], nx: Int, nz: Int, cell: Real) -> Real:
    var w = nx + 1
    var m = Real(0)
    for j in range(nz + 1):
        for i in range(w):
            if i + 1 < w:
                m = max(m, abs(h[j * w + i + 1] - h[j * w + i]) / cell)
            if j + 1 <= nz:
                m = max(m, abs(h[(j + 1) * w + i] - h[j * w + i]) / cell)
    return m
