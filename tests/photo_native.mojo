# tier: integration
# Photo mode on the GPU (app/photo.mojo, issue #146), on lavapipe:
#   - the photo pipeline (depth of field, bloom, exposure) with every setting at its default gives the frame of the
#     plain pipeline back, pixel for pixel;
#   - exposure +1 EV doubles every channel that does not reach white (within 1 of 255 rounding);
#   - an f-number blurs the edge of a box out of focus;
#   - bloom 1.0 brightens the frame;
#   - PhotoCapture draws the free camera's view at twice the frame (1280 x 720 for 640 x 360) and writes
#     build/photo/capture.png; scripts/test_console.py decodes it with Pillow.
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from game.photo_camera import PhotoMode
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect
from app.photo import PhotoCapture, PhotoPost, apply_photo
from std.os import makedirs
from std.os.path import exists

comptime W: UInt32 = 640
comptime H: UInt32 = 360


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def read(device: Device, mut cap: FrameCapture, tex: WGPUTextureHandle) raises -> List[UInt8]:
    var req = cap.capture(device, tex)
    req.wait()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(W))
    var out = List[UInt8]()
    for y in range(Int(H)):
        for x in range(Int(W) * 4):
            out.append(p[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A]):
    """A floor, a near dark box at 3 m and a light one at 8 m, in front of a camera at the origin looking along -z."""
    r.push(DrawItem(0, _v(0, -1.5, -10), 0.0, 0.0, 0.0, 1.0, _v(20, 0.2, 20), _v(0.3, 0.35, 0.3), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(-1.6, 0, -3.5), 0.0, 0.0, 0.0, 1.0, _v(1, 1.2, 1), _v(0.05, 0.05, 0.05), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(1.5, 0, -9.0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(0.9, 0.85, 0.7), r.cube, -1, MAT_COLOR))


def lum(px: List[UInt8], x: Int, y: Int) -> Float64:
    var o = (y * Int(W) + x) * 4
    return (Float64(Int(px[o])) + Float64(Int(px[o + 1])) + Float64(Int(px[o + 2]))) / 3.0


def total(px: List[UInt8]) -> Float64:
    var t = 0.0
    for i in range(0, len(px), 4):
        t += Float64(Int(px[i])) + Float64(Int(px[i + 1])) + Float64(Int(px[i + 2]))
    return t


def edge_width(px: List[UInt8], x0: Int, x1: Int, y: Int) -> Int:
    var a = lum(px, x0, y)
    var b = lum(px, x1, y)
    var n = 0
    for i in range(x0, x1 + 1):
        var t = (lum(px, i, y) - a) / (b - a)
        if t > 0.1 and t < 0.9:
            n += 1
    return n


def column_of(v: View, p: Vec3) -> Int:
    var c = v.project(p)
    return Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W))


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def main() raises:
    var s = Suite("photo_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="photo")
    var hud = Hud(device, format)
    hud.set(DrawList(), Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Real(Float32(W) / Float32(H))
    var cam = CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0)
    var photo = PhotoMode()
    photo.enter(cam)
    var view = View(photo.pose(), aspect)

    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    plain.begin(view.copy())
    scene(plain)
    plain.draw(device, target.handle().raw, W, H, hud)
    var base = read(device, cap, target.handle().raw)

    var r = SceneRendererOf[DefaultPasses, PhotoPost](device, format, view)
    r.lens_sensor = 0.15  # a large sensor, so the blur discs are many pixels at this size (as in tests/lens_native.mojo)
    r.lens_max_coc = 40.0
    apply_photo(r, photo)
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var neutral = read(device, cap, target.handle().raw)
    print("photo pipeline at its defaults (pinhole, bloom 0, 0 EV): pixels that differ from the plain pipeline:", diff(base, neutral))
    s.eqi(diff(base, neutral), 0, "at its defaults the photo pipeline gives the plain frame back")

    _ = photo.set_exposure(1.0)
    apply_photo(r, photo)
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var bright = read(device, cap, target.handle().raw)
    var checked = 0
    var worst = 0
    for i in range(0, len(base), 4):
        for c in range(3):
            var a = Int(base[i + c])
            if a < 127:
                worst = max(worst, abs(Int(bright[i + c]) - 2 * a))
                checked += 1
    print("+1 EV:", checked, "channels below 127 checked ; largest |out - 2 in|:", worst)
    s.check(checked > 100000 and worst <= 1, "+1 EV doubles each channel that stays below white")
    _ = photo.set_exposure(0.0)

    _ = photo.set_focus(8.0)
    _ = photo.set_fstop(1.0)
    apply_photo(r, photo)
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var dof = read(device, cap, target.handle().raw)
    var row = Int(H) // 2
    var col = column_of(view, _v(-2.1, 0, -3.0))  # the near box's left edge
    var w0 = edge_width(base, col - 30, col + 30, row)
    var w1 = edge_width(dof, col - 30, col + 30, row)
    print("f/1, focus 8 m: the near box's edge (column", col, ") is", w1, "px wide ;", w0, "px without depth of field")
    s.check(w1 >= w0 + 4, "an f-number blurs the box out of focus")
    _ = photo.set_fstop(0.0)

    _ = photo.set_bloom(1.0)
    apply_photo(r, photo)
    r.bloom_threshold = 0.5
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var bloomed = read(device, cap, target.handle().raw)
    print("bloom 1.0 at threshold 0.5: frame sum", total(bloomed), "against", total(base))
    s.check(total(bloomed) > total(base) * 1.01, "bloom brightens the frame")
    _ = photo.set_bloom(0.0)

    # the free camera moved 2 m back and turned, captured at twice the frame
    photo.move(-1.0, 0.0, 0.0, 40.0, 0.0, 0.5)
    var size = photo.capture_size(Int(W), Int(H))
    var big_hud = Hud(device, format)
    big_hud.set(DrawList(), Float32(size[0]), Float32(size[1]))
    var pc = PhotoCapture(device, UInt32(size[0]), UInt32(size[1]), format)
    var pv = View(photo.pose(), aspect)
    apply_photo(r, photo)
    r.begin(pv.copy())
    scene(r)
    pc.start(device, r, big_hud)
    pc.req.value().wait()
    s.check(pc.poll(), "the readback arrived and was encoded")
    s.check(size[0] == 2 * Int(W) and size[1] == 2 * Int(H), "the capture is 2x the frame: " + String(size[0]) + " x " + String(size[1]))
    s.check(len(pc.png) > 1000 and pc.png[1] == 80, "PhotoCapture made a PNG of " + String(len(pc.png)) + " bytes")
    if not exists("build/photo"):
        makedirs("build/photo")
    with open("build/photo/capture.png", "w") as f:
        f.write_bytes(pc.png)
    print("wrote build/photo/capture.png", size[0], "x", size[1], len(pc.png), "bytes")
    _ = target.handle()  # kept alive to here: a texture's last use is a raw handle the queued copy still reads
    s.finish()
