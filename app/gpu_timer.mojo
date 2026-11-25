"""GPU time of the frame's passes, from timestamp queries (issue #123).

Native only. `GpuTimer.create` returns None when the device was not made with the timestamp-query feature and wgpu-native's
timestamps-inside-encoders feature (`gpu_timer_features`), and the frame then has no GPU rows: they are reported as "did not
run", never as 0. The web build has none either: wgpu-mojo's web host traps in `wgpuDeviceCreateQuerySet`
(build/deps/wgpu-mojo/web/webgpu_host.mjs), so a browser build asks for no timer. A browser could time a pass through the
`timestampWrites` of the render pass descriptor, which wgpu-mojo's pass helpers do not take yet.

Use, once per frame, on the frame's command encoder (outside passes):

    timer.begin_frame()
    timer.mark(enc)          # before the shadow pass
    ...                      # shadow passes
    timer.mark(enc)          # after the shadow passes
    ...                      # the scene colour pass
    timer.mark(enc)          # after the scene pass
    ...                      # post stages and the HUD pass
    timer.mark(enc)          # after the last pass
    timer.resolve(enc)       # before enc.finish()
    # submit, then wait for the GPU (`device.poll`)
    var ticks = timer.read() # nanoseconds between consecutive marks

Each mark is one 8-byte tick count; `read` converts the differences with the queue's timestamp period."""
from wgpu import WGPUBufferUsage, WGPUFeatureName, WGPUQueryType
from wgpu.buffer import Buffer
from wgpu.command import CommandEncoder
from wgpu.device import Device
from wgpu.query_set import QuerySet

comptime MAX_MARKS = 8
# WGPUNativeFeature_TimestampQueryInsideEncoders of wgpu-native's wgpu.h (build/deps/wgpu-mojo/ffi/include/webgpu/wgpu.h); wgpu-mojo's
# top-level package does not export the native feature names (rule R6: no private wgpu imports). tests/gpu_timer_native.mojo requests a
# device with it, so a wrong value fails there.
comptime NATIVE_TIMESTAMP_INSIDE_ENCODERS: UInt32 = 0x00030024


def gpu_timer_features() -> List[UInt32]:
    """The features the device must be requested with for `GpuTimer.create` to return a timer."""
    return [WGPUFeatureName.TimestampQuery, NATIVE_TIMESTAMP_INSIDE_ENCODERS]


struct GpuTimer(Movable):
    var queries: QuerySet
    var resolved: Buffer  # MAX_MARKS ticks, written by resolve_query_set
    var readback: Buffer  # the same, mappable
    var period_ns: Float32  # nanoseconds per tick
    var marks: Int

    def __init__(out self, device: Device) raises:
        self.queries = device.create_query_set(WGPUQueryType.Timestamp, UInt32(MAX_MARKS), "gpu_timer")
        self.resolved = device.create_buffer(
            UInt64(MAX_MARKS * 8), WGPUBufferUsage.QUERY_RESOLVE | WGPUBufferUsage.COPY_SRC, label="gpu_timer_resolve",
        )
        self.readback = device.create_buffer(
            UInt64(MAX_MARKS * 8), WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="gpu_timer_read",
        )
        self.period_ns = device.queue_timestamp_period()
        self.marks = 0

    @staticmethod
    def create(device: Device) raises -> Optional[GpuTimer]:
        for f in gpu_timer_features():
            if not device.has_feature(f):
                return None
        return GpuTimer(device)

    def begin_frame(mut self):
        self.marks = 0

    def mark(mut self, enc: CommandEncoder):
        """A timestamp at this point of the encoder. Marks past MAX_MARKS are ignored (and not counted)."""
        if self.marks < MAX_MARKS:
            enc.write_timestamp(self.queries, UInt32(self.marks))
            self.marks += 1

    def resolve(self, enc: CommandEncoder):
        if self.marks >= 2:
            enc.resolve_query_set(self.queries, UInt32(0), UInt32(self.marks), self.resolved, UInt64(0))
            enc.copy_buffer_to_buffer(self.resolved, UInt64(0), self.readback, UInt64(0), UInt64(self.marks * 8))

    def read(self) raises -> List[Int64]:
        """Nanoseconds between mark i and mark i + 1, for the marks of the frame whose commands have finished."""
        var out = List[Int64]()
        if self.marks < 2:
            return out^
        var raw = self.readback.map_read(UInt64(0), UInt64(self.marks * 8)).bitcast[UInt64]()
        for i in range(self.marks - 1):
            var d = raw[i + 1] - raw[i]
            out.append(Int64(Float64(d) * Float64(self.period_ns)))
        self.readback.unmap()
        return out^
