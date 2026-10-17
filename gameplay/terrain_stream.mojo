"""Procedural terrain in the streamed world (ROADMAP 17.69: tiles in
parallel, `WorldPartition` wiring).

  * `generate_tiles(txs, tzs, nx, nz, cell, params, dispatch)`: height
    tiles (`procedural.terrain_gen.height_tile`) for the listed tile
    coordinates, one dispatch item per tile. `terrain_height` is a pure
    function of (x, z, seed), so the result does not depend on the
    dispatch, the worker count or the order: parallel and serial runs are
    bit-identical (`test_terrain_stream`).
  * `TerrainStreamer` follows a `WorldPartition`: after each partition
    `update`, `sync` adds a heightfield collider for every newly loaded cell
    (the cell's tile, generated on demand -- cell size = nx x cell) and
    removes the collider of every cell that unloaded. Heights are world y
    minus the origin's y, placed at the cell's corner in local coordinates,
    so the streamed terrain is the same surface wherever the origin is.
"""

from geometry.vec import Real, Vec3
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from procedural.terrain_gen import TerrainParams, height_tile
from scheduler.dispatch import Task, Dispatch, dispatch_for
from .large_world import WorldPartition, WorldPos


struct _TileTask(Task):
    var out: Pointer[List[List[Real]], MutUntrackedOrigin]
    var txs: List[Int]
    var tzs: List[Int]
    var nx: Int
    var nz: Int
    var cell: Real
    var p: TerrainParams

    def __init__(out self, mut out: List[List[Real]], txs: List[Int], tzs: List[Int], nx: Int, nz: Int, cell: Real, p: TerrainParams):
        self.out = Pointer(to=out).unsafe_origin_cast[MutUntrackedOrigin]()
        self.txs = txs.copy()
        self.tzs = tzs.copy()
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.p = p

    def run(self, i: Int):
        try:
            self.out[][i] = height_tile(self.txs[i], self.tzs[i], self.nx, self.nz, self.cell, self.p)
        except:
            pass  # sizes were validated by generate_tiles


def generate_tiles(txs: List[Int], tzs: List[Int], nx: Int, nz: Int, cell: Real, p: TerrainParams, d: Dispatch, workers: Int = 0) raises -> List[List[Real]]:
    if len(txs) != len(tzs) or nx < 1 or nz < 1 or not (cell > 0):
        raise Error("generate_tiles: one tz per tx, nx, nz >= 1, cell > 0")
    var out = List[List[Real]](length=len(txs), fill=List[Real]())
    var task = _TileTask(out, txs, tzs, nx, nz, cell, p)
    dispatch_for(d, task, len(txs), workers)
    return out^


struct TerrainStreamer(Movable):
    var nx: Int
    var cell: Real
    var p: TerrainParams
    var keys: List[Int]  # partition cell keys with a collider
    var ids: List[BodyId]
    var made: Int  # tiles generated so far
    var removed: Int

    def __init__(out self, nx: Int, cell: Real, p: TerrainParams) raises:
        if nx < 1 or not (cell > 0):
            raise Error("TerrainStreamer: nx >= 1, cell > 0")
        self.nx = nx
        self.cell = cell
        self.p = p
        self.keys = List[Int]()
        self.ids = List[BodyId]()
        self.made = 0
        self.removed = 0

    def sync(mut self, mut scene: ContactScene6[QuatBody6], part: WorldPartition, origin: WorldPos) raises:
        if abs(part.cell_size - Float64(Real(self.nx) * self.cell)) > 1e-9:
            raise Error("TerrainStreamer.sync: partition cell size must be nx x cell")
        # unload
        var keep_k = List[Int]()
        var keep_i = List[BodyId]()
        for j in range(len(self.keys)):
            var still = False
            for k in part.loaded:
                if k == self.keys[j]:
                    still = True
            if still:
                keep_k.append(self.keys[j])
                keep_i.append(self.ids[j])
            else:
                scene.remove_body(self.ids[j])
                self.removed += 1
        self.keys = keep_k^
        self.ids = keep_i^
        # load
        for k in part.loaded:
            var have = False
            for m in self.keys:
                if m == k:
                    have = True
            if have:
                continue
            var ix = (k >> 31) - (1 << 30)
            var iz = (k & ((1 << 31) - 1)) - (1 << 30)
            var h = height_tile(ix, iz, self.nx, self.nx, self.cell, self.p)
            for q in range(len(h)):
                h[q] = Real(Float64(h[q]) - origin.y)
            var corner = WorldPos(Float64(ix) * part.cell_size, 0, Float64(iz) * part.cell_size)
            var local = corner.to_local(origin)
            # HeightField counts vertices: (nx + 1) per side
            var id = scene.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), h, self.nx + 1, self.nx + 1, self.cell, local[0], local[2])
            self.keys.append(k)
            self.ids.append(id)
            self.made += 1
