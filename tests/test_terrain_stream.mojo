# tier: integration
"""Procedural terrain in the streamed world (ROADMAP 17.69,
`gameplay.terrain_stream`).

  1. Parallel tiles: 16 tiles of 32^2 generated through the parallel
     dispatch equal the serial ones bit for bit, and neighbouring tiles
     share their edge rows exactly.
  2. Streaming: a partition of 32 m cells (16 cells of 2 m), load radius
     40 m; an observer at the origin loads cells, `sync` adds one
     heightfield per loaded cell; a box dropped at (5, 30, 7) comes to rest
     on the terrain (bottom within 5 cm of `terrain_height` there); when the
     observer moves 1 km away every collider of the old cells is removed.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from procedural.terrain_gen import TerrainParams, terrain_height
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from scheduler.dispatch import Dispatch
from gameplay.large_world import WorldPartition, WorldPos
from gameplay.terrain_stream import generate_tiles, TerrainStreamer


def main() raises:
    var s = Suite("terrain_stream")
    var p = TerrainParams(7, 40.0, 6.0, 4, False, 0.0)
    var txs = List[Int]()
    var tzs = List[Int]()
    for j in range(4):
        for i in range(4):
            txs.append(i - 2)
            tzs.append(j - 2)
    var par = generate_tiles(txs, tzs, 32, 32, 1.0, p, Dispatch.parallel(), 4)
    var ser = generate_tiles(txs, tzs, 32, 32, 1.0, p, Dispatch.serial())
    var same = True
    for t in range(16):
        same = same and len(par[t]) == 33 * 33
        for k in range(len(ser[t])):
            same = same and par[t][k] == ser[t][k]
    # tile (0, 0) = index 10, its +x neighbour (1, 0) = index 11: column 32 == column 0
    var seam = True
    for j in range(33):
        seam = seam and par[10][j * 33 + 32] == par[11][j * 33]
    s.check(same, "parallel tiles equal serial bit for bit")
    s.check(seam, "neighbouring tiles share their edge exactly")

    var sc = ContactScene6[QuatBody6]()
    var part = WorldPartition(32.0, 40.0, 60.0)
    var st = TerrainStreamer(16, 2.0, p)
    var origin = WorldPos(0, 0, 0)
    var obs: List[WorldPos] = [WorldPos(0, 0, 0)]
    part.update(sc, origin, obs, 0)
    st.sync(sc, part, origin)
    print("loaded cells", len(part.loaded), " colliders", len(st.keys))
    s.check(len(part.loaded) > 0 and len(st.keys) == len(part.loaded), "one heightfield per loaded cell")
    var b = sc.add(QuatBody6.at_rest(Vec3(5, 30, 7, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var cfg = SolverConfig()
    for _ in range(240):
        sc.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), cfg)
    var pos = sc.pose(b).pos
    var ground = terrain_height(pos[0], pos[2], p)
    print("box rests at y", pos[1], " bottom", pos[1] - 0.25, " terrain there", ground)
    s.check(abs(pos[1] - 0.25 - ground) < 0.05, "a dropped box rests on the streamed terrain")
    var before = len(st.keys)
    obs[0] = WorldPos(1000, 0, 1000)
    part.update(sc, origin, obs, 1)
    st.sync(sc, part, origin)
    print("after moving 1 km: removed", st.removed, "of", before, " now", len(st.keys), "colliders,", len(part.loaded), "loaded")
    s.check(st.removed == before and len(st.keys) == len(part.loaded), "old colliders removed, new cells covered")
    s.finish()
