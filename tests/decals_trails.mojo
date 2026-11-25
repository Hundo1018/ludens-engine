# tier: unit
# Decals and trails on the CPU (#140): `pixi run -e wasm test-decals-trails`. Every expected value is worked out from
# the inputs (area of the box's footprint, cosine of a slope, a curve sample, a point count), not recorded.
# The GPU passes are tests/tier2_native.mojo; native against wasm64 is app/tier2_parity.mojo.
from std.math import sqrt
from harness.runner import Suite
from game.decals import Decal, DecalMesh, DecalSet, DECAL_VERTEX_FLOATS, DECAL_LIFT
from game.terrain import TerrainField
from game.trails import TrailStyle, Trail, TrailSystem, TRAIL_SEGMENT_FLOATS, TRAIL_BLEND_ALPHA, TRAIL_BLEND_ADD
from game.particles import float_hash
from app.mesh_pass import unit_cube_arrays


def down(x: Float64, y: Float64, z: Float64, hu: Float64, hv: Float64) raises -> Decal:
    return Decal(x, y, z, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, hu, hv, 0.5, [0.2, 0.1, 0.05, 0.9])


def area(m: DecalMesh) -> Float64:
    """Area of the decal's triangles projected on the decal's own plane (u, v)."""
    var a = 0.0
    var f = DECAL_VERTEX_FLOATS
    for t in range(m.triangles()):
        var o = t * 3 * f
        var ux = Float64(m.verts[o + 4]) * 2.0 * m.decal.hu
        var uy = Float64(m.verts[o + 5]) * 2.0 * m.decal.hv
        var vx = Float64(m.verts[o + f + 4]) * 2.0 * m.decal.hu
        var vy = Float64(m.verts[o + f + 5]) * 2.0 * m.decal.hv
        var wx = Float64(m.verts[o + 2 * f + 4]) * 2.0 * m.decal.hu
        var wy = Float64(m.verts[o + 2 * f + 5]) * 2.0 * m.decal.hv
        a += abs((vx - ux) * (wy - uy) - (wx - ux) * (vy - uy)) * 0.5
    return a


def style(lifetime: Float64, min_step: Float64, max_points: Int, blend: Int) raises -> TrailStyle:
    return TrailStyle(lifetime, min_step, max_points, [0.4, 0.0], [1.0, 0.5, 0.0, 1.0], [0.6, 0.3, 0.2, 0.5], [0.2, 0.1, 0.4, 0.0], blend)


