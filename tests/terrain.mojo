# tier: unit
# Terrain on the CPU (#140): `pixi run -e wasm test-terrain`. Checks against ludens-core's HeightField and against the
# geometry itself, not against recorded output:
#   - level 0: every chunk's triangles are HeightField.tri(t), corner for corner and in the same order
#   - LOD: the level grows by one each time the distance doubles past lod_distance
#   - no cracks: on every edge shared by chunks of different levels, the finer chunk's edge vertices lie on the coarser
#     chunk's edge segment, for every level pair in a 4 x 4 chunk field with forced levels 0 .. 4
#   - update_rows follows HeightField.deform
from harness.runner import Suite
from collision.trimesh import HeightField
from procedural.terrain_gen import TerrainParams, height_tile
from geometry.vec import Real
from game.terrain import TerrainField, ChunkRecord, log2_exact, SIDE_W, SIDE_E, SIDE_S, SIDE_N


def field_of(n: Int, chunk: Int) raises -> HeightField:
    """(n + 1)^2 corners of ludens-core's generated terrain, cell 1 m."""
    var p = TerrainParams.default(3)
    var h = height_tile(0, 0, n, n, Real(1.0), p)
    return HeightField(h, n + 1, n + 1, Real(1.0), Real(-4.0), Real(2.0))


def edge_points(t: TerrainField, r: ChunkRecord, side: Int) -> List[String]:
    """The distinct vertices of chunk r's mesh on edge `side`, as "ix iz height-bits" strings, sorted."""
    var n = t.chunk >> r.level
    var seen = List[String]()
    for vi in range(n * n * 6):
        var v = t.chunk_vertex(r, vi)
        var on: Bool
        if side == SIDE_W or side == SIDE_E:
            on = v[0] == (r.ix0 if side == SIDE_W else r.ix0 + t.chunk)
        else:
            on = v[1] == (r.iz0 if side == SIDE_S else r.iz0 + t.chunk)
        if not on:
            continue
        var key = String(v[0]) + " " + String(v[1]) + " " + String(v[2].to_bits())
        var dup = False
        for k in seen:
            if k == key:
                dup = True
        if not dup:
            seen.append(key)
    sort(seen)
    return seen^


