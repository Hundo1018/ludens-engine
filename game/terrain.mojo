"""Terrain on the CPU side (#140): the height grid the renderer draws, its chunks, their level of detail and the stitched
vertex of every chunk at every level. No GPU here; `app/terrain_pass.mojo` uploads the grid and draws the chunks, and its
vertex shader runs the same integer arithmetic as `chunk_vertex` below.

The grid is ludens-core's `collision.HeightField` layout: `h[iz * nx + ix]` is the height of corner (ix, iz) at world
(ox + ix * cell, oz + iz * cell). `TerrainField.from_heightfield` copies a collider's heights, so the drawn surface is
the collided one: at level 0 a chunk's triangles are `HeightField.tri(t)` corner for corner, with the same alternating
diagonal ((ix + iz) & 1 picks it), tested in tests/terrain.mojo.

Chunks: `chunk` cells a side (a power of two); (nx - 1) and (nz - 1) must be multiples of it. Chunk (cx, cz) covers
corners cx * chunk .. (cx + 1) * chunk. At level l a chunk is a grid of (chunk >> l) cells of 2^l corners each, so its
corners are a subset of the full grid and its heights are the field's own.

Level of detail: the distance d from the eye to the chunk's box (x, z and the chunk's height range) picks the level:
0 while d < lod_distance, then one more level each time d doubles, up to log2(chunk). No balancing between neighbours
is needed: on an edge shared with a coarser neighbour (level L > l) every vertex of the finer chunk whose index along
the edge is not a multiple of 2^L moves onto the coarse corner below it (index - index mod 2^L). The finer chunk's edge
then has exactly the coarser chunk's edge vertices, the triangles between them collapse to zero area, and no gap opens
for any difference of levels. (Placing the vertex on the coarse segment instead leaves a T-junction: measured on lavapipe,
1 uncovered pixel in 129 600, `tests/terrain_native.mojo`.)

Splat map: four 8-bit weights per corner (RGBA, `splat[4 * (iz * nx + ix) + k]`), the share of texture layer k. The
fragment shader reads them bilinearly at its own (x, z), so the texturing does not change with the level.
"""
from collision.trimesh import HeightField

comptime TERRAIN_CHUNK = 64  # default cells per chunk side: levels 0 .. 6
comptime SIDE_W = 0
comptime SIDE_E = 1
comptime SIDE_S = 2  # iz = iz0 (smaller z)
comptime SIDE_N = 3


def log2_exact(n: Int) -> Int:
    """log2 of a power of two, -1 otherwise."""
    if n < 1 or (n & (n - 1)) != 0:
        return -1
    var k = 0
    while (1 << k) < n:
        k += 1
    return k


@fieldwise_init
struct ChunkRecord(Copyable, ImplicitlyCopyable, Movable):
    """One chunk drawn at one level: its first corner, its level and its four neighbours' levels (W E S N; a missing
    neighbour has the chunk's own level). Packed for the GPU as four u32: ix0, iz0, level, W | E << 8 | S << 16 | N << 24."""

    var ix0: Int
    var iz0: Int
    var level: Int
    var nw: Int
    var ne: Int
    var ns: Int
    var nn: Int

    def neighbour(self, side: Int) -> Int:
        if side == SIDE_W:
            return self.nw
        if side == SIDE_E:
            return self.ne
        if side == SIDE_S:
            return self.ns
        return self.nn


