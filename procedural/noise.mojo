"""Seedable coherent-noise family: value, Perlin (gradient), Worley
(cellular), and fractal (fBm) sums, in 2D and 3D.

All functions are PURE functions of (coords, seed) via an integer lattice
hash — no permutation table, no RNG state — so results are deterministic and
reproducible across runs and machines (`test_noise`). Value and Perlin
outputs lie in roughly [-1, 1]; Worley returns a distance ≥ 0; fBm inherits
its base's range. The lattice hash makes noise C¹-continuous across cell
boundaries (quintic fade for Perlin, so gradients are continuous too), which
`test_noise` checks by finite differences.
"""

from std.math import floor, sqrt
from geometry.vec import Real


# --- integer lattice hash -------------------------------------------------

def _hash(ix: Int, iy: Int, iz: Int, seed: Int) -> UInt32:
    """A small integer mix (xxhash-flavoured) of the lattice cell + seed."""
    var h = UInt32(seed & 0xFFFFFFFF)
    h = (h ^ UInt32(ix & 0xFFFFFFFF)) * 2654435761
    h = (h ^ UInt32(iy & 0xFFFFFFFF)) * 2246822519
    h = (h ^ UInt32(iz & 0xFFFFFFFF)) * 3266489917
    h = h ^ (h >> 15)
    h = h * 2246822519
    h = h ^ (h >> 13)
    return h


def _uni(h: UInt32) -> Real:
    """UInt32 -> [-1, 1)."""
    return Real(Float64(h) / 2147483647.5 - 1.0)


def _uni01(h: UInt32) -> Real:
    """UInt32 -> [0, 1)."""
    return Real(Float64(h) / 4294967296.0)


def _fade(t: Real) -> Real:
    """Quintic 6t⁵−15t⁴+10t³ (C² fade -> continuous value AND gradient)."""
    return t * t * t * (t * (t * 6 - 15) + 10)


def _lerp(a: Real, b: Real, t: Real) -> Real:
    return a + t * (b - a)


# --- Perlin gradient dots (Ken Perlin's improved-noise selectors) ---------

def _grad3(h: UInt32, x: Real, y: Real, z: Real) -> Real:
    var hh = Int(h & 15)
    var u = x if hh < 8 else y
    var v = y if hh < 4 else (x if (hh == 12 or hh == 14) else z)
    var r1 = u if (hh & 1) == 0 else -u
    var r2 = v if (hh & 2) == 0 else -v
    return r1 + r2


def _grad2(h: UInt32, x: Real, y: Real) -> Real:
    var hh = Int(h & 7)
    var u = x if hh < 4 else y
    var v = y if hh < 4 else x
    var r1 = u if (hh & 1) == 0 else -u
    var r2 = v if (hh & 2) == 0 else -v
    return r1 + r2


# --- value noise ----------------------------------------------------------

def value3(x: Real, y: Real, z: Real, seed: Int = 0) -> Real:
    """Trilinearly interpolated hashed lattice values, in [-1, 1]."""
    var ix = Int(floor(x))
    var iy = Int(floor(y))
    var iz = Int(floor(z))
    var fx = x - Real(ix)
    var fy = y - Real(iy)
    var fz = z - Real(iz)
    var u = _fade(fx)
    var v = _fade(fy)
    var w = _fade(fz)

    var c000 = _uni(_hash(ix, iy, iz, seed))
    var c100 = _uni(_hash(ix + 1, iy, iz, seed))
    var c010 = _uni(_hash(ix, iy + 1, iz, seed))
    var c110 = _uni(_hash(ix + 1, iy + 1, iz, seed))
    var c001 = _uni(_hash(ix, iy, iz + 1, seed))
    var c101 = _uni(_hash(ix + 1, iy, iz + 1, seed))
    var c011 = _uni(_hash(ix, iy + 1, iz + 1, seed))
    var c111 = _uni(_hash(ix + 1, iy + 1, iz + 1, seed))

    var x00 = _lerp(c000, c100, u)
    var x10 = _lerp(c010, c110, u)
    var x01 = _lerp(c001, c101, u)
    var x11 = _lerp(c011, c111, u)
    return _lerp(_lerp(x00, x10, v), _lerp(x01, x11, v), w)


# --- Perlin gradient noise ------------------------------------------------

