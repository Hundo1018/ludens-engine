"""GPU broadphase: the all-pairs AABB test, run on the device.

Every other broadphase in this directory reduces the number of pair tests with
an acceleration structure. This one does the opposite: it keeps the O(n²)
enumeration and throws lanes at it. That is worth measuring because the two
strategies scale on different resources — a structure trades memory traffic and
build time for fewer tests, while the device trades nothing and simply performs
more tests per unit time — so which wins is an empirical question about N and
about how much the structure's build costs.

Layout is SoA (one buffer per AABB component) for the same reason the cloth
solver uses it: it avoids width-3 SIMD entirely and is the coalesced access
pattern on device. Thread `i` walks `j > i`, so each unordered pair is tested
exactly once, and hits are appended through a single atomic cursor. The cursor
makes the OUTPUT ORDER nondeterministic, which is why the parity test compares
pair SETS and why `solver6` — which needs a deterministic order — would have to
sort before use.

This does NOT implement the `BroadPhase` trait. The trait's `rebuild`/`pairs`
take no device context, and creating a `DeviceContext` per instance is exactly
the pattern that hangs on this nightly (root-caused 2026-07-13). Putting this
behind the seam properly needs the trait to carry a context, which is a change
to every implementation; until then it is a context-taking free function, and
`bench_gpu_broadphase` compares it against the CPU structures directly.
"""

from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from std.atomic import Atomic
from layout import TileTensor, TensorLayout, row_major
from geometry.aabb import AABB
from .broadphase import Pair, BoxProxy

comptime fdt = DType.float32
comptime idt = DType.int32


def pair_kernel[LT: TensorLayout, ILT: TensorLayout, CLT: TensorLayout](
    lox: TileTensor[fdt, LT, MutAnyOrigin],
    loy: TileTensor[fdt, LT, MutAnyOrigin],
    loz: TileTensor[fdt, LT, MutAnyOrigin],
    hix: TileTensor[fdt, LT, MutAnyOrigin],
    hiy: TileTensor[fdt, LT, MutAnyOrigin],
    hiz: TileTensor[fdt, LT, MutAnyOrigin],
    out_a: TileTensor[idt, ILT, MutAnyOrigin],
    out_b: TileTensor[idt, ILT, MutAnyOrigin],
    cursor: TileTensor[idt, CLT, MutAnyOrigin],
    n: Int,
    cap: Int,
):
    comptime assert lox.flat_rank == 1
    comptime assert out_a.flat_rank == 1
    var i = global_idx.x
    if i >= n:
        return
    var ax0 = rebind[Scalar[fdt]](lox[i])
    var ay0 = rebind[Scalar[fdt]](loy[i])
    var az0 = rebind[Scalar[fdt]](loz[i])
    var ax1 = rebind[Scalar[fdt]](hix[i])
    var ay1 = rebind[Scalar[fdt]](hiy[i])
    var az1 = rebind[Scalar[fdt]](hiz[i])
    for j in range(Int(i) + 1, n):
        if ax1 < rebind[Scalar[fdt]](lox[j]) or rebind[Scalar[fdt]](hix[j]) < ax0:
            continue
        if ay1 < rebind[Scalar[fdt]](loy[j]) or rebind[Scalar[fdt]](hiy[j]) < ay0:
            continue
        if az1 < rebind[Scalar[fdt]](loz[j]) or rebind[Scalar[fdt]](hiz[j]) < az0:
            continue
        # one atomic claim per hit; overflow is detected on the host by
        # comparing the cursor against the capacity
        var slot = Int(Atomic.fetch_add(cursor.ptr, Int32(1)))
        if slot < cap:
            out_a[slot] = rebind[out_a.ElementType](Int32(Int(i)))
            out_b[slot] = rebind[out_b.ElementType](Int32(j))


def gpu_pairs_ctx[N: Int, CAP: Int](
    mut ctx: DeviceContext, items: List[BoxProxy[3]], mut out: List[Pair],
) raises -> Bool:
    """Candidate pairs for `items` on the device. Returns False (and leaves
    `out` truncated) if more pairs were found than `cap` — the caller then
    knows the result is incomplete rather than silently wrong."""
    comptime n = N
    comptime cap = CAP
    if len(items) < 2:
        return True

    var lox = ctx.enqueue_create_buffer[fdt](n)
    var loy = ctx.enqueue_create_buffer[fdt](n)
    var loz = ctx.enqueue_create_buffer[fdt](n)
    var hix = ctx.enqueue_create_buffer[fdt](n)
    var hiy = ctx.enqueue_create_buffer[fdt](n)
    var hiz = ctx.enqueue_create_buffer[fdt](n)
    var oa = ctx.enqueue_create_buffer[idt](cap)
    var ob = ctx.enqueue_create_buffer[idt](cap)
    var cur = ctx.enqueue_create_buffer[idt](1)
    cur.enqueue_fill(0)

    comptime layout = row_major[n]()
    comptime ilay = row_major[cap]()
    comptime clay = row_major[1]()
    with lox.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.min[0]
    with loy.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.min[1]
    with loz.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.min[2]
    with hix.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.max[0]
    with hiy.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.max[1]
    with hiz.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = items[i].box.max[2]

    var tlox = TileTensor(lox, layout)
    var tloy = TileTensor(loy, layout)
    var tloz = TileTensor(loz, layout)
    var thix = TileTensor(hix, layout)
    var thiy = TileTensor(hiy, layout)
    var thiz = TileTensor(hiz, layout)
    var toa = TileTensor(oa, ilay)
    var tob = TileTensor(ob, ilay)
    var tcur = TileTensor(cur, clay)

    comptime BLOCK = 256
    comptime k = pair_kernel[type_of(layout), type_of(ilay), type_of(clay)]
    var grid = (n + BLOCK - 1) // BLOCK
    ctx.enqueue_function[k](
        tlox, tloy, tloz, thix, thiy, thiz, toa, tob, tcur, n, cap,
        grid_dim=grid, block_dim=BLOCK,
    )
    ctx.synchronize()

    var found = 0
    with cur.map_to_host() as m:
        var t = TileTensor(m, clay)
        found = Int(rebind[Scalar[idt]](t[0]))
    var take = found if found <= cap else cap
    var ia = List[Int]()
    var ib = List[Int]()
    with oa.map_to_host() as m:
        var t = TileTensor(m, ilay)
        for i in range(take):
            ia.append(Int(rebind[Scalar[idt]](t[i])))
    with ob.map_to_host() as m:
        var t = TileTensor(m, ilay)
        for i in range(take):
            ib.append(Int(rebind[Scalar[idt]](t[i])))
    for i in range(take):
        out.append(Pair(items[ia[i]].proxy, items[ib[i]].proxy))
    return found <= cap
