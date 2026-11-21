# tier: integration
# The lens stages (app/lens.mojo) against what the thin lens and the camera's motion predict.
#   depth of field  three dark boxes 3 m, 8 m and 25 m away against the sky, the lens focused at 8 m. The width of each
#                   box's edge (the pixels between 10 % and 90 % of the step) is compared with the blur disc the
#                   formula gives for its distance; the box in focus keeps the edge it has without the stage; a
#                   pinhole (f-number 0) gives the input back, pixel for pixel.
#   motion blur     the camera turns 0.05 rad between two frames: a vertical edge is smeared over the distance the
#                   picture moved, a horizontal edge is not; with the camera still the frame is unchanged.
from std.math import tan, sqrt
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect, Stage, ThenPost
from app.lens import DepthOfField, MotionBlur, coc_pixels, coc_scale, focal_length

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
    """Three dark boxes whose left edges stand against the sky: 3 m, 8 m and 25 m in front of a camera at the origin
    looking along -z. Sizes grow with distance so each is about as large on screen."""
    r.push(DrawItem(0, _v(-1.6, 0, -3.5), 0.0, 0.0, 0.0, 1.0, _v(1, 1.2, 1), _v(0.05, 0.05, 0.05), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(0.8, 0, -9.0), 0.0, 0.0, 0.0, 1.0, _v(2, 3, 2), _v(0.05, 0.05, 0.05), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(12.0, 0, -28.0), 0.0, 0.0, 0.0, 1.0, _v(6, 9, 6), _v(0.05, 0.05, 0.05), r.cube, -1, MAT_COLOR))


def lum(px: List[UInt8], x: Int, y: Int) -> Float64:
    var o = (y * Int(W) + x) * 4
    return (Float64(Int(px[o])) + Float64(Int(px[o + 1])) + Float64(Int(px[o + 2]))) / 3.0


def edge_width(px: List[UInt8], x0: Int, x1: Int, y: Int, vertical: Bool = False) -> Int:
    """Pixels between 10 % and 90 % of the step from the first to the last pixel of the run (x0 .. x1 along row y, or
    along the column y when `vertical`: then x0 .. x1 are rows)."""
    var a = lum(px, y, x0) if vertical else lum(px, x0, y)
    var b = lum(px, y, x1) if vertical else lum(px, x1, y)
    var n = 0
    for i in range(x0, x1 + 1):
        var t = ((lum(px, y, i) if vertical else lum(px, i, y)) - a) / (b - a)
        if t > 0.1 and t < 0.9:
            n += 1
    return n


def column_of(v: View, p: Vec3) -> Int:
    var c = v.project(p)
    return Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W))


