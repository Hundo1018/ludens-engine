# tier: component
"""Hydraulic erosion and slope-filtered scattering (ROADMAP 17.69,
`procedural.terrain_gen`).

  1. Conservation: 20000 droplets on a 64 x 64 fBm tile change the total
     height by < 1e-5 of the summed |height| (droplets drop their load
     when they stop or reach the edge).
  2. Erosion moves material downhill: on a plane falling toward x = 0
     (slope 0.3 per cell, with fBm bumps), the lower quarter gains height
     and the upper half loses it; the eroded tile is no longer the plane
     plus bumps (max change printed).
  3. Determinism: the same seed gives the same tile bit for bit.
  4. Slope filter: a tile flat for x < 32 cells and rising at 1 per cell
     after it; Poisson points kept with max slope 0.2 all lie on the flat
     part (x <= 32 cells + one cell of bilinear blending).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec2
from procedural.terrain_gen import TerrainParams, height_tile, hydraulic_erosion, filter_by_slope, slope_at
from procedural.scatter import poisson_disk


def sumh(h: List[Real]) -> Float64:
    var s = Float64(0)
    for v in h:
        s += Float64(v)
    return s


def main() raises:
    var s = Suite("erosion")
    var n = 64
    var p = TerrainParams(5, 20.0, 8.0, 4, False, 0.0)
    var h = height_tile(0, 0, n, n, 1.0, p)
    var abs_sum = Float64(0)
    for v in h:
        abs_sum += abs(Float64(v))
    var s0 = sumh(h)
    hydraulic_erosion(h, n, n, 20000, 9)
    var s1 = sumh(h)
    print("fBm tile: total height", s0, "->", s1, " relative to sum |h|", abs(s1 - s0) / abs_sum)
    s.check(abs(s1 - s0) / abs_sum < 1e-5, "total height conserved (1e-5)")

    # plane falling toward x = 0 with bumps
    var bumps = height_tile(0, 0, n, n, 1.0, TerrainParams(3, 5.0, 0.5, 2, False, 0.0))
    var plane = List[Real](length=(n + 1) * (n + 1), fill=0)
    for j in range(n + 1):
        for i in range(n + 1):
            plane[j * (n + 1) + i] = 0.3 * Real(i) + bumps[j * (n + 1) + i]
    var before = plane.copy()
    hydraulic_erosion(plane, n, n, 20000, 4)
    var low = Float64(0)
    var high = Float64(0)
    var worst = Real(0)
    for j in range(n + 1):
        for i in range(n + 1):
            var k = j * (n + 1) + i
            var d = plane[k] - before[k]
            worst = max(worst, abs(d))
            if i < 16:
                low += Float64(d)
            elif i >= 32:
                high += Float64(d)
    print("sloped tile: height change lower quarter", low, " upper half", high, " max |change|", worst)
    s.check(low > 0 and high < 0 and worst > 0.05, "material moves downhill: lower quarter gains, upper half loses")

    var again = height_tile(0, 0, n, n, 1.0, p)
    hydraulic_erosion(again, n, n, 20000, 9)
    var same = True
    for k in range(len(h)):
        same = same and h[k] == again[k]
    s.check(same, "same seed, same eroded tile")

    # slope filter
    var ramp = List[Real](length=(n + 1) * (n + 1), fill=0)
    for j in range(n + 1):
        for i in range(n + 1):
            ramp[j * (n + 1) + i] = Real(max(0, i - 32))
    var pts = poisson_disk(64.0, 64.0, 2.0, 1)
    var kept = filter_by_slope(pts, ramp, n, n, 1.0, 0.2)
    var maxx = Real(0)
    for q in kept:
        maxx = max(maxx, q[0])
    print("slope filter:", len(kept), "of", len(pts), "points kept, max x", maxx, "  slope at x 10 / 40:", slope_at(ramp, n, n, 1.0, 10, 10), slope_at(ramp, n, n, 1.0, 40, 10))
    s.check(len(kept) > 0 and len(kept) < len(pts) and maxx <= 33.0, "only the flat part keeps points")
    s.finish()
