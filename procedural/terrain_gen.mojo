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

`hydraulic_erosion` runs water droplets (the particle form of Mei et al.
2007): each starts at a hashed position, rolls down the bilinear
gradient with inertia, gains speed from the drop and loses water to
evaporation; its sediment capacity is max(-dh, min_slope) x speed x water
x `capacity`. Above capacity it deposits, below it erodes (at most the
drop height), both onto the four vertices around it with bilinear weights.
When a droplet stops or would leave the tile it drops everything it
carries where it is, so the total height is conserved up to rounding.

`slope_at` is the gradient magnitude of the bilinear height at (x, z);
`filter_by_slope` keeps the scatter points (17.69 `scatter`) whose slope
is at most `max_slope` -- trees on the flats, none on the cliffs.
"""

from std.math import sqrt
from geometry.vec import Real, Vec2
from .noise import fbm2, _hash


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


def _bilinear(h: List[Real], w: Int, x: Real, z: Real) -> Tuple[Real, Real, Real]:
    """(height, d/dx, d/dz) of the bilinear surface at grid coordinates."""
    var i = Int(x)
    var j = Int(z)
    var fx = x - Real(i)
    var fz = z - Real(j)
    var a = h[j * w + i]
    var b = h[j * w + i + 1]
    var c = h[(j + 1) * w + i]
    var d = h[(j + 1) * w + i + 1]
    var hh = a * (1 - fx) * (1 - fz) + b * fx * (1 - fz) + c * (1 - fx) * fz + d * fx * fz
    var gx = (b - a) * (1 - fz) + (d - c) * fz
    var gz = (c - a) * (1 - fx) + (d - b) * fx
    return (hh, gx, gz)


def _splat(mut h: List[Real], w: Int, x: Real, z: Real, amount: Real):
    var i = Int(x)
    var j = Int(z)
    var fx = x - Real(i)
    var fz = z - Real(j)
    h[j * w + i] += amount * (1 - fx) * (1 - fz)
    h[j * w + i + 1] += amount * fx * (1 - fz)
    h[(j + 1) * w + i] += amount * (1 - fx) * fz
    h[(j + 1) * w + i + 1] += amount * fx * fz


def hydraulic_erosion(
    mut h: List[Real], nx: Int, nz: Int, droplets: Int, seed: Int,
    inertia: Real = 0.05, capacity: Real = 4, min_slope: Real = 0.01,
    erode: Real = 0.3, deposit: Real = 0.3, evaporate: Real = 0.01,
    gravity: Real = 4, lifetime: Int = 30,
) raises:
    """Droplet erosion on an (nx + 1) x (nz + 1) vertex grid, in grid units
    (module note)."""
    if nx < 2 or nz < 2 or len(h) != (nx + 1) * (nz + 1):
        raise Error("hydraulic_erosion: an (nx + 1) x (nz + 1) grid, nx, nz >= 2")
    var w = nx + 1
    var lim_x = Real(nx) - Real(1e-3)
    var lim_z = Real(nz) - Real(1e-3)
    for d in range(droplets):
        var x = Real(Float64(_hash(d, 1, 0xE60D, seed)) / 4294967296.0) * lim_x
        var z = Real(Float64(_hash(d, 2, 0xE60D, seed)) / 4294967296.0) * lim_z
        var dx = Real(0)
        var dz = Real(0)
        var speed = Real(1)
        var water = Real(1)
        var sed = Real(0)
        for _ in range(lifetime):
            var cur = _bilinear(h, w, x, z)
            dx = dx * inertia - cur[1] * (1 - inertia)
            dz = dz * inertia - cur[2] * (1 - inertia)
            var l = sqrt(dx * dx + dz * dz)
            if l <= 0:
                break
            dx /= l
            dz /= l
            var nxp = x + dx
            var nzp = z + dz
            if nxp < 0 or nzp < 0 or nxp > lim_x or nzp > lim_z:
                break
            var dh = _bilinear(h, w, nxp, nzp)[0] - cur[0]
            var cap = max(-dh, min_slope) * speed * water * capacity
            if sed > cap or dh > 0:
                # deposit: fill the pit up to the step (going uphill) or the excess
                var amt = min(dh, sed) if dh > 0 else (sed - cap) * deposit
                sed -= amt
                _splat(h, w, x, z, amt)
            else:
                var amt = min((cap - sed) * erode, -dh)
                sed += amt
                _splat(h, w, x, z, -amt)
            speed = sqrt(max(speed * speed + dh * gravity * -1, Real(0)))
            water *= 1 - evaporate
            x = nxp
            z = nzp
        _splat(h, w, x, z, sed)


def slope_at(h: List[Real], nx: Int, nz: Int, cell: Real, x: Real, z: Real) -> Real:
    """Gradient magnitude (rise / run) of the bilinear height at world (x, z),
    clamped to the tile."""
    var gx = min(max(x / cell, Real(0)), Real(nx) - Real(1e-4))
    var gz = min(max(z / cell, Real(0)), Real(nz) - Real(1e-4))
    var b = _bilinear(h, nx + 1, gx, gz)
    return sqrt(b[1] * b[1] + b[2] * b[2]) / cell


def filter_by_slope(pts: List[Vec2], h: List[Real], nx: Int, nz: Int, cell: Real, max_slope: Real) -> List[Vec2]:
    var out = List[Vec2]()
    for p in pts:
        if slope_at(h, nx, nz, cell, p[0], p[1]) <= max_slope:
            out.append(p)
    return out^
