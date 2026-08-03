"""GPU-side LBVH front half: Morton codes and the sort, on the device.

An LBVH build is three steps — quantise centroids to Morton codes, SORT by
code, emit a hierarchy from the sorted order — and only the middle one is
expensive and parallel. That is the whole reason LBVH is the construction
people run on a GPU, so it is the step this offloads.

The sort is BITONIC, not radix, and that choice is forced rather than
preferred. An LSD radix sort must be STABLE: each pass relies on the previous
pass's relative order surviving. The natural GPU scatter — claim an output slot
with an atomic per bin — hands out slots in whatever order the warps arrive,
which is not stable, so a radix sort built that way silently produces a wrong
order. Making it stable needs per-block histograms plus a global scan, a real
piece of infrastructure. Bitonic sort needs none of it: it is a fixed schedule
of compare-exchanges, has no atomics, and is deterministic by construction, at
the cost of O(n log²n) work instead of O(n).

The hierarchy emit stays on the host. It is O(n) pointer work over an array
that is already in the right order, so moving it would trade a cheap serial
pass for another round trip.

`test_gpu_lbvh` asserts the device-sorted order matches the CPU sort exactly,
and that a tree built from it answers queries identically to the CPU LBVH.
"""

from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major
from geometry.vec import Real, Vec3, lane_min, lane_max
from geometry.aabb import AABB
from collision.broadphase import BoxProxy

comptime fdt = DType.float32
comptime udt = DType.uint32


def morton_kernel[LT: TensorLayout](
    cx: TileTensor[fdt, LT, MutAnyOrigin],
    cy: TileTensor[fdt, LT, MutAnyOrigin],
    cz: TileTensor[fdt, LT, MutAnyOrigin],
    codes: TileTensor[udt, LT, MutAnyOrigin],
    idx: TileTensor[udt, LT, MutAnyOrigin],
    n: Int,
    npad: Int,
    minx: Float32, miny: Float32, minz: Float32,
    invx: Float32, invy: Float32, invz: Float32,
):
    comptime assert cx.flat_rank == 1
    var g = global_idx.x
    if g >= npad:
        return
    var i = Int(g)
    if i >= n:
        # padding lanes sort to the end and are dropped on the host
        codes[i] = rebind[codes.ElementType](UInt32(0xFFFFFFFF))
        idx[i] = rebind[idx.ElementType](UInt32(i))
        return
    var tx = (rebind[Scalar[fdt]](cx[i]) - minx) * invx
    var ty = (rebind[Scalar[fdt]](cy[i]) - miny) * invy
    var tz = (rebind[Scalar[fdt]](cz[i]) - minz) * invz
    if tx < 0:
        tx = 0
    if tx > 1:
        tx = 1
    if ty < 0:
        ty = 0
    if ty > 1:
        ty = 1
    if tz < 0:
        tz = 0
    if tz > 1:
        tz = 1
    var qx = UInt32(Int(tx * 1023.0))
    var qy = UInt32(Int(ty * 1023.0))
    var qz = UInt32(Int(tz * 1023.0))
    var code = UInt32(0)
    for b in range(10):
        code |= ((qx >> UInt32(b)) & UInt32(1)) << UInt32(3 * b)
        code |= ((qy >> UInt32(b)) & UInt32(1)) << UInt32(3 * b + 1)
        code |= ((qz >> UInt32(b)) & UInt32(1)) << UInt32(3 * b + 2)
    codes[i] = rebind[codes.ElementType](code)
    idx[i] = rebind[idx.ElementType](UInt32(i))


