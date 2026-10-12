# tier: integration
"""Influence maps and fog of war (ROADMAP 17.15).

A 40 x 40 m area (1 m cells) split by a wall with a gap at the north end,
cells blocked from a baked navmesh. Ordinary: stamped influence falls off
linearly; propagation spreads each team's influence but not through the wall
(only around through the gap); the control layer (red - blue) changes sign
between the bases; the best cell for red is on red's side. Vision: a unit
sees its own room, not the cells behind the wall, sees through the gap;
explored cells stay explored after the unit leaves. Extreme: a unit off the
grid sees nothing, radius 0 sees its own cell, bad dimensions raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from ai.influence import InfluenceMap, TeamVision


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _quad(mut v: List[Vec3], mut t: List[Int], x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
    var n = len(v)
    v.append(_v(x0, y, z0))
    v.append(_v(x0, y, z1))
    v.append(_v(x1, y, z0))
    v.append(_v(x1, y, z1))
    for k in [0, 1, 2, 2, 1, 3]:
        t.append(n + k)


def _wall(mut v: List[Vec3], mut t: List[Int], x0: Real, z0: Real, x1: Real, z1: Real):
    var n = len(v)
    for c in range(8):
        v.append(_v(x1 if c & 1 else x0, Real(2.5) if c & 2 else Real(0), z1 if c & 4 else z0))
    var f = [2, 6, 3, 3, 6, 7, 0, 2, 4, 4, 2, 6, 1, 5, 3, 3, 5, 7, 0, 1, 2, 1, 3, 2, 4, 6, 5, 5, 6, 7]
    for k in range(len(f)):
        t.append(n + f[k])


def main() raises:
    var s = Suite("ai_influence")
    var v = List[Vec3]()
    var t = List[Int]()
    _quad(v, t, 0, 0, 40, 40, 0)
    _wall(v, t, 19.5, 0, 20.5, 34)  # wall x = 20, gap for z > 34
    var mesh = bake_navmesh(v, t, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))
    var im = InfluenceMap(_v(0, 0, 0), 40, 40, 1.0, 3)
    im.block_from_navmesh(mesh)
    s.check(im.blocked[im.cell_of(_v(20, 0, 10))], "wall cell blocked")
    s.check(not im.blocked[im.cell_of(_v(20, 0, 37))], "gap cell open")

    # stamp falloff
    im.stamp(0, _v(5, 0, 5), 10, 5)
    var near = im.at(0, _v(5.5, 0, 5.5))
    var mid = im.at(0, _v(7.5, 0, 5.5))
    var far = im.at(0, _v(12, 0, 5))
    s.check(near > mid and mid > 0 and far == 0, "stamp falls off linearly to zero at the radius")

    # propagation: red at (5, 10), blue at (35, 10)
    # sources are re-stamped every iteration (the game does it every frame)
    im.clear(0)
    for _ in range(90):
        im.stamp(0, _v(5, 0, 10), 1, 1.5)
        im.stamp(1, _v(35, 0, 10), 1, 1.5)
        im.propagate(0, 0.1, 0.9, 1)
        im.propagate(1, 0.1, 0.9, 1)
    var red_west = im.at(0, _v(18, 0, 10))
    var red_east = im.at(0, _v(22, 0, 10))
    var red_gap = im.at(0, _v(20, 0, 37))
    s.check(red_west > red_east * 3, "the wall blocks red's influence (west " + String(red_west) + " vs east " + String(red_east) + ")")
    s.check(red_gap > 0, "red's influence reaches the gap")
    s.check(red_east > 0, "and leaks east only around through the gap")
    im.combine(2, 0, 1, 1, -1)
    s.check(im.at(2, _v(5, 0, 10)) > 0 and im.at(2, _v(35, 0, 10)) < 0, "control layer changes sign between the bases")
    var best = im.best_cell(2)
    s.check(im.center(best)[0] < 20, "red's best control cell is on red's side")

    # vision / fog of war
    var vis = TeamVision(im, 2)
    var units = List[Vec3]()
    units.append(_v(10, 0, 10))
    vis.update(im, 0, units, 15)
    s.check(vis.is_visible(0, im.cell_of(_v(15, 0, 12))), "unit sees its own room")
    s.check(vis.is_visible(0, im.cell_of(_v(19.5, 0, 10))), "unit sees the wall face (first blocked cell)")
    s.check(not vis.is_visible(0, im.cell_of(_v(23, 0, 10))), "not the cells behind the wall")
    var units2 = List[Vec3]()
    units2.append(_v(20, 0, 37))
    vis.update(im, 0, units2, 8)
    s.check(vis.is_visible(0, im.cell_of(_v(24, 0, 37))), "from the gap the east side is visible")
    s.check(not vis.is_visible(0, im.cell_of(_v(15, 0, 12))), "the old room is no longer visible")
    s.check(vis.is_explored(0, im.cell_of(_v(15, 0, 12))), "but stays explored")
    s.check(vis.visible_count(1) == 0, "team 1 has seen nothing")
    var off = List[Vec3]()
    off.append(_v(-5, 0, -5))
    vis.update(im, 1, off, 10)
    s.eqi(vis.visible_count(1), 0, "unit off the grid sees nothing")
    var zero = List[Vec3]()
    zero.append(_v(10.5, 0, 10.5))
    vis.update(im, 1, zero, 0)
    s.eqi(vis.visible_count(1), 1, "radius 0: only its own cell")
    var raised = False
    try:
        _ = InfluenceMap(_v(0, 0, 0), 0, 10, 1, 1)
    except:
        raised = True
    s.check(raised, "zero-size map raises")
    s.finish()
