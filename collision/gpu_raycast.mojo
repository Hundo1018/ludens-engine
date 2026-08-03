"""Batched GPU raycasting: one thread per ray, all boxes tested.

The counterpart to `bp_gpu` on the query side, and the same trade. A CPU BVH
answers one ray by descending only the nodes it enters, so it does O(log n)
work per ray but has to build and traverse a tree. This kernel does the O(n)
slab test against every box and relies on having a ray per lane, which is
exactly the regime scene queries live in: a frame issues thousands of
independent rays and nothing about them needs a shared structure.

Each thread keeps its own nearest hit in registers and writes once, so there is
no atomic and no ordering question — unlike the broadphase, this result is
FULLY DETERMINISTIC and matches the CPU nearest hit exactly (`test_gpu_raycast`
compares proxy ids, not just distances, and asserts on the tie-breaking rule:
lowest index wins an exact distance tie, which is what the CPU BVH's descent
order produces).

Buffers are SoA and sized at comptime for the same reasons as `bp_gpu`; see its
header for why this is a context-taking free function rather than a
`SceneQuery` seam implementation.
"""

from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from geometry.ray import Ray
from collision.broadphase import BoxProxy

comptime fdt = DType.float32
comptime idt = DType.int32


def raycast_kernel[BLT: TensorLayout, RLT: TensorLayout](
    blox: TileTensor[fdt, BLT, MutAnyOrigin],
    bloy: TileTensor[fdt, BLT, MutAnyOrigin],
    bloz: TileTensor[fdt, BLT, MutAnyOrigin],
    bhix: TileTensor[fdt, BLT, MutAnyOrigin],
    bhiy: TileTensor[fdt, BLT, MutAnyOrigin],
    bhiz: TileTensor[fdt, BLT, MutAnyOrigin],
    rox: TileTensor[fdt, RLT, MutAnyOrigin],
    roy: TileTensor[fdt, RLT, MutAnyOrigin],
    roz: TileTensor[fdt, RLT, MutAnyOrigin],
    rdx: TileTensor[fdt, RLT, MutAnyOrigin],
    rdy: TileTensor[fdt, RLT, MutAnyOrigin],
    rdz: TileTensor[fdt, RLT, MutAnyOrigin],
    out_p: TileTensor[idt, RLT, MutAnyOrigin],
    out_t: TileTensor[fdt, RLT, MutAnyOrigin],
    nb: Int,
    nr: Int,
    max_t: Float32,
):
    comptime assert blox.flat_rank == 1
    comptime assert out_p.flat_rank == 1
    var r = global_idx.x
    if r >= nr:
        return
    var ri = Int(r)
    var ox = rebind[Scalar[fdt]](rox[r])
    var oy = rebind[Scalar[fdt]](roy[r])
    var oz = rebind[Scalar[fdt]](roz[r])
    var dx = rebind[Scalar[fdt]](rdx[r])
    var dy = rebind[Scalar[fdt]](rdy[r])
    var dz = rebind[Scalar[fdt]](rdz[r])
    # slab test wants 1/d; a zero component means "parallel", handled by the
    # infinity that 1/0 produces combining correctly with the min/max below
    var ix = Float32(1.0) / dx
    var iy = Float32(1.0) / dy
    var iz = Float32(1.0) / dz
    var best_t = max_t
    var best_p = Int32(-1)
    for b in range(nb):
        var t1 = (rebind[Scalar[fdt]](blox[b]) - ox) * ix
        var t2 = (rebind[Scalar[fdt]](bhix[b]) - ox) * ix
        var tmin = t1 if t1 < t2 else t2
        var tmax = t1 if t1 > t2 else t2
        t1 = (rebind[Scalar[fdt]](bloy[b]) - oy) * iy
        t2 = (rebind[Scalar[fdt]](bhiy[b]) - oy) * iy
        var lo = t1 if t1 < t2 else t2
        var hi = t1 if t1 > t2 else t2
        if lo > tmin:
            tmin = lo
        if hi < tmax:
            tmax = hi
        t1 = (rebind[Scalar[fdt]](bloz[b]) - oz) * iz
        t2 = (rebind[Scalar[fdt]](bhiz[b]) - oz) * iz
        lo = t1 if t1 < t2 else t2
        hi = t1 if t1 > t2 else t2
        if lo > tmin:
            tmin = lo
        if hi < tmax:
            tmax = hi
        if tmax < tmin or tmax < 0:
            continue
        var t = tmin if tmin >= 0 else Float32(0)
        # strict `<` keeps the LOWEST index on an exact tie, matching the CPU
        # BVH's descent order
        if t < best_t:
            best_t = t
            best_p = Int32(b)
    out_p[ri] = rebind[out_p.ElementType](best_p)
    out_t[ri] = rebind[out_t.ElementType](best_t)