def perlin3(x: Real, y: Real, z: Real, seed: Int = 0) -> Real:
    """3D gradient noise, ~[-1, 1] (scaled so a single octave stays in range)."""
    var ix = Int(floor(x))
    var iy = Int(floor(y))
    var iz = Int(floor(z))
    var fx = x - Real(ix)
    var fy = y - Real(iy)
    var fz = z - Real(iz)
    var u = _fade(fx)
    var v = _fade(fy)
    var w = _fade(fz)

    var n000 = _grad3(_hash(ix, iy, iz, seed), fx, fy, fz)
    var n100 = _grad3(_hash(ix + 1, iy, iz, seed), fx - 1, fy, fz)
    var n010 = _grad3(_hash(ix, iy + 1, iz, seed), fx, fy - 1, fz)
    var n110 = _grad3(_hash(ix + 1, iy + 1, iz, seed), fx - 1, fy - 1, fz)
    var n001 = _grad3(_hash(ix, iy, iz + 1, seed), fx, fy, fz - 1)
    var n101 = _grad3(_hash(ix + 1, iy, iz + 1, seed), fx - 1, fy, fz - 1)
    var n011 = _grad3(_hash(ix, iy + 1, iz + 1, seed), fx, fy - 1, fz - 1)
    var n111 = _grad3(
        _hash(ix + 1, iy + 1, iz + 1, seed), fx - 1, fy - 1, fz - 1
    )

    var x00 = _lerp(n000, n100, u)
    var x10 = _lerp(n010, n110, u)
    var x01 = _lerp(n001, n101, u)
    var x11 = _lerp(n011, n111, u)
    # ×0.97 keeps the theoretical 3D bound inside [-1, 1]
    return _lerp(_lerp(x00, x10, v), _lerp(x01, x11, v), w) * Real(0.97)


def perlin2(x: Real, y: Real, seed: Int = 0) -> Real:
    """2D gradient noise, ~[-1, 1] — the usual terrain/heightmap primitive."""
    var ix = Int(floor(x))
    var iy = Int(floor(y))
    var fx = x - Real(ix)
    var fy = y - Real(iy)
    var u = _fade(fx)
    var v = _fade(fy)

    var n00 = _grad2(_hash(ix, iy, 0, seed), fx, fy)
    var n10 = _grad2(_hash(ix + 1, iy, 0, seed), fx - 1, fy)
    var n01 = _grad2(_hash(ix, iy + 1, 0, seed), fx, fy - 1)
    var n11 = _grad2(_hash(ix + 1, iy + 1, 0, seed), fx - 1, fy - 1)
    return _lerp(_lerp(n00, n10, u), _lerp(n01, n11, u), v)


# --- Worley / cellular ----------------------------------------------------

def worley3(x: Real, y: Real, z: Real, seed: Int = 0) -> Real:
    """F1 cellular noise: distance to the nearest feature point (one per
    lattice cell, at a hashed offset). Range ~[0, 1.7]; small = near a point."""
    var ix = Int(floor(x))
    var iy = Int(floor(y))
    var iz = Int(floor(z))
    var best = Real(1e30)
    for dx in range(-1, 2):
        for dy in range(-1, 2):
            for dz in range(-1, 2):
                var cx = ix + dx
                var cy = iy + dy
                var cz = iz + dz
                var fx = _uni01(_hash(cx, cy, cz, seed))
                var fy = _uni01(_hash(cx, cy, cz, seed + 101))
                var fz = _uni01(_hash(cx, cy, cz, seed + 202))
                var px = Real(cx) + fx
                var py = Real(cy) + fy
                var pz = Real(cz) + fz
                var ddx = px - x
                var ddy = py - y
                var ddz = pz - z
                var d2 = ddx * ddx + ddy * ddy + ddz * ddz
                if d2 < best:
                    best = d2
    return sqrt(best)


# --- fractal Brownian motion ----------------------------------------------

def fbm3(
    x: Real, y: Real, z: Real, seed: Int = 0, octaves: Int = 5,
    lacunarity: Real = 2, gain: Real = 0.5,
) -> Real:
    """Sum of Perlin octaves, normalised back into the base's [-1, 1]."""
    var total = Real(0)
    var amp = Real(1)
    var freq = Real(1)
    var norm = Real(0)
    for o in range(octaves):
        total += amp * perlin3(x * freq, y * freq, z * freq, seed + o)
        norm += amp
        amp *= gain
        freq *= lacunarity
    return total / norm if norm > 0 else 0


def fbm2(
    x: Real, y: Real, seed: Int = 0, octaves: Int = 5,
    lacunarity: Real = 2, gain: Real = 0.5,
) -> Real:
    """2D fBm — layered terrain height in [-1, 1]."""
    var total = Real(0)
    var amp = Real(1)
    var freq = Real(1)
    var norm = Real(0)
    for o in range(octaves):
        total += amp * perlin2(x * freq, y * freq, seed + o)
        norm += amp
        amp *= gain
        freq *= lacunarity
    return total / norm if norm > 0 else 0
