"""Two interchangeable world-matrix propagation strategies — the swap seam.

Both walk a `Hierarchy` (parents first) and write each entity's cached `world`
matrix; they differ only in *how much* they recompute, so a benchmark can show
the crossover:

  - `propagate_full`    — recompose and re-multiply every node, every call.
  - `propagate_dirty`   — recompute only nodes whose local TRS changed or whose
                          parent was recomputed this pass; clear the flags.

They are free functions generic over the storage backend, exactly like
`physics.integrator.integrate`. A parity test asserts they produce identical
world matrices, proving `propagate_dirty` is a correct optimization of
`propagate_full`. (A SoA/archetype-column variant is the natural third strategy
— left as future work.)
"""

from .world import World
from .storage import StorageBackend
from .transform import Transform
from .hierarchy import Hierarchy
from geometry.mat import Mat4


def propagate_full[B: StorageBackend](mut w: World[B], h: Hierarchy):
    var max_id = len(h.parent_of) - 1
    if max_id < 0:
        return
    var world_cache = List[Mat4]()
    for _ in range(max_id + 1):
        world_cache.append(Mat4.identity())

    for k in range(len(h.order)):
        var e = h.order[k]
        var t = w.get[Transform](e)
        var local = t.local_matrix()
        var par = h.parent_of[e.id]
        var wm = local
        if par >= 0 and par <= max_id:
            wm = world_cache[par] * local
        world_cache[e.id] = wm
        t.world = wm
        t.local_dirty = False
        t.world_dirty = False
        w.set(e, t)


def propagate_dirty[B: StorageBackend](mut w: World[B], h: Hierarchy):
    var max_id = len(h.parent_of) - 1
    if max_id < 0:
        return
    var world_cache = List[Mat4]()
    var rebuilt = List[Bool]()
    for _ in range(max_id + 1):
        world_cache.append(Mat4.identity())
        rebuilt.append(False)

    for k in range(len(h.order)):
        var e = h.order[k]
        var t = w.get[Transform](e)
        var par = h.parent_of[e.id]
        var parent_rebuilt = False
        if par >= 0 and par <= max_id:
            parent_rebuilt = rebuilt[par]
        if t.local_dirty or t.world_dirty or parent_rebuilt:
            var local = t.local_matrix()
            var wm = local
            if par >= 0 and par <= max_id:
                wm = world_cache[par] * local
            world_cache[e.id] = wm
            t.world = wm
            t.local_dirty = False
            t.world_dirty = False
            w.set(e, t)
            rebuilt[e.id] = True
        else:
            world_cache[e.id] = t.world
            rebuilt[e.id] = False
