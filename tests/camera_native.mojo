# tier: integration
# The camera's projection, culling and viewports (game/camera_view.mojo, app/cull.mojo, app/viewports.mojo).
#   orthographic  a box 2 m wide covers the same number of pixels 5 m and 25 m from the camera, and that number is the
#                 one the scale gives; in perspective the far one is a fifth as wide. Shadows, point lights and a
#                 stage that rebuilds world positions from depth work in the parallel view.
#   culling       with `cull` on, the frame is the frame without it, pixel for pixel, while most items are dropped;
#                 an item outside the view whose shadow falls into it is kept.
#   viewports     two and four views composed into one frame: each rectangle is the picture the renderer draws alone
#                 at that size, pixel for pixel.
from std.math import sqrt, sin, cos
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureHandle
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import ArenaRendererOf, DefaultPasses
from app.render_pass import RenderPass, Then, AuxTarget, NoAux
from app.render_res import PointLight
from app.shadow_pass import ShadowPass
from app.post import PostEffect, NoPost, Style, Stage
from app.lights import sun_shadow_vp
from app.cull import MeshBounds, ShadowReach, visible_items, capsule_outside
from app.viewports import SplitScreen, split_rects, Rect

comptime W: UInt32 = 480
comptime H: UInt32 = 270
comptime Lit = Then[ShadowPass, DefaultPasses]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


