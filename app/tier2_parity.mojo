"""Native / wasm64 parity probe for the CPU side of rendering tier 2 (#140): the stitched vertices of every terrain chunk
at levels picked by distance and at forced mixed levels, the clipped triangles of decals on that terrain and on a few
loose triangles, and the trail records packed from a fixed run, as three hashes (FNV-1a over the bit patterns). The
heights are a polynomial of the corner indices, so only this repository's code is compared. `main` prints for native,
`tier2_parity_run` is exported for wasm64 (scripts/tier2_same.py)."""
from game.terrain import TerrainField
from game.decals import Decal, DecalMesh
from game.trails import TrailSystem, TrailStyle, TRAIL_BLEND_ALPHA, TRAIL_BLEND_ADD
from game.particles import float_hash


def _fnv(h: UInt64, bits: UInt64) -> UInt64:
    return (h ^ bits) * UInt64(0x100000001B3)


def field() raises -> TerrainField:
    var n = 129
    var h = List[Float32](capacity=n * n)
    for iz in range(n):
        for ix in range(n):
            var x = Float32(ix) / 128.0
            var z = Float32(iz) / 128.0
            h.append(Float32(6.0) * x * (1.0 - x) * z + Float32(2.0) * (z - x) * (z - x) - Float32(1.5) * x * z * z)
    return TerrainField(h^, n, n, 0.5, -10.0, 4.0, 16, 6.0)


def run() raises -> Tuple[UInt64, UInt64, UInt64]:
    var f = field()
    var h = UInt64(0xCBF29CE484222325)
    var by_distance = f.levels(-2.0, 9.0, 12.0)
    var mixed = List[Int]()
    for i in range(f.ccx * f.ccz):
        mixed.append((i * 7 + i // 8) % 5)
    for levels in [by_distance.copy(), mixed^]:
        for cz in range(f.ccz):
            for cx in range(f.ccx):
                var r = f.record(levels, cx, cz)
                for vi in range(f.vertices_at(r.level)):
                    var v = f.chunk_vertex(r, vi)
                    h = _fnv(h, UInt64(v[0]))
                    h = _fnv(h, UInt64(v[1]))
                    h = _fnv(h, UInt64(v[2].to_bits()))
    var dv = List[Float32]()
    for k in range(6):
        var d = DecalMesh(Decal(
            -6.0 + Float64(k) * 4.3, 6.0, 9.0 + Float64(k) * 3.1, 0.1 * Float64(k), -1.0, 0.2, 0.0, 0.0, 1.0,
            1.0 + 0.3 * Float64(k), 0.8, 4.0, [0.2, 0.1, 0.05, 0.9],
        ))
        _ = d.project_terrain(f)
        d.project_triangle(-8.0, 1.0, 10.0, -2.0, 3.0, 14.0, 3.0, 0.5, 8.0)
        for i in range(len(d.verts)):
            dv.append(d.verts[i])
    var ts = TrailSystem()
    var a = ts.add(TrailStyle(1.5, 0.07, 64, [0.6, 0.2, 0.0], [1.0, 0.7, 0.2, 1.0], [1.0, 0.4, 0.1, 0.7], [0.8, 0.2, 0.1, 0.0], TRAIL_BLEND_ALPHA))
    var b = ts.add(TrailStyle(4.0, 0.2, 40, [0.5], [0.1, 0.5, 0.9, 0.9], [0.1, 0.4, 0.8, 0.6], [0.1, 0.3, 0.6, 0.2], TRAIL_BLEND_ADD, True))
    var c = ts.add(TrailStyle(0.9, 0.03, 128, [0.3, 0.1], [0.9, 0.9, 0.9, 0.8], [0.6, 0.6, 0.9, 0.5], [0.2, 0.2, 0.9, 0.0], TRAIL_BLEND_ALPHA))
    var rec = List[Float32]()
    for i in range(240):
        var t = Float64(i) / 60.0
        var u = t - 2.0
        ts.trails[a].move_to(t, 3.0 * u, 2.0 - u * u, 1.0 + 0.3 * t)
        ts.trails[b].move_to(t, -5.0 + 2.5 * t, 0.1, 0.4 * t * t)
        ts.trails[c].move_to(t, 1.0 / (1.0 + t), t * 0.7, -t)
        ts.expire(t)
        if i % 30 == 29:
            _ = ts.pack(t, 0.5 * t, 3.0, 8.0 - t, 0.0, -0.3, -0.95, rec, 100000)
    return (h, float_hash(dv), float_hash(rec))


@export
def tier2_parity_run(out_ptr: UInt64) abi("C") -> Int32:
    """Writes [terrain vertex hash, decal hash, trail hash] to out_ptr (3 x u64). 0 = ok."""
    try:
        var r = run()
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = r[0]
        out[1] = r[1]
        out[2] = r[2]
        return 0
    except e:
        print("tier2_parity_run:", e)
        return -1


def main() raises:
    var r = run()
    print("terrain", r[0], "decals", r[1], "trails", r[2])
