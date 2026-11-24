"""A reproducible particle frame for the native/web pixel parity (#121): floor, a cube and a sky sphere, the `spark`
emitter (additive) and a burst of `smoke` (alpha) stepped 20 times from fixed seeds, drawn by
SceneRendererOf[Then[DefaultPasses, ParticlePass]] into a 480 x 270 RGBA8Unorm target and read back through
FrameCapture. The same code runs natively (app/particle_pixels.mojo) and in the web app (app_particles_request)."""
from game.camera_view import View
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.particles_table import particles_default_table, particles_row
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
from app.render_pass import Then
from app.particle_pass import ParticlePass

comptime PARTICLE_FRAME_W: UInt32 = 480
comptime PARTICLE_FRAME_H: UInt32 = 270
comptime ParticleFramePasses = Then[DefaultPasses, ParticlePass]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def particle_frame_view() -> View:
    var aspect = Real(Float32(PARTICLE_FRAME_W) / Float32(PARTICLE_FRAME_H))
    var eye = _v(0, 2.5, 7)
    return View(CameraPose(eye, look_rotation(_v(0, 0.8, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)


struct ParticleReference(Movable):
    var renderer: SceneRendererOf[ParticleFramePasses]
    var target: Texture
    var capture: FrameCapture
    var hud: Hud
    var req: Optional[MapRequest]

    def __init__(out self, device: Device) raises:
        var format = WGPUTextureFormat.RGBA8Unorm  # pinned, so both sides produce the same bytes
        self.renderer = SceneRendererOf[ParticleFramePasses](device, format, particle_frame_view())
        self.target = device.create_texture(
            PARTICLE_FRAME_W, PARTICLE_FRAME_H, 1, format,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="particle_reference_target",
        )
        self.capture = FrameCapture(device, PARTICLE_FRAME_W, PARTICLE_FRAME_H)
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(PARTICLE_FRAME_W), Float32(PARTICLE_FRAME_H))
        self.req = None

    def __init__(out self, *, deinit move: Self):
        self.renderer = move.renderer^
        self.target = move.target^
        self.capture = move.capture^
        self.hud = move.hud^
        self.req = move.req^

    def start(mut self, device: Device) raises:
        var table = particles_default_table()
        _ = self.renderer.passes.second.system.add(particles_row(table, "spark"), 0.0, 1.0, 1.0, 7)
        var smoke = particles_row(table, "smoke")
        smoke.rate = 0.0
        smoke.burst_count = 200
        _ = self.renderer.passes.second.system.add(smoke^, 1.5, 0.5, 0.0, 11)
        var view = particle_frame_view()
        for _ in range(20):
            self.renderer.passes.second.advance(1.0 / 60.0, view)
        self.renderer.begin(particle_frame_view())
        self.renderer.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(16, 0.5, 16), _v(0.6, 0.65, 0.55), self.renderer.cube, -1, MAT_COLOR))
        self.renderer.push(DrawItem(0, _v(-1.5, 1.0, 0), 0.0, 0.0, 0.0, 1.0, _v(1.2, 2.0, 1.2), _v(0.85, 0.3, 0.25), self.renderer.cube, -1, MAT_COLOR))
        self.renderer.push(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), self.renderer.sphere, -1, MAT_SKY))
        self.renderer.draw(device, self.target.handle().raw, PARTICLE_FRAME_W, PARTICLE_FRAME_H, self.hud)
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