struct WorldHeight(Style):
    """White where the surface under the pixel is above y = 0.6, black below: needs world_at (depth to world)."""

    comptime NAME: StaticString = "world_height"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(step(0.6, world_at(uv).y));
}
"""


def pose(eye: Vec3, at: Vec3, aspect: Float64) -> CameraPose:
    return CameraPose(eye, look_rotation(at - eye, _v(0, 1, 0)), 0.9, Real(aspect), 0.1, 200.0)


def read(device: Device, mut cap: FrameCapture, tex: WGPUTextureHandle, w: Int, h: Int) raises -> List[UInt8]:
    var req = cap.capture(device, tex)
    req.wait()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(UInt32(w)))
    var out = List[UInt8]()
    for y in range(h):
        for x in range(w * 4):
            out.append(p[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: ArenaRendererOf[P, F, A], many: Bool):
    """A floor, two boxes 2 m wide at z = 0 and z = -20, a ball, a tall box off to the side whose shadow reaches the
    middle; with `many`, 300 more boxes in a ring 60 to 90 m out."""
    r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(120, 0.5, 120), _v(0.7, 0.7, 0.7), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(-2.5, 1, 0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(0.9, 0.2, 0.2), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(2.5, 1, -20), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(0.2, 0.3, 0.9), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(1, _v(0, 0.6, 2), 0.0, 0.0, 0.0, 1.0, _v(0.6, 0.6, 0.6), _v(0.2, 0.8, 0.3)))
    r.push(DrawItem(0, _v(8, 6, 2), 0.0, 0.0, 0.0, 1.0, _v(2, 12, 2), _v(0.8, 0.8, 0.2), r.cube, -1, MAT_COLOR))
    if many:
        for i in range(300):
            var a = Float64(i) * 0.37
            var d = 60.0 + Float64(i % 30)
            var cx = d * cos(a)
            var cz = d * sin(a)
            if i % 2 == 0:
                r.push(DrawItem(0, _v(cx, 1, cz), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(0.5, 0.5, 0.9), r.cube, -1, MAT_COLOR))
            else:
                r.push(DrawItem(0, _v(cx, 1, cz), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(0.9, 0.5, 0.5)))


def span(px: List[UInt8], w: Int, row: Int, red: Bool) -> Int:
    """Pixels of `row` that show the red (or the blue) box."""
    var n = 0
    for x in range(w):
        var o = (row * w + x) * 4
        var r = Int(px[o])
        var b = Int(px[o + 2])
        if (red and r > 120 and b < 90 and Int(px[o + 1]) < 90) or (not red and b > 120 and r < 90):
            n += 1
    return n


def at(v: View, p: Vec3) -> Int:
    """The offset in a W x H RGBA frame of the pixel that shows world point p."""
    var c = v.project(p)
    var x = Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W))
    var y = Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(H))
    return (min(max(y, 0), Int(H) - 1) * Int(W) + min(max(x, 0), Int(W) - 1)) * 4


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def main() raises:
    var s = Suite("camera_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var usage = WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC
    var target = device.create_texture(W, H, 1, format, usage, label="camera")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Float64(W) / Float64(H)
    var cam = pose(_v(0, 1, 5), _v(0, 1, 0), aspect)

    # ---- orthographic
    var persp = View(cam, Real(aspect))
    var ortho = View.orthographic(cam, 4.0, Real(aspect))
    var r = ArenaRendererOf[Lit](device, format, persp)
    r.set_shadow(device, sun_shadow_vp(_v(0.4, 1.0, 0.6), _v(0, 0, -8), 30.0, 60.0), True)
    r.begin(persp.copy())
    scene(r, False)
    r.draw(device, target.handle().raw, W, H, hud)
    var fp = read(device, cap, target.handle().raw, Int(W), Int(H))
    r.begin(ortho.copy())
    scene(r, False)
    r.draw(device, target.handle().raw, W, H, hud)
    var fo = read(device, cap, target.handle().raw, Int(W), Int(H))
    var row = Int(H) // 2 - 10  # y = 1.3 m in the parallel view: through both boxes
    var want = Int(2.0 / (2.0 * 4.0 * aspect) * Float64(W) + 0.5)
    print("box 2 m wide, pixels in a row: perspective near", span(fp, Int(W), row, True), "far", span(fp, Int(W), Int(H) // 2 - 2, False),
          "; orthographic near", span(fo, Int(W), row, True), "far", span(fo, Int(W), row, False), "; the scale gives", want)
    s.check(abs(span(fo, Int(W), row, True) - want) <= 1, "orthographic: the near box is as wide as the scale says")
    s.check(abs(span(fo, Int(W), row, False) - want) <= 1, "orthographic: the box 20 m further is the same width")
    var pn = span(fp, Int(W), row, True)
    var pf = span(fp, Int(W), Int(H) // 2 - 2, False)
    s.check(pf * 4 < pn and pf > 0, "perspective: the far box is less than a quarter as wide")
    var c0 = ortho.project(_v(1, 1, 0))
    var c1 = ortho.project(_v(1, 1, -40))
    s.check(abs(Float64(c0.x) - Float64(c1.x)) < 1e-6 and Float64(c0.w) == 1.0, "View.project: parallel lines stay parallel (the same x 40 m apart, w = 1)")
    s.almost(Float64(c0.x), 1.0 / (4.0 * aspect), "View.project: x is metres over the half width", tol=1e-6)
    # from above and behind, parallel: the tall box's shadow lies on the floor where the sun's direction puts it. The
    # box's middle (y = 6) shadows the floor at (8 - 0.4 * 6, 2 - 0.6 * 6).
    var iso = View.orthographic(pose(_v(0, 12, 14), _v(0, 0, -2), aspect), 9.0, Real(aspect))
    r.begin(iso.copy())
    scene(r, False)
    r.draw(device, target.handle().raw, W, H, hud)
    var fi = read(device, cap, target.handle().raw, Int(W), Int(H))
    var o_sun = at(iso, _v(-6, 0, 2))
    var o_sh = at(iso, _v(8.0 - 0.4 * 6.0, 0, 2.0 - 0.6 * 6.0))
    print("orthographic from above: floor in the sun", Int(fi[o_sun]), "; floor under the tall box's shadow", Int(fi[o_sh]))
    s.check(Int(fi[o_sun]) > 100 and Int(fi[o_sh]) < 10, "orthographic: the sun's shadow falls where the geometry puts it")
    # a stage that turns depth back into world positions, in both projections: the ball's top (y up to 1.2) is white,
    # the floor black
    var rw = ArenaRendererOf[DefaultPasses, Stage[WorldHeight]](device, format, persp)
    for k in range(2):
        var vw = persp.copy() if k == 0 else iso.copy()
        rw.begin(vw.copy())
        scene(rw, False)
        rw.draw(device, target.handle().raw, W, H, hud)
        var fw = read(device, cap, target.handle().raw, Int(W), Int(H))
        # the red box's front face (z = 1): 1.5 m up is white, 0.3 m up is black
        var ot = at(vw, _v(-2.5, 1.5, 1.0))
        var ol = at(vw, _v(-2.5, 0.3, 1.0))
        print("world height stage,", "perspective" if k == 0 else "orthographic", ": the box's face 1.5 m up", Int(fw[ot]), ", 0.3 m up", Int(fw[ol]))
        s.check(Int(fw[ot]) > 200 and Int(fw[ol]) < 50, ("perspective" if k == 0 else "orthographic") + ": world_at puts a point 1.5 m up above 0.6 m and one 0.3 m up below")

    # ---- culling: the same frame, fewer items
    for k in range(2):
        var v = persp.copy() if k == 0 else iso.copy()
        var name = "perspective" if k == 0 else "orthographic"
        r.set_lights(device, [PointLight(_v(-2, 3, 3), 12.0, _v(1, 0.8, 0.6), 1.0, True)])
        r.cull = False
        r.begin(v.copy())
        scene(r, True)
        r.draw(device, target.handle().raw, W, H, hud)
        var all = read(device, cap, target.handle().raw, Int(W), Int(H))
        r.cull = True
        r.begin(v.copy())
        scene(r, True)
        r.draw(device, target.handle().raw, W, H, hud)
        var some = read(device, cap, target.handle().raw, Int(W), Int(H))
        print("culling,", name, ": dropped", r.culled, "of 305 items; pixels that differ:", diff(all, some))
        s.eqi(diff(all, some), 0, name + ": the culled frame is the whole frame, pixel for pixel")
        s.check(r.culled > 150, name + ": more than half the items are dropped")
    r.cull = False
    r.set_lights(device, List[PointLight]())
    # a tall box 30 m to the side is outside the view. Its shadow, followed 100 m, crosses the view; a lamp that casts
    # shadows and reaches it keeps it too. With neither it is dropped.
    var bounds = MeshBounds()
    var tall = DrawItem(0, _v(30, 6, 2), 0.0, 0.0, 0.0, 1.0, _v(2, 12, 2), _v(1, 1, 1), r.cube, -1, MAT_COLOR)
    var sun = _v(0.4 / 1.2328828, 1.0 / 1.2328828, 0.6 / 1.2328828)
    var with_sun = visible_items([tall.copy()], persp, r.meshes, bounds, ShadowReach(True, sun, 100.0, List[Vec3]()))
    var no_sun = visible_items([tall.copy()], persp, r.meshes, bounds, ShadowReach(False, sun, 100.0, List[Vec3]()))
    var lamp = visible_items([tall.copy()], persp, r.meshes, bounds, ShadowReach(False, sun, 100.0, [Vec3(Real(24), Real(3), Real(2), Real(8))]))
    print("a tall box at x = 30, outside the view: kept with the sun's shadow on", len(with_sun), ", off", len(no_sun), ", within a shadow-casting lamp's range", len(lamp))
    s.check(len(with_sun) == 1 and len(no_sun) == 0 and len(lamp) == 1, "an item outside the view is kept only while its shadow can reach in")
    s.check(capsule_outside(persp, _v(0, 1, 30), _v(0, 1, 30), 1.0) and not capsule_outside(persp, _v(0, 1, 30), _v(0, 1, -5), 1.0), "a sphere behind the camera is outside; swept to in front of it, it is not")

    # ---- viewports
    for nviews in [2, 4]:
        var rects = split_rects(nviews, Int(W), Int(H))
        var split = SplitScreen(device, format, W, H, rects.copy())
        var eyes = [_v(0, 1, 5), _v(6, 3, 6), _v(-6, 2, 4), _v(0, 9, 0.5)]
        var alone = List[List[UInt8]]()
        var held = List[Texture]()  # the textures drawn alone, kept until the loop is over
        for i in range(nviews):
            var a = split.aspect(i)
            var vi = View(pose(eyes[i], _v(0, 1, 0), a), Real(a))
            # alone, into a texture of the rectangle's size
            held.append(device.create_texture(split.width(i), split.height(i), 1, format, usage, label="alone"))
            var c = FrameCapture(device, split.width(i), split.height(i))
            r.begin(vi.copy())
            scene(r, False)
            r.draw(device, held[i].handle().raw, split.width(i), split.height(i), hud)
            alone.append(read(device, c, held[i].handle().raw, rects[i].w, rects[i].h))
            # and into the split's texture
            r.begin(vi.copy())
            scene(r, False)
            r.draw(device, split.target(i), split.width(i), split.height(i), hud)
        split.compose(device, target.handle().raw, hud)
        var whole = read(device, cap, target.handle().raw, Int(W), Int(H))
        var wrong = 0
        for i in range(nviews):
            for y in range(rects[i].h):
                for x in range(rects[i].w):
                    var a = (y * rects[i].w + x) * 4
                    var b = ((rects[i].y + y) * Int(W) + rects[i].x + x) * 4
                    if alone[i][a] != whole[b] or alone[i][a + 1] != whole[b + 1] or alone[i][a + 2] != whole[b + 2]:
                        wrong += 1
        print(nviews, "views composed: pixels that differ from the views drawn alone:", wrong)
        s.eqi(wrong, 0, String(nviews) + " views: every rectangle is its view drawn alone")
        s.check(diff(alone[0], alone[1]) > 2000, String(nviews) + " views: the views are different pictures")
        s.eqi(len(held), nviews, "the textures drawn alone outlive the loop")
    # a picture in a picture: the second rectangle lies over the first
    var pip = SplitScreen(device, format, W, H, [Rect(0, 0, Int(W), Int(H)), Rect(300, 20, 160, 90)])
    s.eqi(pip.count(), 2, "a rectangle inside another is accepted")
    var bad = False
    try:
        var b = SplitScreen(device, format, W, H, [Rect(400, 0, 200, 100)])
        _ = b.count()
    except e:
        bad = True
    s.check(bad, "a rectangle outside the frame is refused")
    s.finish()
