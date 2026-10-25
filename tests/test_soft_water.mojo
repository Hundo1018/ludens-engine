# tier: integration
"""Soft bodies and cloth in still water (ROADMAP 17.59, `physics.soft_water`).

  1. Ordinary: a single particle standing for a 5 cm cell settles where
     its submerged fraction equals the density ratio: at density 500 its
     centre at the surface, at 250 a quarter cell above it, within 5 mm
     (measured -3.4 / +2.2 mm: buoyancy and drag act once per frame,
     gravity over the soft body's four substeps).
     A 0.2 m soft cube (6^3) of density 500 floats across the surface; it
     turns corner-up (vertical extent about 0.2 sqrt 3 = 0.346), as real
     cubes of that density float tilted. (A soft slab was tried for an
     upright draft check: with the soft body's 4 x 4 XPBD iterations a
     0.4 m slab folds -- height 0.30 for faces 0.15 apart -- so it is not
     the test.)
  2. Integration: a horizontal 0.5 m cloth sheet of 1 kg/m^2 (no thickness)
     sinks flat at the terminal velocity of quadratic pressure drag,
     sqrt(2 sigma g / (rho cd)) = 0.128 m/s with cd 1.2, within 5 %; with
     a 0.5 mm thickness (buoyancy halves the net weight) at 0.090 m/s; a
     sheet lighter than the water it displaces (2 mm) rises.
  3. Extreme: bad arguments raise; particles outside a volume's footprint
     are not touched.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.fields import WaterVolume
from physics.softbody import SoftBody, SP, SEdge
from physics.cloth import MeshCloth, grid_mesh
from physics.soft_water import soft_water, cloth_water

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _pool() -> List[WaterVolume]:
    return [WaterVolume(Vec3(-5, -10, -5, 0), Vec3(5, 0, 5, 0), 1000, 2, 2)]


def _particle(density: Real) raises -> Real:
    """Height of a single particle (one 5 cm cell of `density`) after 5 s."""
    var sb = SoftBody()
    var vol = Real(0.05 * 0.05 * 0.05)
    sb.pts.append(SP(Vec3(0, 0.1, 0, 0), Vec3(0, 0, 0, 0), 1 / (density * vol)))
    var pool = _pool()
    for _ in range(300):
        soft_water(sb, pool, G, DT, vol)
        sb.advance(DT, G)
    return sb.pts[0].x[1]


def _cube(density: Real) raises -> Tuple[Real, Real, Real]:
    """(top, bottom, max speed) of a 0.2 m soft cube (6^3) after 5 s."""
    var half = Real(0.1)
    var vol = (2 * half) ** 3
    var sb = SoftBody.box_lattice(Vec3(0, 0.15, 0, 0), Vec3(half, half, half, 0), 6, density * vol, 0)
    var pool = _pool()
    for _ in range(300):
        soft_water(sb, pool, G, DT, vol)
        sb.advance(DT, G)
    return (sb.top_y(), sb.bottom_y(), sb.max_speed())


def _sheet(thickness: Real, secs: Real, bend: Real = 0) raises -> Tuple[Real, Real]:
    """(mean vertical velocity, flatness: max |y - mean y|)."""
    var mesh = grid_mesh(10, 10, 0.5, 0.5, Vec3(-0.25, -1.0, -0.25, 0))
    var c = MeshCloth(mesh[0].copy(), mesh[1].copy(), 1.0, 0, bend)
    var pool = _pool()
    for _ in range(Int(secs / DT)):
        cloth_water(c, pool, G, DT, 1.0, thickness)
        c.advance(DT, G)
    var vy = Real(0)
    var y = Real(0)
    for i in range(len(c.v)):
        vy += c.v[i][1]
        y += c.x[i][1]
    vy /= Real(len(c.v))
    y /= Real(len(c.v))
    var flat = Real(0)
    for i in range(len(c.x)):
        flat = max(flat, abs(c.x[i][1] - y))
    return (vy, flat)


def main() raises:
    var s = Suite("soft_water")
    var p500 = _particle(500)
    var p250 = _particle(250)
    print("  one particle (5 cm cell) after 5 s: height", p500, " at density 500 (Archimedes 0),", p250, " at 250 (0.0125)")
    s.check(abs(p500) < 5e-3 and abs(p250 - 0.0125) < 5e-3, "a particle floats where its submerged fraction is the density ratio (5 mm, a tenth of the cell)")
    var cube = _cube(500)
    print("  soft cube 0.2 m, density 500, after 5 s: top", cube[0], " bottom", cube[1], " extent", cube[0] - cube[1], " (corner-up 0.346) max speed", cube[2])
    s.check(cube[0] > 0 and cube[1] < 0 and cube[2] < 0.2, "a soft cube floats across the surface")

    var v_t = Real(sqrt(2 * 1.0 * 9.8 / (1000 * 1.2)))
    var a = _sheet(0, 2)
    var b = _sheet(0.0005, 2)
    var up = _sheet(0.002, 1)
    var soft = _sheet(0, 2, 1e-3)
    print("  horizontal sheet 1 kg/m^2 after 2 s: vy", a[0], " (terminal", -v_t, ")  flatness", a[1], ";  0.5 mm thick:", b[0], " (", -v_t * Real(sqrt(0.5)), ");  2 mm thick:", up[0])
    s.check(abs(a[0] / -v_t - 1) < 0.05 and abs(b[0] / (-v_t * Real(sqrt(0.5))) - 1) < 0.05, "a sinking sheet reaches the quadratic-drag terminal velocity (5 %)")
    s.check(up[0] > 0, "a sheet lighter than the water it displaces rises")

    var raised = 0
    var sb = SoftBody.box_lattice(Vec3(0, 0, 0, 0), Vec3(0.1, 0.1, 0.1, 0), 2, 1, 0)
    var pool = _pool()
    try:
        soft_water(sb, pool, G, DT, 0)
    except:
        raised += 1
    var mesh = grid_mesh(2, 2, 0.5, 0.5, Vec3(20, -1, 20, 0))
    var c = MeshCloth(mesh[0].copy(), mesh[1].copy(), 1.0)
    try:
        cloth_water(c, pool, G, DT, 0, 0)
    except:
        raised += 1
    s.check(raised == 2, "bad arguments raise")
    var v0 = c.v[0]
    cloth_water(c, pool, G, DT, 1.0, 0.001)
    s.check(c.v[0] == v0, "outside the footprint: untouched")
    s.finish()