def bitonic_kernel[LT: TensorLayout](
    codes: TileTensor[udt, LT, MutAnyOrigin],
    idx: TileTensor[udt, LT, MutAnyOrigin],
    npad: Int,
    k: Int,
    j: Int,
):
    """One compare-exchange stage of a bitonic sort. Fixed schedule, no atomics,
    every lane touches a disjoint pair — so the result does not depend on warp
    arrival order."""
    comptime assert codes.flat_rank == 1
    var g = global_idx.x
    if g >= npad:
        return
    var i = Int(g)
    var l = i ^ j
    if l <= i:
        return
    var ascending = (i & k) == 0
    var ci = rebind[Scalar[udt]](codes[i])
    var cl = rebind[Scalar[udt]](codes[l])
    var swap = (ci > cl) if ascending else (ci < cl)
    if swap:
        var ii = rebind[Scalar[udt]](idx[i])
        var il = rebind[Scalar[udt]](idx[l])
        codes[i] = rebind[codes.ElementType](cl)
        codes[l] = rebind[codes.ElementType](ci)
        idx[i] = rebind[idx.ElementType](il)
        idx[l] = rebind[idx.ElementType](ii)


def gpu_morton_order_ctx[N: Int, NPAD: Int](
    mut ctx: DeviceContext,
    items: List[BoxProxy[3]],
    mut out_order: List[Int],
) raises:
    """Morton codes + bitonic sort on the device; returns the permutation of
    `items` in Z-order. `NPAD` must be a power of two >= `N`."""
    comptime n = N
    comptime npad = NPAD
    comptime lay = row_major[npad]()

    # scene centroid bounds (host: O(n) and needed as kernel scalars anyway)
    var cmin = (items[0].box.min + items[0].box.max) * 0.5
    var cmax = cmin
    for i in range(1, n):
        var c = (items[i].box.min + items[i].box.max) * 0.5
        cmin = lane_min(cmin, c)
        cmax = lane_max(cmax, c)
    var ex = cmax[0] - cmin[0]
    var ey = cmax[1] - cmin[1]
    var ez = cmax[2] - cmin[2]
    var ivx = Float32(1.0 / ex) if ex > 1e-20 else Float32(0)
    var ivy = Float32(1.0 / ey) if ey > 1e-20 else Float32(0)
    var ivz = Float32(1.0 / ez) if ez > 1e-20 else Float32(0)

    var bcx = ctx.enqueue_create_buffer[fdt](npad)
    var bcy = ctx.enqueue_create_buffer[fdt](npad)
    var bcz = ctx.enqueue_create_buffer[fdt](npad)
    var bcode = ctx.enqueue_create_buffer[udt](npad)
    var bidx = ctx.enqueue_create_buffer[udt](npad)
    bcx.enqueue_fill(0)
    bcy.enqueue_fill(0)
    bcz.enqueue_fill(0)

    with bcx.map_to_host() as m:
        var t = TileTensor(m, lay)
        for i in range(n):
            t[i] = (items[i].box.min[0] + items[i].box.max[0]) * 0.5
    with bcy.map_to_host() as m:
        var t = TileTensor(m, lay)
        for i in range(n):
            t[i] = (items[i].box.min[1] + items[i].box.max[1]) * 0.5
    with bcz.map_to_host() as m:
        var t = TileTensor(m, lay)
        for i in range(n):
            t[i] = (items[i].box.min[2] + items[i].box.max[2]) * 0.5

    comptime BLOCK = 256
    var grid = (npad + BLOCK - 1) // BLOCK
    comptime mk = morton_kernel[type_of(lay)]
    ctx.enqueue_function[mk](
        TileTensor(bcx, lay), TileTensor(bcy, lay), TileTensor(bcz, lay),
        TileTensor(bcode, lay), TileTensor(bidx, lay),
        n, npad, cmin[0], cmin[1], cmin[2], ivx, ivy, ivz,
        grid_dim=grid, block_dim=BLOCK,
    )

    comptime bk = bitonic_kernel[type_of(lay)]
    var k = 2
    while k <= npad:
        var j = k // 2
        while j > 0:
            ctx.enqueue_function[bk](
                TileTensor(bcode, lay), TileTensor(bidx, lay), npad, k, j,
                grid_dim=grid, block_dim=BLOCK,
            )
            j //= 2
        k *= 2
    ctx.synchronize()

    with bidx.map_to_host() as m:
        var t = TileTensor(m, lay)
        for i in range(npad):
            var v = Int(rebind[Scalar[udt]](t[i]))
            if v < n:
                out_order.append(v)