def gpu_raycast_ctx[NB: Int, NR: Int](
    mut ctx: DeviceContext,
    items: List[BoxProxy[3]],
    rays: List[Ray[3]],
    mut out_proxy: List[Int],
    mut out_t: List[Real],
    max_t: Real,
) raises:
    """Nearest hit for every ray. `out_proxy[i]` is -1 when ray i misses."""
    comptime nb = NB
    comptime nr = NR
    comptime blay = row_major[nb]()
    comptime rlay = row_major[nr]()

    var lox = ctx.enqueue_create_buffer[fdt](nb)
    var loy = ctx.enqueue_create_buffer[fdt](nb)
    var loz = ctx.enqueue_create_buffer[fdt](nb)
    var hix = ctx.enqueue_create_buffer[fdt](nb)
    var hiy = ctx.enqueue_create_buffer[fdt](nb)
    var hiz = ctx.enqueue_create_buffer[fdt](nb)
    var ox = ctx.enqueue_create_buffer[fdt](nr)
    var oy = ctx.enqueue_create_buffer[fdt](nr)
    var oz = ctx.enqueue_create_buffer[fdt](nr)
    var dx = ctx.enqueue_create_buffer[fdt](nr)
    var dy = ctx.enqueue_create_buffer[fdt](nr)
    var dz = ctx.enqueue_create_buffer[fdt](nr)
    var op = ctx.enqueue_create_buffer[idt](nr)
    var ot = ctx.enqueue_create_buffer[fdt](nr)

    with lox.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.min[0]
    with loy.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.min[1]
    with loz.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.min[2]
    with hix.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.max[0]
    with hiy.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.max[1]
    with hiz.map_to_host() as m:
        var t = TileTensor(m, blay)
        for i in range(nb):
            t[i] = items[i].box.max[2]
    with ox.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].origin[0]
    with oy.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].origin[1]
    with oz.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].origin[2]
    with dx.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].dir[0]
    with dy.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].dir[1]
    with dz.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            t[i] = rays[i].dir[2]

    comptime BLOCK = 256
    comptime k = raycast_kernel[type_of(blay), type_of(rlay)]
    var grid = (nr + BLOCK - 1) // BLOCK
    ctx.enqueue_function[k](
        TileTensor(lox, blay), TileTensor(loy, blay), TileTensor(loz, blay),
        TileTensor(hix, blay), TileTensor(hiy, blay), TileTensor(hiz, blay),
        TileTensor(ox, rlay), TileTensor(oy, rlay), TileTensor(oz, rlay),
        TileTensor(dx, rlay), TileTensor(dy, rlay), TileTensor(dz, rlay),
        TileTensor(op, rlay), TileTensor(ot, rlay),
        nb, nr, Float32(max_t),
        grid_dim=grid, block_dim=BLOCK,
    )
    ctx.synchronize()

    with op.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            var pi = Int(rebind[Scalar[idt]](t[i]))
            out_proxy.append(items[pi].proxy if pi >= 0 else -1)
    with ot.map_to_host() as m:
        var t = TileTensor(m, rlay)
        for i in range(nr):
            out_t.append(Real(rebind[Scalar[fdt]](t[i])))
