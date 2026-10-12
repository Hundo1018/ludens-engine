"""GPU articulations (ROADMAP 17.17): `ArticBatch` instances stepped on the
device, one thread per instance.

The kernel calls `artic_step_instance` (`physics/artic_batch.mojo`), the same
function the host path runs, `steps` times per launch (step fusion: one
launch and no host round trip for a whole frame of substeps). Model, state
and workspace stay on the device between calls (`GpuArticBatch`), so a frame
costs one launch; `download` copies q / qd / qdd back only when the host
asks.

Device-only code: compiled only under `has_accelerator()` by its callers
(see tests/test_gpu_artic.mojo); `scripts/gpu_compile_check.sh` builds it
for an explicit architecture on hosts without one.
"""

from std.math import ceildiv
from max.gpu import global_idx
from max.gpu.host import DeviceContext, DeviceBuffer
from geometry.vec import Real, Vec3, WorldType
from physics.artic_batch import ArticBatch, artic_step_instance, FPtr, IPtr, WS

comptime _BLOCK = 64


def artic_step_kernel(
    model: FPtr, parent: IPtr, n: Int32, state: FPtr, qdd: FPtr, ws: FPtr,
    count: Int32, gx: Real, gy: Real, gz: Real, dt: Real, steps: Int32,
):
    var k = Int(global_idx.x)
    if k >= Int(count):
        return
    var nn = Int(n)
    var g = Vec3(gx, gy, gz, 0)
    for _ in range(Int(steps)):
        artic_step_instance(model, parent, nn, state + k * 3 * nn, qdd + k * nn, ws + k * nn * WS, g, dt)


struct GpuArticBatch(Movable):
    var n: Int
    var count: Int
    var model: DeviceBuffer[WorldType]
    var parent: DeviceBuffer[DType.int32]
    var state: DeviceBuffer[WorldType]
    var qdd: DeviceBuffer[WorldType]
    var ws: DeviceBuffer[WorldType]

    def __init__(out self, mut ctx: DeviceContext, batch: ArticBatch) raises:
        self.n = batch.n
        self.count = batch.count
        self.model = ctx.enqueue_create_buffer[WorldType](len(batch.model))
        self.parent = ctx.enqueue_create_buffer[DType.int32](len(batch.parent))
        self.state = ctx.enqueue_create_buffer[WorldType](len(batch.state))
        self.qdd = ctx.enqueue_create_buffer[WorldType](len(batch.qdd))
        self.ws = ctx.enqueue_create_buffer[WorldType](len(batch.ws))
        with self.model.map_to_host() as m:
            for i in range(len(batch.model)):
                m[i] = batch.model[i]
        with self.parent.map_to_host() as m:
            for i in range(len(batch.parent)):
                m[i] = batch.parent[i]
        self.upload_state(ctx, batch)

    def upload_state(mut self, mut ctx: DeviceContext, batch: ArticBatch) raises:
        """Copy q / qd / tau of every instance to the device (e.g. new torques)."""
        with self.state.map_to_host() as m:
            for i in range(len(batch.state)):
                m[i] = batch.state[i]

    def step(mut self, mut ctx: DeviceContext, steps: Int, dt: Real, gravity: Vec3) raises:
        """`steps` semi-implicit Euler steps of every instance in one launch."""
        ctx.enqueue_function[artic_step_kernel](
            self.model.unsafe_ptr(), self.parent.unsafe_ptr(), Int32(self.n),
            self.state.unsafe_ptr(), self.qdd.unsafe_ptr(), self.ws.unsafe_ptr(),
            Int32(self.count), gravity[0], gravity[1], gravity[2],
            dt, Int32(steps),
            grid_dim=ceildiv(self.count, _BLOCK), block_dim=_BLOCK,
        )

    def download(mut self, mut ctx: DeviceContext, mut batch: ArticBatch) raises:
        """Copy state and the last qdd back into `batch` (synchronises)."""
        ctx.synchronize()
        with self.state.map_to_host() as m:
            for i in range(len(batch.state)):
                batch.state[i] = m[i]
        with self.qdd.map_to_host() as m:
            for i in range(len(batch.qdd)):
                batch.qdd[i] = m[i]
