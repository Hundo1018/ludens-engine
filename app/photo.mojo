"""Photo mode on the GPU (game/photo_camera.mojo holds the camera and the settings; docs/console.md, issue #146).

`PhotoPost` is the pipeline the photo renderer draws with: depth of field, bloom, then the exposure, so the three can be
changed while photo mode is on without touching the game's own pipeline (which is drawn again when photo mode ends).
A game's own post stages are not part of it.

`apply_photo` copies the settings into a renderer. `PhotoCapture` draws one frame at the capture size into a texture of
its own, reads it back and encodes it as PNG (platform/png.mojo): `start` records the draw and the copy, `poll` returns
True once the PNG is in `png`. A BGRA target is swapped to RGB on the way."""
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.texture import Texture
from game.photo_camera import PhotoMode
from hud import Hud
from app.lens import DepthOfField, Exposure
from app.post import Stage, ThenPost
from app.post_fx import Bloom
from app.render3d import SceneRendererOf
from app.render_pass import RenderPass, AuxTarget
from platform.png import encode_png

comptime PhotoPost = ThenPost[ThenPost[Stage[DepthOfField], Bloom], Stage[Exposure]]


def apply_photo[P: RenderPass, A: AuxTarget](mut r: SceneRendererOf[P, PhotoPost, A], photo: PhotoMode):
    r.lens_focus = photo.focus
    r.lens_fstop = photo.fstop
    r.exposure_ev = photo.exposure
    r.bloom_intensity = photo.bloom


struct PhotoCapture(Movable):
    var width: UInt32
    var height: UInt32
    var format: UInt32
    var target: Texture
    var capture: FrameCapture
    var req: Optional[MapRequest]
    var png: List[UInt8]

    def __init__(out self, device: Device, width: UInt32, height: UInt32, format: UInt32) raises:
        self.width = width
        self.height = height
        self.format = format
        self.target = device.create_texture(
            width, height, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="photo_capture",
        )
        self.capture = FrameCapture(device, width, height)
        self.req = None
        self.png = List[UInt8]()

    def start[P: RenderPass, A: AuxTarget](mut self, device: Device, mut r: SceneRendererOf[P, PhotoPost, A], hud: Hud) raises:
        """Draw the renderer's current view (after `begin` and the pushes) at the capture size and queue the readback."""
        r.draw(device, self.target.handle().raw, self.width, self.height, hud)
        self.req = self.capture.capture(device, self.target.handle().raw)

    def poll(mut self) raises -> Bool:
        """True once the readback has arrived and `png` holds the file."""
        if not self.req or not self.req.value().ready():
            return False
        var req = self.req.take()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(self.width))
        var w = Int(self.width)
        var h = Int(self.height)
        var bgra = self.format == WGPUTextureFormat.BGRA8Unorm or self.format == WGPUTextureFormat.BGRA8UnormSrgb
        var rows = List[UInt8](capacity=w * h * 4)
        for y in range(h):
            for x in range(w):
                var o = y * pitch + 4 * x
                if bgra:
                    rows.append(p[unsafe_offset=o + 2])
                    rows.append(p[unsafe_offset=o + 1])
                    rows.append(p[unsafe_offset=o])
                else:
                    rows.append(p[unsafe_offset=o])
                    rows.append(p[unsafe_offset=o + 1])
                    rows.append(p[unsafe_offset=o + 2])
                rows.append(255)
        self.capture.unmap()
        self.png = encode_png(rows, w, h, 4 * w)
        return True