def row_of(v: View, p: Vec3) -> Int:
    var c = v.project(p)
    return Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(H))


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def main() raises:
    var s = Suite("lens_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="lens")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Real(Float32(W) / Float32(H))
    var view = View(CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)

    # the formula against the lens equation: an object at z images at v = f z / (z - f); with the sensor at the image
    # distance of the focus, its light covers a disc of (f / N) |v - v_focus| / v
    var sensor = Float32(0.15)  # a large sensor, so the discs are many pixels at this frame size
    var fstop = Float32(0.7)
    var f = focal_length(view, sensor)
    s.almost(f, 0.075 / tan(0.45), "focal length: half the sensor over tan(half the field of view)", tol=1e-6)
    var worst = 0.0
    for z in [1.0, 3.0, 8.0, 25.0, 200.0]:
        var vi = f * z / (z - f)
        var vf = f * 8.0 / (8.0 - f)
        var disc_m = (f / Float64(fstop)) * abs(vi - vf) / vi
        var want = disc_m / Float64(sensor) * Float64(H)
        var got = coc_pixels(view, 8.0, fstop, sensor, Float32(H), z)
        print("blur disc at", z, "m, focus 8 m: lens equation", want, "px ; coc_pixels", got, "px")
        worst = max(worst, abs(got - want))
    s.check(worst < 1e-3, "coc_pixels is the lens equation's disc at five distances")
    s.check(coc_scale(view, 8.0, 0.0, sensor, Float32(H)) == 0.0, "f-number 0 is a pinhole: no disc")

    # ---- depth of field
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    plain.begin(view.copy())
    scene(plain)
    plain.draw(device, target.handle().raw, W, H, hud)
    var sharp = read(device, cap, target.handle().raw)
    var r = SceneRendererOf[DefaultPasses, Stage[DepthOfField]](device, format, view)
    r.lens_sensor = sensor
    r.lens_focus = 8.0
    r.lens_max_coc = 40.0
    r.lens_fstop = 0.0
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var pin = read(device, cap, target.handle().raw)
    print("pinhole: pixels that differ from the frame without the stage:", diff(sharp, pin))
    s.eqi(diff(sharp, pin), 0, "a pinhole lens gives the frame back, pixel for pixel")
    r.lens_fstop = fstop
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var dof = read(device, cap, target.handle().raw)
    var row = Int(H) // 2
    # each box's left edge: front face x = centre - half width, z = centre + half depth
    var edges = [(_v(-2.1, 0, -3.0), 3.0), (_v(-0.2, 0, -8.0), 8.0), (_v(9.0, 0, -25.0), 25.0)]
    var names = ["near (3 m)", "focused (8 m)", "far (25 m)"]
    for k in range(3):
        var col = column_of(view, edges[k][0])
        var disc = coc_pixels(view, 8.0, fstop, sensor, Float32(H), edges[k][1])
        var w0 = edge_width(sharp, col - 30, col + 30, row)
        var w1 = edge_width(dof, col - 30, col + 30, row)
        print("edge of the", names[k], "box at column", col, ": blur disc", disc, "px ; edge width without the stage", w0, "px, with it", w1, "px")
        if k == 1:
            s.check(w1 <= w0 + 1, "the box in focus keeps its edge")
        else:
            s.check(Float64(w1) > 0.3 * disc and Float64(w1) < 1.2 * disc, names[k] + ": the edge is as wide as its blur disc (0.3 to 1.2 of it)")
    # half the aperture, half the disc
    r.lens_fstop = fstop * 2.0
    r.begin(view.copy())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    var dof2 = read(device, cap, target.handle().raw)
    var col0 = column_of(view, edges[0][0])
    var wa = edge_width(dof, col0 - 30, col0 + 30, row)
    var wb = edge_width(dof2, col0 - 30, col0 + 30, row)
    print("near edge at f /", fstop, ":", wa, "px ; at f /", fstop * 2.0, ":", wb, "px")
    s.check(Float64(wb) > 0.35 * Float64(wa) and Float64(wb) < 0.7 * Float64(wa), "twice the f-number: about half the edge width")

    # ---- motion blur
    var m = SceneRendererOf[DefaultPasses, Stage[MotionBlur]](device, format, view)
    m.shutter = 1.0
    var turned = View(CameraPose(_v(0, 0, 0), look_rotation(_v(-0.05, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)
    # frame 1 from the turned camera, frame 2 from `view`: the picture moved by tan(0.05) * sx * W / 2 at the centre
    m.begin(turned.copy())
    scene(m)
    m.draw(device, target.handle().raw, W, H, hud)
    m.begin(view.copy())
    scene(m)
    m.draw(device, target.handle().raw, W, H, hud)
    var blurred = read(device, cap, target.handle().raw)
    var colm = column_of(view, edges[1][0])
    var moved = abs(column_of(turned, edges[1][0]) - colm)
    var wv = edge_width(blurred, colm - 40, colm + 40, row)
    var top = row_of(view, _v(0.8, 1.5, -8.0))  # the focused box's top edge
    var colc = column_of(view, _v(0.8, 0, -8.0))
    var wh0 = edge_width(sharp, top - 20, top + 20, colc, True)
    var wh = edge_width(blurred, top - 20, top + 20, colc, True)
    print("camera turned 0.05 rad: the picture moved", moved, "px at the middle box ; its vertical edge is", wv, "px wide (a ramp of that length: ", 0.8 * Float64(moved), "), its top edge", wh, "px (", wh0, "without the stage)")
    s.check(Float64(wv) > 0.55 * Float64(moved) and Float64(wv) < 1.0 * Float64(moved), "a vertical edge is smeared over the distance the picture moved")
    s.check(wh <= wh0 + 1, "an edge along the motion is not smeared")
    # a third frame from the same camera: nothing moved
    m.begin(view.copy())
    scene(m)
    m.draw(device, target.handle().raw, W, H, hud)
    var still = read(device, cap, target.handle().raw)
    print("camera still: pixels that differ from the frame without the stage:", diff(sharp, still))
    s.eqi(diff(sharp, still), 0, "with the camera still the frame is unchanged")
    m.shutter = 0.5
    m.begin(turned.copy())
    scene(m)
    m.draw(device, target.handle().raw, W, H, hud)
    m.begin(view.copy())
    scene(m)
    m.draw(device, target.handle().raw, W, H, hud)
    var half = read(device, cap, target.handle().raw)
    var wv2 = edge_width(half, colm - 40, colm + 40, row)
    print("shutter 0.5: the vertical edge is", wv2, "px wide")
    s.check(Float64(wv2) > 0.35 * Float64(wv) and Float64(wv2) < 0.7 * Float64(wv), "half the shutter: about half the smear")
    # both stages in one pipeline
    var both = SceneRendererOf[DefaultPasses, ThenPost[Stage[MotionBlur], Stage[DepthOfField]]](device, format, view)
    both.begin(view.copy())
    scene(both)
    both.draw(device, target.handle().raw, W, H, hud)
    var last = read(device, cap, target.handle().raw)
    s.eqi(diff(sharp, last), 0, "both stages, pinhole and closed shutter: the frame unchanged")
    s.check(target.handle().raw == target.handle().raw, "the target is alive until here")  # its last use: not before the read
    s.finish()
