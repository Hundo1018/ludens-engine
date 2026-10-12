"""GPU narrowphase (ROADMAP 17.17): `NarrowBatch` pair records turned into
manifolds on the device, one thread per pair.

The kernel calls `narrow_pair` (`collision/narrow_batch.mojo`), the same
function `NarrowBatch.run_host` runs and the host path is bit-identical to
`ColliderSet.pair_manifold`. Buffers persist in `GpuNarrow` and grow by
doubling, so a steady pair count allocates nothing per frame.

Device-only code: compiled only under `has_accelerator()` by its callers
(see tests/test_gpu_narrow.mojo); `scripts/gpu_compile_check.sh` builds it
for an explicit architecture on hosts without one.
"""

from std.math import ceildiv
from max.gpu import global_idx
from max.gpu.host import DeviceContext, DeviceBuffer
from geometry.vec import Real, WorldType
from collision.narrow_batch import NarrowBatch, narrow_pair, FPtr, PAIR_STRIDE, OUT_STRIDE

comptime _BLOCK = 128


def narrow_kernel(inp: FPtr, res: FPtr, count: Int32):
    var k = Int(global_idx.x)
    if k < Int(count):
        narrow_pair(inp, res, k)


struct GpuNarrow(Movable):
    var cap: Int
    var inp: DeviceBuffer[WorldType]
    var res: DeviceBuffer[WorldType]

    def __init__(out self, mut ctx: DeviceContext, capacity: Int = 1024) raises:
        self.cap = max(capacity, 1)
        self.inp = ctx.enqueue_create_buffer[WorldType](self.cap * PAIR_STRIDE)
        self.res = ctx.enqueue_create_buffer[WorldType](self.cap * OUT_STRIDE)

    def run(mut self, mut ctx: DeviceContext, mut batch: NarrowBatch) raises:
        """Fill `batch.out` with every pair's manifold (synchronises)."""
        var n = batch.count
        if n > self.cap:
            while self.cap < n:
                self.cap *= 2
            self.inp = ctx.enqueue_create_buffer[WorldType](self.cap * PAIR_STRIDE)
            self.res = ctx.enqueue_create_buffer[WorldType](self.cap * OUT_STRIDE)
        with self.inp.map_to_host() as m:
            for i in range(n * PAIR_STRIDE):
                m[i] = batch.inp[i]
        if n > 0:
            ctx.enqueue_function[narrow_kernel](
                self.inp.unsafe_ptr(), self.res.unsafe_ptr(), Int32(n),
                grid_dim=ceildiv(n, _BLOCK), block_dim=_BLOCK,
            )
        ctx.synchronize()
        batch.out = List[Real](length=n * OUT_STRIDE, fill=0)
        with self.res.map_to_host() as m:
            for i in range(n * OUT_STRIDE):
                batch.out[i] = m[i]