struct TerrainField(Movable):
    var h: List[Float32]
    var nx: Int
    var nz: Int
    var cell: Float32
    var ox: Float32
    var oz: Float32
    var chunk: Int
    var ccx: Int  # chunks along x
    var ccz: Int
    var ymin: List[Float32]  # per chunk, row-major (cz * ccx + cx)
    var ymax: List[Float32]
    var splat: List[UInt8]  # 4 per corner; default all layer 0
    var lod_distance: Float64
    var stitch: Bool  # False only for the negative control of the tests

    def __init__(
        out self, var h: List[Float32], nx: Int, nz: Int, cell: Float32, ox: Float32 = 0.0, oz: Float32 = 0.0,
        chunk: Int = TERRAIN_CHUNK, lod_distance: Float64 = 40.0,
    ) raises:
        if len(h) != nx * nz:
            raise Error("TerrainField: len(h) must equal nx * nz")
        if cell <= 0.0:
            raise Error("TerrainField: cell must be > 0")
        if log2_exact(chunk) < 0:
            raise Error("TerrainField: chunk must be a power of two")
        if nx < 2 or nz < 2 or (nx - 1) % chunk != 0 or (nz - 1) % chunk != 0:
            raise Error("TerrainField: nx - 1 and nz - 1 must be positive multiples of the chunk (" + String(chunk) + ")")
        if lod_distance <= 0.0:
            raise Error("TerrainField: lod_distance must be > 0")
        self.h = h^
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.ox = ox
        self.oz = oz
        self.chunk = chunk
        self.ccx = (nx - 1) // chunk
        self.ccz = (nz - 1) // chunk
        self.ymin = List[Float32](length=self.ccx * self.ccz, fill=0.0)
        self.ymax = List[Float32](length=self.ccx * self.ccz, fill=0.0)
        self.splat = List[UInt8](length=nx * nz * 4, fill=0)
        for i in range(nx * nz):
            self.splat[4 * i] = 255
        self.lod_distance = lod_distance
        self.stitch = True
        for cz in range(self.ccz):
            for cx in range(self.ccx):
                self._bounds(cx, cz)

    @staticmethod
    def from_heightfield(hf: HeightField, chunk: Int = TERRAIN_CHUNK, lod_distance: Float64 = 40.0) raises -> Self:
        """The collider's heights, origin and cell, copied: what is drawn is what is hit."""
        var h = List[Float32](capacity=len(hf.h))
        for i in range(len(hf.h)):
            h.append(Float32(hf.h[i]))
        return Self(h^, hf.nx, hf.nz, Float32(hf.cell), Float32(hf.ox), Float32(hf.oz), chunk, lod_distance)

    def max_level(self) -> Int:
        return log2_exact(self.chunk)

    def height(self, ix: Int, iz: Int) -> Float32:
        return self.h[min(max(iz, 0), self.nz - 1) * self.nx + min(max(ix, 0), self.nx - 1)]

    def _bounds(mut self, cx: Int, cz: Int):
        var lo = Float32.MAX
        var hi = -Float32.MAX
        for iz in range(cz * self.chunk, (cz + 1) * self.chunk + 1):
            for ix in range(cx * self.chunk, (cx + 1) * self.chunk + 1):
                var y = self.h[iz * self.nx + ix]
                lo = min(lo, y)
                hi = max(hi, y)
        self.ymin[cz * self.ccx + cx] = lo
        self.ymax[cz * self.ccx + cx] = hi

    def update_rows(mut self, hf: HeightField, iz0: Int, iz1: Int) raises -> Tuple[Int, Int]:
        """Copy rows iz0 .. iz1 (inclusive) of a collider edited in place (`HeightField.deform`) and refresh the bounds
        of the chunks they touch. Returns the corner range [first, last + 1) that changed, for the GPU upload."""
        if hf.nx != self.nx or hf.nz != self.nz:
            raise Error("TerrainField.update_rows: the heightfield's size differs")
        var a = max(iz0, 0)
        var b = min(iz1, self.nz - 1)
        if a > b:
            return (0, 0)
        for i in range(a * self.nx, (b + 1) * self.nx):
            self.h[i] = Float32(hf.h[i])
        var cz0 = max((a - 1) // self.chunk, 0)
        var cz1 = min(b // self.chunk, self.ccz - 1)
        for cz in range(cz0, cz1 + 1):
            for cx in range(self.ccx):
                self._bounds(cx, cz)
        return (a * self.nx, (b + 1) * self.nx)

    def set_splat(mut self, ix: Int, iz: Int, w0: UInt8, w1: UInt8, w2: UInt8, w3: UInt8):
        if ix < 0 or iz < 0 or ix >= self.nx or iz >= self.nz:
            return
        var o = 4 * (iz * self.nx + ix)
        self.splat[o] = w0
        self.splat[o + 1] = w1
        self.splat[o + 2] = w2
        self.splat[o + 3] = w3

    def splat_by_height_slope(mut self, y1: Float32, y2: Float32, steep: Float32):
        """A starting splat map: layer 0 below y1, layer 1 between y1 and y2, layer 2 above y2, layer 3 where the slope
        (rise / run between the corner's neighbours) is above `steep`. Each corner is one layer at full weight; the
        shader's bilinear read blends them over a cell."""
        for iz in range(self.nz):
            for ix in range(self.nx):
                var y = self.h[iz * self.nx + ix]
                var gx = (self.height(ix + 1, iz) - self.height(ix - 1, iz)) / (2.0 * self.cell)
                var gz = (self.height(ix, iz + 1) - self.height(ix, iz - 1)) / (2.0 * self.cell)
                var k = 0
                if gx * gx + gz * gz > steep * steep:
                    k = 3
                elif y >= y2:
                    k = 2
                elif y >= y1:
                    k = 1
                var o = 4 * (iz * self.nx + ix)
                for j in range(4):
                    self.splat[o + j] = 255 if j == k else 0

    def level_for(self, cx: Int, cz: Int, ex: Float64, ey: Float64, ez: Float64) -> Int:
        """The level of chunk (cx, cz) seen from (ex, ey, ez): the distance to its box against lod_distance, doubling."""
        var x0 = Float64(self.ox) + Float64(cx * self.chunk) * Float64(self.cell)
        var z0 = Float64(self.oz) + Float64(cz * self.chunk) * Float64(self.cell)
        var x1 = x0 + Float64(self.chunk) * Float64(self.cell)
        var z1 = z0 + Float64(self.chunk) * Float64(self.cell)
        var y0 = Float64(self.ymin[cz * self.ccx + cx])
        var y1 = Float64(self.ymax[cz * self.ccx + cx])
        var dx = max(x0 - ex, 0.0, ex - x1)
        var dy = max(y0 - ey, 0.0, ey - y1)
        var dz = max(z0 - ez, 0.0, ez - z1)
        var d2 = dx * dx + dy * dy + dz * dz
        var level = 0
        var reach = self.lod_distance
        var top = self.max_level()
        while level < top and d2 >= reach * reach:
            level += 1
            reach *= 2.0
        return level

    def levels(self, ex: Float64, ey: Float64, ez: Float64) -> List[Int]:
        """The level of every chunk, row-major."""
        var out = List[Int](capacity=self.ccx * self.ccz)
        for cz in range(self.ccz):
            for cx in range(self.ccx):
                out.append(self.level_for(cx, cz, ex, ey, ez))
        return out^

    def record(self, levels: List[Int], cx: Int, cz: Int) -> ChunkRecord:
        var l = levels[cz * self.ccx + cx]
        var w = levels[cz * self.ccx + cx - 1] if cx > 0 else l
        var e = levels[cz * self.ccx + cx + 1] if cx + 1 < self.ccx else l
        var s = levels[(cz - 1) * self.ccx + cx] if cz > 0 else l
        var n = levels[(cz + 1) * self.ccx + cx] if cz + 1 < self.ccz else l
        return ChunkRecord(cx * self.chunk, cz * self.chunk, l, w, e, s, n)

    def vertices_at(self, level: Int) -> Int:
        """Vertices one chunk draws at `level`: 6 per cell, (chunk >> level)^2 cells."""
        var n = self.chunk >> level
        return n * n * 6

    def chunk_vertex(self, r: ChunkRecord, vi: Int) -> Tuple[Int, Int, Float32]:
        """Vertex `vi` of chunk record `r`: its grid corner (ix, iz) and its height after stitching. The WGSL in
        app/terrain_pass.mojo (`TERRAIN_WGSL`, vs_main) is this function line for line."""
        var s = 1 << r.level
        var n = self.chunk >> r.level
        var c = vi // 6
        var k = vi % 6
        var cx = c % n
        var cz = c // n
        var parity = ((r.ix0 // s + cx) + (r.iz0 // s + cz)) & 1
        # corner of the cell: 0 = (0,0), 1 = (1,0), 2 = (0,1), 3 = (1,1); the triangles of HeightField.tri
        var corner: Int
        if parity == 0:
            corner = [0, 2, 3, 0, 3, 1][k]
        else:
            corner = [0, 2, 1, 1, 2, 3][k]
        var ix = r.ix0 + (cx + (corner & 1)) * s
        var iz = r.iz0 + (cz + (corner >> 1)) * s
        # stitching: on an edge shared with a coarser neighbour (level L), a vertex between two of the neighbour's
        # corners moves onto the lower of them. The two chunks then share their edge vertices exactly (same corner,
        # same height, bit for bit), so the rasteriser's shared-edge rule leaves no pixel uncovered; a vertex merely
        # placed on the coarse segment would be a T-junction and can drop a pixel to rounding.
        if self.stitch:
            if ix == r.ix0 or ix == r.ix0 + self.chunk:
                var big = 1 << r.neighbour(SIDE_W if ix == r.ix0 else SIDE_E)
                if big > s:
                    iz -= iz % big
            if iz == r.iz0 or iz == r.iz0 + self.chunk:
                var big = 1 << r.neighbour(SIDE_S if iz == r.iz0 else SIDE_N)
                if big > s:
                    ix -= ix % big
        var y = self.height(ix, iz)
        return (ix, iz, y)

    def triangles(self, levels: List[Int]) -> Int:
        var n = 0
        for i in range(len(levels)):
            n += self.vertices_at(levels[i]) // 3
        return n