def main() raises:
    var s = Suite("decals_trails")

    # --- decals on two triangles of flat ground (10 x 10 m at y = 0)
    var m = DecalMesh(down(1.0, 0.2, -1.0, 0.75, 0.5))
    m.project_triangle(-5.0, 0.0, -5.0, -5.0, 0.0, 5.0, 5.0, 0.0, 5.0)
    m.project_triangle(-5.0, 0.0, -5.0, 5.0, 0.0, 5.0, 5.0, 0.0, -5.0)
    print("flat ground: triangles", m.triangles(), "; area", area(m), "m2 (the box's footprint is 1.5 x 1.0)")
    s.almost(area(m), 1.5, "the clipped area is the box's footprint, 2 hu x 2 hv", tol=1e-6)
    var lo_u = Float32(1.0)
    var hi_u = Float32(0.0)
    var y_ok = True
    var fade_ok = True
    for v in range(len(m.verts) // DECAL_VERTEX_FLOATS):
        var o = v * DECAL_VERTEX_FLOATS
        lo_u = min(lo_u, m.verts[o + 4])
        hi_u = max(hi_u, m.verts[o + 4])
        if abs(Float64(m.verts[o + 1]) - DECAL_LIFT) > 1e-6:
            y_ok = False
        if abs(Float64(m.verts[o + 3]) - 1.0) > 1e-6:
            fade_ok = False
    print("u from", lo_u, "to", hi_u)
    s.check(abs(lo_u) < 1e-6 and abs(hi_u - 1.0) < 1e-6, "u spans 0 .. 1 over the box")
    s.check(y_ok, "vertices are lifted DECAL_LIFT along the normal")
    s.check(fade_ok, "head-on: fade 1")

    # a 45 degree slope: fade cos 45, area of the footprint on the slope seen along w is still 2 hu x 2 hv
    var sl = DecalMesh(down(0.0, 0.0, 0.0, 0.5, 0.5))
    sl.project_triangle(-5.0, -5.0, -5.0, -5.0, -5.0, 5.0, 5.0, 5.0, 5.0)
    sl.project_triangle(-5.0, -5.0, -5.0, 5.0, 5.0, 5.0, 5.0, 5.0, -5.0)
    var fade = Float64(sl.verts[3])
    print("45 degree slope: fade", fade, "; area in the decal's plane", area(sl))
    s.almost(fade, sqrt(0.5), "45 degrees: fade = cos 45", tol=1e-6)
    s.almost(area(sl), 1.0, "area in the decal's plane is 2 hu x 2 hv", tol=1e-6)

    # a wall edge-on to the projector and a triangle outside the box catch nothing
    var wall = DecalMesh(down(0.0, 0.0, 0.0, 0.5, 0.5))
    wall.project_triangle(0.0, -1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0)
    wall.project_triangle(3.0, 0.0, 3.0, 4.0, 0.0, 3.0, 3.0, 0.0, 4.0)
    s.eqi(wall.triangles(), 0, "an edge-on wall and a triangle outside the box: nothing")

    # terrain: a flat 33 x 33 grid at y = 2, cell 0.5
    var tf = TerrainField(List[Float32](length=33 * 33, fill=2.0), 33, 33, 0.5, 0.0, 0.0, 16)
    var tm = DecalMesh(down(8.1, 2.3, 7.9, 1.0, 0.6))
    var cells = tm.project_terrain(tf)
    print("terrain: cells visited", cells, "; triangles", tm.triangles(), "; area", area(tm))
    s.almost(area(tm), 2.4, "on flat terrain the area is 2 hu x 2 hv", tol=1e-6)
    s.check(cells < 100, "only the cells under the box are visited")

    # a mesh: the unit cube scaled (2, 1, 2) at (0, 0.5, 0), top face at y = 1; decal of 0.6 x 0.6 on it
    var cube = unit_cube_arrays()
    var cm = DecalMesh(down(0.2, 1.1, 0.1, 0.3, 0.3))
    var tested = cm.project_mesh(cube[0], cube[3], 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 1.0, 2.0)
    print("cube top: triangles tested", tested, "of", len(cube[3]) // 3, "; decal triangles", cm.triangles(), "; area", area(cm))
    s.almost(area(cm), 0.36, "on the cube's top face the area is 2 hu x 2 hv", tol=1e-6)
    s.check(tested < len(cube[3]) // 3, "triangles whose bounds miss the box are not clipped")
    # rotated 90 degrees about y the square top is the same: same area
    var cr = DecalMesh(down(0.2, 1.1, 0.1, 0.3, 0.3))
    _ = cr.project_mesh(cube[0], cube[3], 0.0, 0.5, 0.0, 0.0, sqrt(0.5), 0.0, sqrt(0.5), 2.0, 1.0, 2.0)
    s.almost(area(cr), 0.36, "rotated mesh: same area", tol=1e-6)

    # the set: capacity, budget, distance
    var ds = DecalSet(3, 4, 50.0)
    for i in range(5):
        var d = DecalMesh(down(Float64(i), 0.2, 0.0, 0.2, 0.2))
        d.project_triangle(-50.0, 0.0, -50.0, -50.0, 0.0, 50.0, 50.0, 0.0, 50.0)
        d.project_triangle(-50.0, 0.0, -50.0, 50.0, 0.0, 50.0, 50.0, 0.0, -50.0)
        _ = ds.add(d^)
    s.eqi(len(ds.meshes), 3, "at most max_decals kept")
    s.eqi(ds.replaced, 2, "5 added into 3: 2 replaced")
    s.check(ds.meshes[0].decal.c[0] == 2.0, "the oldest were replaced (decals 2, 3, 4 kept)")
    var out = List[Float32]()
    var tris = ds.pack(0.0, 1.0, 0.0, out)
    var per = ds.meshes[0].triangles()
    print("set: triangles per decal", per, "; drawn", tris, "; over budget", ds.over_budget)
    s.check(tris <= 4, "the frame's triangles stay within max_triangles")
    s.eqi(ds.over_budget, 3 - 4 // per, "decals past the budget are counted")
    s.eqi(len(out), tris * 3 * DECAL_VERTEX_FLOATS, "the packed vertices are the drawn triangles")
    _ = ds.pack(1000.0, 1.0, 0.0, out)
    s.eqi(ds.far, 3, "from 1000 m away every decal is past max_distance")
    var empty = DecalMesh(down(100.0, 0.0, 0.0, 0.2, 0.2))
    s.eqi(ds.add(empty^), -1, "a decal that caught nothing is not kept")

    # --- trails
    var tr = Trail(style(1.0, 0.5, 64, TRAIL_BLEND_ALPHA))
    for i in range(5):  # 0, 0.25, 0.5, 0.75, 1.0 m at t = 0, 0.1, ...
        tr.move_to(Float64(i) * 0.1, Float64(i) * 0.25, 0.0, 0.0)
    s.eqi(tr.points(), 3, "min_step 0.5 over 1 m in steps of 0.25: points at 0, 0.5 and 1.0")
    s.almost(tr.px[1], 0.5, "second point at 0.5 m")
    s.almost(tr.birth[2], 0.4, "third point born at t = 0.4")
    s.almost(tr.width_at(0, 0.5), 0.2, "width curve 0.4 -> 0 at age 0.5: 0.2")
    tr.expire(1.05)
    s.eqi(tr.points(), 2, "at t = 1.05 the point born at 0 (lifetime 1) is gone")
    var capped = Trail(style(10.0, 0.1, 4, TRAIL_BLEND_ALPHA))
    for i in range(10):
        capped.move_to(Float64(i), Float64(i), 0.0, 0.0)
    s.eqi(capped.points(), 4, "max_points 4")
    s.eqi(capped.dropped, 6, "10 points into 4: 6 dropped")
    s.almost(capped.px[0], 6.0, "the oldest went first")

    var ts = TrailSystem()
    var near = ts.add(style(2.0, 0.2, 64, TRAIL_BLEND_ALPHA))
    var far_t = ts.add(style(2.0, 0.2, 64, TRAIL_BLEND_ALPHA))
    var add = ts.add(style(2.0, 0.2, 64, TRAIL_BLEND_ADD))
    for i in range(4):
        var t = Float64(i) * 0.25
        ts.trails[near].move_to(t, Float64(i) * 0.5, 1.0, 2.0)
        ts.trails[far_t].move_to(t, Float64(i) * 0.5, 1.0, -6.0)
        ts.trails[add].move_to(t, Float64(i) * 0.5, 0.0, 0.0)
    s.eqi(ts.segments(), 9, "three trails of 4 points: 9 segments")
    var rec = List[Float32]()
    var counts = ts.pack(0.75, 0.0, 1.0, 5.0, 0.0, 0.0, -1.0, rec, 1000)
    s.eqi(counts[0], 6, "6 alpha segments")
    s.eqi(counts[1], 3, "3 additive segments")
    s.eqi(len(rec), 9 * TRAIL_SEGMENT_FLOATS, "24 floats per segment")
    s.check(rec[2] == -6.0 and rec[3 * TRAIL_SEGMENT_FLOATS + 2] == 2.0, "alpha segments far to near: the z = -6 trail first")
    # colour at age 0.25 of lifetime 2 (born 0.25 at time 0.75 -> age 0.5 s -> t 0.25): start + (mid - start) * 0.5
    var seg = ts.pack(0.75, 0.0, 1.0, 5.0, 0.0, 0.0, -1.0, rec, 1000)
    _ = seg
    var o = 0
    rec.clear()
    _ = ts.pack(0.75, 0.0, 1.0, 5.0, 0.0, 0.0, -1.0, rec, 1000)
    # the first record is the far trail's first segment: point 0 (born 0, age 0.75 s, t 0.375) then point 1 (born 0.25)
    var b = 12  # point B of the segment
    s.almost(Float64(rec[b + 3]), 0.4 + (0.0 - 0.4) * 0.25, "point B (age t 0.25): width on the curve", tol=1e-6)
    s.almost(Float64(rec[b + 4]), 1.0 + (0.6 - 1.0) * 0.5, "point B: red between start and mid", tol=1e-6)
    s.almost(Float64(rec[o + 8]), 1.0, "tangent of an end point: along +x", tol=1e-6)
    var h1 = float_hash(rec)
    var rec2 = List[Float32]()
    _ = ts.pack(0.75, 0.0, 1.0, 5.0, 0.0, 0.0, -1.0, rec2, 1000)
    s.check(float_hash(rec2) == h1, "the same state packs to the same bytes")
    var few = List[Float32]()
    var c2 = ts.pack(0.75, 0.0, 1.0, 5.0, 0.0, 0.0, -1.0, few, 4)
    s.eqi(c2[0] + c2[1], 4, "max_segments caps the records")
    s.finish()
