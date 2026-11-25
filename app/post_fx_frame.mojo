"""Reproducible frames of the picture effects for the native/web pixel parity (#139): the scene of the particle frame
(floor, a box, a sky sphere) at 480 x 270 RGBA8Unorm through

    look      FXAA, bloom and a graded LUT, one sample          (ThenPost[Fxaa, ThenPost[Bloom, Grade]])
    msaa      MSAA 4x, bloom and the same LUT                   (ThenPost[Bloom, Grade], RenderCaps.samples = 4)

read back through FrameCapture. The same code runs natively (app/post_fx_pixels.mojo) and in the web app
(app_post_fx_request); shell/web/app.ts compares both with the native bytes under the existing tolerance rows."""
from game.camera_view import View
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture
from wgpu.device import Device
from wgpu.texture import Texture
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_res import RenderCaps
from app.post import PostEffect, ThenPost
from app.post_fx import Fxaa, Bloom, Grade, graded_lut

comptime POST_FX_W: UInt32 = 480
comptime POST_FX_H: UInt32 = 270
comptime LookStages = ThenPost[Fxaa, ThenPost[Bloom, Grade]]
comptime MsaaStages = ThenPost[Bloom, Grade]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def post_fx_view() -> View:
    var aspect = Real(Float32(POST_FX_W) / Float32(POST_FX_H))
    var eye = _v(0, 2.5, 7)
    return View(CameraPose(eye, look_rotation(_v(0, 0.8, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)


struct PostFxFrame[F: PostEffect, SAMPLES: Int](Movable):
    var renderer: SceneRendererOf[DefaultPasses, Self.F]
    var target: Texture
    var capture: FrameCapture
    var hud: Hud
    var req: Optional[MapRequest]

    def __init__(out self, device: Device) raises:
        var format = WGPUTextureFormat.RGBA8Unorm  # pinned, so both sides produce the same bytes
        var caps = RenderCaps.default()
        caps.samples = Self.SAMPLES
        self.renderer = SceneRendererOf[DefaultPasses, Self.F](device, format, post_fx_view(), caps=caps)
        self.target = device.create_texture(
            POST_FX_W, POST_FX_H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
            label="post_fx_reference_target",
        )
        self.capture = FrameCapture(device, POST_FX_W, POST_FX_H)
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(POST_FX_W), Float32(POST_FX_H))
        self.req = None

    def __init__(out self, *, deinit move: Self):
        self.renderer = move.renderer^
        self.target = move.target^
        self.capture = move.capture^
        self.hud = move.hud^
        self.req = move.req^

    def start(mut self, device: Device) raises:
        self.renderer.set_lut(device, 16, graded_lut(16, 0.6, 1.1, 0.8))
        self.renderer.bloom_threshold = 0.75
        self.renderer.bloom_intensity = 1.0
        self.renderer.begin(post_fx_view())
        self.renderer.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(16, 0.5, 16), _v(0.6, 0.65, 0.55), self.renderer.cube, -1, MAT_COLOR))
        self.renderer.push(DrawItem(0, _v(-1.5, 1.0, 0), 0.0, 0.0, 0.0, 1.0, _v(1.2, 2.0, 1.2), _v(0.85, 0.3, 0.25), self.renderer.cube, -1, MAT_COLOR))
        self.renderer.push(DrawItem(1, _v(1.4, 0.7, 0.5), 0.0, 0.0, 0.0, 1.0, _v(0.7, 0.7, 0.7), _v(1.0, 0.95, 0.8), self.renderer.sphere, -1, MAT_COLOR))
        self.renderer.push(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), self.renderer.sphere, -1, MAT_SKY))
        self.renderer.draw(device, self.target.handle().raw, POST_FX_W, POST_FX_H, self.hud)
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


struct PostFxFrames(Movable):
    """Both frames: 0 the one-sample look, 1 the MSAA one."""

    var look: PostFxFrame[LookStages, 1]
    var msaa: PostFxFrame[MsaaStages, 4]

    def __init__(out self, device: Device) raises:
        self.look = PostFxFrame[LookStages, 1](device)
        self.msaa = PostFxFrame[MsaaStages, 4](device)

    def __init__(out self, *, deinit move: Self):
        self.look = move.look^
        self.msaa = move.msaa^

    def start(mut self, device: Device) raises:
        self.look.start(device)
        self.msaa.start(device)

    def poll(mut self, which: Int) raises -> UInt64:
        return self.look.poll() if which == 0 else self.msaa.poll()

    def pitch(self) -> UInt32:
        return self.look.pitch()