def main() raises:
    var s = Suite("terrain")
    s.eqi(log2_exact(64), 6, "log2 64")
    s.eqi(log2_exact(48), -1, "48 is not a power of two")

    # level 0 is the collider's tessellation
    var hf = field_of(64, 16)
    var t = TerrainField.from_heightfield(hf, 16, 10.0)
    s.eqi(t.ccx * t.ccz, 16, "64 cells / 16 per chunk: 4 x 4 chunks")
    var lv0 = List[Int](length=16, fill=0)
    var mismatched = 0
    var compared = 0
    for cz in range(t.ccz):
        for cx in range(t.ccx):
            var r = t.record(lv0, cx, cz)
            for vi in range(t.vertices_at(0)):
                var c = vi // 6
                var ix = cx * 16 + c % 16
                var iz = cz * 16 + c // 16
                var tri = iz * (hf.nx - 1) * 2 + ix * 2 + (vi % 6) // 3
                var p = hf.tri(tri).points[vi % 3]
                var v = t.chunk_vertex(r, vi)
                var x = t.ox + Float32(v[0]) * t.cell
                var z = t.oz + Float32(v[1]) * t.cell
                compared += 1
                if x != Float32(p[0]) or v[2] != Float32(p[1]) or z != Float32(p[2]):
                    mismatched += 1
    print("level 0: vertices compared with HeightField.tri", compared, "; different", mismatched)
    s.eqi(compared, 64 * 64 * 6, "every vertex of level 0 compared")
    s.eqi(mismatched, 0, "level 0 draws HeightField.tri(t), vertex for vertex")

    # LOD by distance: lod_distance 10, chunk 16 m; eye above chunk (0, 0)'s box: level 0
    s.eqi(t.level_for(0, 0, -4.0 + 8.0, Float64(t.ymax[0]) + 1.0, 2.0 + 8.0), 0, "eye over the chunk: level 0")
    var far = List[Int]()
    for d in [5.0, 15.0, 25.0, 45.0, 85.0, 1000.0]:
        far.append(t.level_for(0, 0, -4.0 - d, Float64(t.ymin[0]), 10.0))
    print("levels at 5, 15, 25, 45, 85, 1000 m west of chunk (0, 0):", far[0], far[1], far[2], far[3], far[4], far[5])
    s.eqi(far[0], 0, "5 m: level 0")
    s.eqi(far[1], 1, "15 m (10 .. 20): level 1")
    s.eqi(far[2], 2, "25 m (20 .. 40): level 2")
    s.eqi(far[3], 3, "45 m (40 .. 80): level 3")
    s.eqi(far[4], 4, "85 m: level 4, the coarsest of a 16-cell chunk")
    s.eqi(far[5], 4, "1000 m: still level 4")

    # cracks: forced levels, every pair of neighbours: both chunks have exactly the same vertices on the shared edge
    var forced: List[Int] = [0, 1, 2, 3, 4, 0, 2, 4, 1, 3, 0, 4, 2, 2, 1, 0]
    var edges = 0
    var differing = 0
    var unequal_levels = 0
    for stitch in [True, False]:
        t.stitch = stitch
        var bad = 0
        for cz in range(t.ccz):
            for cx in range(t.ccx):
                var a = t.record(forced, cx, cz)
                for side in [SIDE_E, SIDE_N]:
                    if (side == SIDE_E and cx + 1 >= t.ccx) or (side == SIDE_N and cz + 1 >= t.ccz):
                        continue
                    var b = t.record(forced, cx + 1, cz) if side == SIDE_E else t.record(forced, cx, cz + 1)
                    var other = SIDE_W if side == SIDE_E else SIDE_S
                    if stitch:
                        edges += 1
                        if a.level != b.level:
                            unequal_levels += 1
                    var pa = edge_points(t, a, side)
                    var pb = edge_points(t, b, other)
                    var same = len(pa) == len(pb)
                    if same:
                        for i in range(len(pa)):
                            if pa[i] != pb[i]:
                                same = False
                    if not same:
                        bad += 1
        if stitch:
            differing = bad
        else:
            print("negative control, stitching off: shared edges whose vertices differ", bad)
            s.check(bad == unequal_levels, "without stitching every edge between unequal levels differs")
    t.stitch = True
    print("shared edges checked:", edges, "(", unequal_levels, "between different levels ); edges whose two sides differ", differing)
    s.eqi(edges, 24, "4 x 4 chunks share 24 edges")
    s.check(unequal_levels >= 16, "most of them join different levels")
    s.eqi(differing, 0, "on every shared edge both chunks have the same vertices, bit for bit")

    # stitching moves only the finer side, onto the coarse corners
    var r0 = t.record(forced, 0, 0)  # level 0, east neighbour level 1
    s.eqi(r0.ne, 1, "chunk (0,0)'s east neighbour is level 1")
    var odd = 0
    for vi in range(t.vertices_at(0)):
        var v = t.chunk_vertex(r0, vi)
        if v[0] == 16 and v[1] % 2 == 1:
            odd += 1
    s.eqi(odd, 0, "no vertex of chunk (0,0)'s east edge is at an odd row: all moved onto the level-1 corners")

    # deform: the collider changes, update_rows copies it
    _ = hf.deform(Real(10.0), Real(20.0), Real(4.0), Real(2.0))
    var span = t.update_rows(hf, 14, 26)
    var same = True
    for i in range(len(hf.h)):
        if Float32(hf.h[i]) != t.h[i]:
            same = False
    s.check(same, "after deform + update_rows the drawn heights are the collider's")
    s.eqi(span[0], 14 * 65, "changed corners start at row 14")
    s.eqi(span[1], 27 * 65, "and end after row 26")

    # splat by height and slope: weights are one-hot and every corner has one
    t.splat_by_height_slope(Float32(-2.0), Float32(4.0), Float32(1.5))
    var count = List[Int](length=4, fill=0)
    var bad = 0
    for i in range(t.nx * t.nz):
        var sum = 0
        for k in range(4):
            sum += Int(t.splat[4 * i + k])
            if t.splat[4 * i + k] == 255:
                count[k] += 1
        if sum != 255:
            bad += 1
    print("splat corners per layer:", count[0], count[1], count[2], count[3])
    s.eqi(bad, 0, "every corner's weights sum to 255")

    var raised = False
    try:
        _ = TerrainField(List[Float32](length=10 * 10, fill=0.0), 10, 10, 1.0, 0.0, 0.0, 4)
    except:
        raised = True
    s.check(raised, "a grid whose cells are not a multiple of the chunk is refused")
    s.finish()
