# tier: integration
# Per-object motion blur (app/velocity.mojo, app/lens.mojo ObjectMotionBlur). The camera stands still; of three dark
# boxes 8 m away one stands, one moves 0.5 m to the right between two frames and one turns 0.2 rad about the view axis.
#   the velocity target  the pixel of each box holds the move its surface point made on screen, worked out here by
#                        projecting the point where it is and where it was
#   the blur             the moving box's vertical edges are smeared over its move, the standing box's are not;
#                        MotionBlur (camera only) leaves the moving box sharp
#   matching             items are matched to the previous frame's when the list changes order
from std.math import sin, cos, sqrt
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import ArenaRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget, Aux
from app.post import PostEffect, Style, Stage
from app.lens import MotionBlur, ObjectMotionBlur
from app.velocity import VelocityPass, velocity_uv, match_previous, VELOCITY_RANGE

comptime W: UInt32 = 640
comptime H: UInt32 = 360


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


struct ShowAux(Style):
    comptime NAME: StaticString = "show_aux"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let a = aux_at(uv);
  return vec3<f32>(a.rg, a.a);
}
"""


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


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: ArenaRendererOf[P, F, A], step: Int):
    """Frame `step`: the standing box at x = -4, the moving box at x = 0.5 * step, the turning box at x = 4 turned
    0.2 * step rad about z."""
    var dark = _v(0.05, 0.05, 0.05)
    r.push(DrawItem(0, _v(-4, 0, -8), 0.0, 0.0, 0.0, 1.0, _v(0.8, 1.2, 0.5), dark))
    r.push(DrawItem(0, _v(0.5 * Float64(step), 0, -8), 0.0, 0.0, 0.0, 1.0, _v(0.8, 1.2, 0.5), dark))
    var a = 0.2 * Float64(step)
    r.push(DrawItem(0, _v(4, 0, -8), 0.0, 0.0, sin(a / 2), cos(a / 2), _v(2, 2, 1), dark, r.cube, -1, MAT_COLOR))


def uv_of(v: View, p: Vec3) -> Tuple[Float64, Float64]:
    var c = v.project(p)
    return (Float64(c.x) / Float64(c.w) * 0.5 + 0.5, 0.5 - Float64(c.y) / Float64(c.w) * 0.5)


def offset(v: View, p: Vec3) -> Int:
    var u = uv_of(v, p)
    return (Int(u[1] * Float64(H)) * Int(W) + Int(u[0] * Float64(W))) * 4


def lum(px: List[UInt8], x: Int, y: Int) -> Float64:
    var o = (y * Int(W) + x) * 4
    return (Float64(Int(px[o])) + Float64(Int(px[o + 1])) + Float64(Int(px[o + 2]))) / 3.0


def edge_width(px: List[UInt8], x0: Int, x1: Int, y: Int) -> Int:
    """Pixels of row y between 10 % and 90 % of the step from column x0 to column x1."""
    var a = lum(px, x0, y)
    var b = lum(px, x1, y)
    var n = 0
    for i in range(x0, x1 + 1):
        var t = (lum(px, i, y) - a) / (b - a)
        if t > 0.1 and t < 0.9:
            n += 1
    return n


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def main() raises:
    var s = Suite("motion_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="motion")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Real(Float32(W) / Float32(H))
    var view = View(CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)

    # ---- matching
    var a0 = DrawItem(0, _v(0, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), 0, -1, MAT_COLOR)
    var b0 = DrawItem(0, _v(5, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), 0, -1, MAT_COLOR)
    var a1 = DrawItem(0, _v(0.1, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), 0, -1, MAT_COLOR)
    var b1 = DrawItem(0, _v(5.1, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), 0, -1, MAT_COLOR)
    var other = DrawItem(0, _v(5.1, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), 1, -1, MAT_COLOR)
    var was: List[DrawItem] = [a0.copy(), b0.copy()]
    var swapped: List[DrawItem] = [b1.copy(), a1.copy(), other.copy()]
    var m = match_previous(swapped, was)
    s.check(m[0] == 1 and m[1] == 0 and m[2] == -1, "two items that changed places are matched by position; an item of another mesh has no match")
    var same: List[DrawItem] = [a1.copy(), b1.copy()]
    var m2 = match_previous(same, was)
    s.check(m2[0] == 0 and m2[1] == 1, "items in the same order are matched in place")

    # ---- the velocity target
    var rv = ArenaRendererOf[DefaultPasses, Stage[ShowAux], Aux[VelocityPass]](device, format, view)
    rv.begin(view.copy())
    scene(rv, 0)
    rv.draw(device, target.handle().raw, W, H, hud)
    var first = read(device, cap, target.handle().raw)
    var o_first = offset(view, _v(0, 0, -7.75))
    s.check(first[o_first] == 128 and first[o_first + 1] == 128 and first[o_first + 2] == 255, "the first frame: bodies are drawn with no move (128, 128)")
    rv.begin(view.copy())
    scene(rv, 1)
    rv.draw(device, target.handle().raw, W, H, hud)
    var vel = read(device, cap, target.handle().raw)
    var step_uv = VELOCITY_RANGE / 127.0
    # the moving box's front face: where its middle is now and where it was
    var now_b = uv_of(view, _v(0.5, 0, -7.75))
    var was_b = uv_of(view, _v(0.0, 0, -7.75))
    var ob = offset(view, _v(0.5, 0, -7.75))
    var got_b = velocity_uv(vel[ob], vel[ob + 1])
    print("moving box: its middle moved", (now_b[0] - was_b[0]) * Float64(W), "px to the right ; the target holds", got_b[0] * Float64(W), got_b[1] * Float64(H), "px")
    s.check(abs(got_b[0] - (now_b[0] - was_b[0])) <= step_uv and abs(got_b[1]) <= step_uv, "the moving box's pixel holds its move (within one step of 1 / 127 of the range)")
    var oa = offset(view, _v(-4, 0, -7.75))
    s.check(vel[oa] == 128 and vel[oa + 1] == 128 and vel[oa + 2] == 255, "the standing box's pixel holds no move")
    var osky = offset(view, _v(0, 3.0, -8))
    s.eqi(Int(vel[osky + 2]), 0, "the sky's pixel is marked as no body")
    # the turning box: the point 0.7 m above its centre on the front face, now, and the same point of the box before
    var up_now = _v(4.0 - 0.7 * sin(0.2), 0.7 * cos(0.2), -7.5)
    var up_was = _v(4.0, 0.7, -7.5)
    var un = uv_of(view, up_now)
    var uw = uv_of(view, up_was)
    var oc = offset(view, up_now)
    var got_c = velocity_uv(vel[oc], vel[oc + 1])
    print("turning box, 0.7 m above its centre: the point moved", (un[0] - uw[0]) * Float64(W), (un[1] - uw[1]) * Float64(H), "px ; the target holds", got_c[0] * Float64(W), got_c[1] * Float64(H), "px")
    s.check(abs(got_c[0] - (un[0] - uw[0])) <= 1.5 * step_uv and abs(got_c[1] - (un[1] - uw[1])) <= 1.5 * step_uv, "the turning box's upper pixel holds its move")
    var dn_now = _v(4.0 + 0.7 * sin(0.2), -0.7 * cos(0.2), -7.5)
    var od = offset(view, dn_now)
    var got_d = velocity_uv(vel[od], vel[od + 1])
    s.check(got_c[0] < 0.0 and got_d[0] > 0.0, "above its centre the turning box moves left, below it right")

    # ---- the blur
    var plain = ArenaRendererOf[DefaultPasses](device, format, view)
    plain.begin(view.copy())
    scene(plain, 1)
    plain.draw(device, target.handle().raw, W, H, hud)
    var sharp = read(device, cap, target.handle().raw)
    var rb = ArenaRendererOf[DefaultPasses, Stage[ObjectMotionBlur], Aux[VelocityPass]](device, format, view)
    rb.shutter = 1.0
    for step in range(2):
        rb.begin(view.copy())
        scene(rb, step)
        rb.draw(device, target.handle().raw, W, H, hud)
    var blurred = read(device, cap, target.handle().raw)
    var row = Int(H) // 2
    var move_px = (now_b[0] - was_b[0]) * Float64(W)
    var left_b = Int(uv_of(view, _v(0.5 - 0.8, 0, -7.5))[0] * Float64(W))  # the moving box's left edge, now
    var left_a = Int(uv_of(view, _v(-4.0 - 0.8, 0, -7.5))[0] * Float64(W))
    var wb = edge_width(blurred, left_b - 40, left_b + 40, row)
    var wa = edge_width(blurred, left_a - 40, left_a + 40, row)
    print("moving box: moved", move_px, "px ; its left edge is", wb, "px wide (a ramp of that length:", 0.8 * move_px, ") ; the standing box's left edge:", wa, "px")
    s.check(Float64(wb) > 0.55 * move_px and Float64(wb) < 1.05 * move_px, "the moving box's edge is smeared over its move")
    s.check(wa <= 1, "the standing box's edge is not smeared")
    # the camera-only stage leaves the moving box as it is
    var rc = ArenaRendererOf[DefaultPasses, Stage[MotionBlur]](device, format, view)
    rc.shutter = 1.0
    for step in range(2):
        rc.begin(view.copy())
        scene(rc, step)
        rc.draw(device, target.handle().raw, W, H, hud)
    var cam_only = read(device, cap, target.handle().raw)
    print("MotionBlur (camera only), same two frames: pixels that differ from the frame without a stage:", diff(sharp, cam_only))
    s.eqi(diff(sharp, cam_only), 0, "MotionBlur does not blur a body moving in front of a still camera")
    # a third frame in which nothing moved
    rb.begin(view.copy())
    scene(rb, 1)
    rb.draw(device, target.handle().raw, W, H, hud)
    var still = read(device, cap, target.handle().raw)
    print("ObjectMotionBlur, nothing moved: pixels that differ from the frame without a stage:", diff(sharp, still))
    s.eqi(diff(sharp, still), 0, "when nothing moves the frame is unchanged")
    rb.shutter = 0.5
    for step in range(2):
        rb.begin(view.copy())
        scene(rb, step)
        rb.draw(device, target.handle().raw, W, H, hud)
    var half = read(device, cap, target.handle().raw)
    var wh = edge_width(half, left_b - 40, left_b + 40, row)
    print("shutter 0.5: the moving box's left edge is", wh, "px wide")
    s.check(Float64(wh) > 0.35 * Float64(wb) and Float64(wh) < 0.7 * Float64(wb), "half the shutter: about half the smear")
    s.check(target.handle().raw == target.handle().raw, "the target is alive until here")
    s.finish()
