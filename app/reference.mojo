"""A reproducible frame for the native/web pixel parity: fresh Sim, `frames` steps at 1/60, one draw into an
RGBA8Unorm target, read back through FrameCapture. Same code natively (app/pixels.mojo) and in the web app."""
from render import Renderer
from sim import Sim
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture
from wgpu.device import Device
from wgpu.texture import Texture


def fill(mut renderer: Renderer, sim: Sim, aspect: Float32) raises:
    """Push every body's pose into the renderer's staging array."""
    renderer.begin(aspect)
    for i in range(len(sim.handles)):
        var st = sim.world.state(sim.handles[i])
        renderer.push(
            Float64(st.pos[0]), Float64(st.pos[1]), Float64(st.pos[2]),
            Float64(st.rot.x), Float64(st.rot.y), Float64(st.rot.z), Float64(st.rot.w),
            sim.halves[3 * i], sim.halves[3 * i + 1], sim.halves[3 * i + 2],
        )


struct Reference(Movable):
    var renderer: Renderer
    var target: Texture
    var capture: FrameCapture
    var req: Optional[MapRequest]
    var width: UInt32
    var height: UInt32

    def __init__(out self, device: Device, width: UInt32, height: UInt32) raises:
        # The format is pinned (not the browser's preferred canvas format) so both sides produce the same bytes.
        self.renderer = Renderer(device, WGPUTextureFormat.RGBA8Unorm)
        self.target = device.create_texture(
            width, height, 1, WGPUTextureFormat.RGBA8Unorm,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
            label="reference_target",
        )
        self.capture = FrameCapture(device, width, height)
        self.req = None
        self.width = width
        self.height = height

    def __init__(out self, *, deinit move: Self):
        self.renderer = move.renderer^
        self.target = move.target^
        self.capture = move.capture^
        self.req = move.req^
        self.width = move.width
        self.height = move.height

    def start(mut self, device: Device, frames: Int) raises:
        var sim = Sim()
        for _ in range(frames):
            sim.step(1.0 / 60.0)
        fill(self.renderer, sim, Float32(self.width) / Float32(self.height))
        self.renderer.draw(device, self.target.handle().raw)
        self.req = self.capture.capture(device, self.target.handle().raw)

    def poll(mut self) raises -> UInt64:
        """Address of the mapped pixels once the read-back finished, else 0."""
        if self.req and self.req.value().ready():
            var req = self.req.take()
            return UInt64(Int(req.take()))
        return 0

    def release(mut self):
        self.capture.unmap()

    def pitch(self) -> UInt32:
        return self.capture.row_pitch()
