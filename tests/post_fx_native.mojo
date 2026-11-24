# tier: integration
# Anti-aliasing, bloom and colour grading (app/post_fx.mojo, issue #139), each against a number, on native wgpu (lavapipe).
#   FXAA      a fixed scene of dark boxes with slanted edges against the sky. The error of the frame against the same scene
#             drawn at 4 x 4 the size and box-filtered down (the reference), over the pixels that lie on an edge of the
#             reference: mean absolute channel difference, in levels of 255. With the filter the error is lower.
#   bloom     a bright box on a dark wall. Energy above the threshold appears outside the box, falls off with distance
#             over tens of pixels (the mip chain), doubles with the intensity; with the intensity at 0, or with the threshold
#             above the box's brightness, the frame is the frame without the stage, pixel for pixel.
#   grade     every one of the 256 ^ 3 inputs through a size-16 neutral table comes out as it went in; a graded table
#             gives what the same table gives when read on the CPU, within one level.
#   cost      the frame time at 1920 x 1080 of each effect added to the same scene (printed; lavapipe is a CPU rasteriser,
#             so these are not GPU times).
# `post_fx_native --dump DIR` writes the frames of the AA comparison as DIR/*.rgba (320 x 180).
from std.math import sqrt, sin, cos
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.texture import Texture
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList, Color
from ui.geom import Rect
from app.render_res import RenderCaps
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect, Stage, ThenPost, Style
from app.post_fx import Fxaa, Bloom, Grade, neutral_lut, graded_lut, lut_lookup

comptime W: UInt32 = 320
comptime H: UInt32 = 180


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)


def read(device: Device, mut cap: FrameCapture, tex: WGPUTextureHandle, w: UInt32, h: UInt32) raises -> List[UInt8]:
    var req = cap.capture(device, tex)
    req.wait()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(w))
    var out = List[UInt8]()
    for y in range(Int(h)):
        for x in range(Int(w) * 4):
            out.append(p[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


struct Rig(Movable):
    """A target, its read-back and an empty HUD at one size."""

    var w: UInt32
    var h: UInt32
    var target: Texture
    var cap: FrameCapture
    var hud: Hud

    def __init__(out self, device: Device, format: UInt32, w: UInt32, h: UInt32) raises:
        self.w = w
        self.h = h
        self.target = device.create_texture(
            w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="post_fx_target",
        )
        self.cap = FrameCapture(device, w, h)
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(w), Float32(h))

    def __init__(out self, *, deinit move: Self):
        self.w = move.w
        self.h = move.h
        self.target = move.target^
        self.cap = move.cap^
        self.hud = move.hud^

    def shoot[P: RenderPass, F: PostEffect, A: AuxTarget](
        mut self, device: Device, mut r: SceneRendererOf[P, F, A], which: Int,
    ) raises -> List[UInt8]:
        r.begin(view_for(self.w, self.h))
        scene(r, which)
        r.draw(device, self.target.handle().raw, self.w, self.h, self.hud)
        return read(device, self.cap, self.target.handle().raw, self.w, self.h)


comptime SCENE_EDGES = 0  # dark boxes with slanted edges against the sky
comptime SCENE_GLOW = 1  # a bright box on a dark wall
comptime SCENE_DIM = 2  # the same box, dim


def _quat_z(a: Float64) -> List[Float64]:
    return [0.0, 0.0, sin(a * 0.5), cos(a * 0.5)]


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], which: Int):
    if which == SCENE_EDGES:
        var q = _quat_z(0.52)
        r.push(DrawItem(0, _v(-1.4, 0.2, -6), 0.0, 0.0, q[2], q[3], _v(1.2, 0.8, 1), _v(0.05, 0.05, 0.05), r.cube, -1, MAT_COLOR))
        var q2 = _quat_z(-0.2)
        r.push(DrawItem(0, _v(1.5, -0.3, -7), 0.0, 0.0, q2[2], q2[3], _v(1.4, 0.5, 1), _v(0.6, 0.05, 0.05), r.cube, -1, MAT_COLOR))
        r.push(DrawItem(1, _v(0.2, 0.9, -5), 0.0, 0.0, 0.0, 1.0, _v(0.7, 0.7, 0.7), _v(0.1, 0.2, 0.6), r.sphere, -1, MAT_COLOR))
    else:
        r.push(DrawItem(0, _v(0, 0, -30), 0.0, 0.0, 0.0, 1.0, _v(60, 40, 1), _v(0.02, 0.02, 0.02), r.cube, -1, MAT_COLOR))
        var c = 1.0 if which == SCENE_GLOW else 0.25
        r.push(DrawItem(0, _v(0, 0, -6), 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(c, c, c), r.cube, -1, MAT_COLOR))


def lum(px: List[UInt8], w: Int, x: Int, y: Int) -> Float64:
    var o = (y * w + x) * 4
    return (Float64(Int(px[o])) + Float64(Int(px[o + 1])) + Float64(Int(px[o + 2]))) / 3.0


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def box_down(px: List[UInt8], w: Int, h: Int, k: Int) -> List[UInt8]:
    """The frame of w * k by h * k pixels averaged k * k to one (the supersampled reference)."""
    var out = List[UInt8]()
    for y in range(h):
        for x in range(w):
            for c in range(4):
                var sum = 0
                for j in range(k):
                    for i in range(k):
                        sum += Int(px[((y * k + j) * w * k + x * k + i) * 4 + c])
                out.append(UInt8((sum + k * k // 2) // (k * k)))
    return out^


def on_edge(truth: List[UInt8], w: Int, h: Int, x: Int, y: Int, level: Float64 = 8.0) -> Bool:
    """The reference's luma range over the 3 x 3 block around (x, y) is above `level` levels."""
    var lo = 255.0
    var hi = 0.0
    for j in range(-1, 2):
        for i in range(-1, 2):
            var xx = min(max(x + i, 0), w - 1)
            var yy = min(max(y + j, 0), h - 1)
            var l = lum(truth, w, xx, yy)
            lo = min(lo, l)
            hi = max(hi, l)
    return hi - lo > level


def edge_error(img: List[UInt8], truth: List[UInt8], w: Int, h: Int) -> Float64:
    """Mean absolute channel difference (levels of 255) over the pixels on an edge of the reference."""
    var sum = 0.0
    var n = 0
    for y in range(h):
        for x in range(w):
            if on_edge(truth, w, h, x, y):
                n += 1
                for c in range(3):
                    sum += abs(Float64(Int(img[(y * w + x) * 4 + c])) - Float64(Int(truth[(y * w + x) * 4 + c])))
    return sum / Float64(max(n, 1) * 3)


def edge_count(truth: List[UInt8], w: Int, h: Int) -> Int:
    var n = 0
    for y in range(h):
        for x in range(w):
            if on_edge(truth, w, h, x, y):
                n += 1
    return n


def far_change(a: List[UInt8], b: List[UInt8], truth: List[UInt8], w: Int, h: Int) -> Int:
    """Pixels farther than 2 pixels from any edge of the reference (a luma step of more than 2 levels) whose colour differs
    between a and b."""
    var n = 0
    for y in range(h):
        for x in range(w):
            var near = False
            for j in range(-2, 3):
                for i in range(-2, 3):
                    if on_edge(truth, w, h, min(max(x + i, 0), w - 1), min(max(y + j, 0), h - 1), 2.0):
                        near = True
            if not near:
                var o = (y * w + x) * 4
                if a[o] != b[o] or a[o + 1] != b[o + 1] or a[o + 2] != b[o + 2]:
                    n += 1
    return n


def write_rgba(path: String, px: List[UInt8]) raises:
    var f = open(path, "w")
    f.write_bytes(px)
    f.close()


# ---- the ramp: a frame whose pixel (x, y) is (x, y, b) in levels, for the exhaustive LUT check

struct Ramp(Style):
    comptime NAME: StaticString = "ramp"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(floor(px.x), floor(px.y), frame.user.x) / 255.0;
}
"""


struct ZDump(Style):
    comptime NAME: StaticString = "zdump"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(view_z(uv) / 100.0);
}
"""


def msaa_caps() -> RenderCaps:
    var c = RenderCaps.default()
    c.samples = 4
    return c


def main() raises:
    var s = Suite("post_fx_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var dump = String("")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dump = String(args[i + 1])
    var view = view_for(W, H)

    # ---- anti-aliasing: the error against a 4 x 4 supersampled reference, over the reference's edges
    var big = Rig(device, format, W * 4, H * 4)
    var small = Rig(device, format, W, H)
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    var hires = SceneRendererOf[DefaultPasses](device, format, view_for(W * 4, H * 4))
    var truth = box_down(big.shoot(device, hires, SCENE_EDGES), Int(W), Int(H), 4)
    var none = small.shoot(device, plain, SCENE_EDGES)
    var fx = SceneRendererOf[DefaultPasses, Fxaa](device, format, view)
    var filtered = small.shoot(device, fx, SCENE_EDGES)
    var e_none = edge_error(none, truth, Int(W), Int(H))
    var e_fxaa = edge_error(filtered, truth, Int(W), Int(H))
    var n_edge = edge_count(truth, Int(W), Int(H))
    print("edge pixels of the reference:", n_edge, "of", Int(W * H))
    print("edge error, no filter:", e_none, "levels ; FXAA:", e_fxaa, "levels ; reduction to", e_fxaa / e_none)
    s.check(n_edge > 400, "the scene has edges to measure")
    s.check(e_fxaa < 0.8 * e_none, "FXAA lowers the edge error against the supersampled reference by at least 20 %")
    var far = far_change(none, filtered, truth, Int(W), Int(H))
    print("pixels farther than 2 px from an edge that FXAA changed:", far)
    s.eqi(far, 0, "FXAA leaves the flat areas alone")
    fx.fxaa_strength = 0.0
    s.eqi(diff(none, small.shoot(device, fx, SCENE_EDGES)), 0, "strength 0: the frame without the stage, pixel for pixel")
    if dump.byte_length() > 0:
        write_rgba(dump + "/edges_none.rgba", none)
        write_rgba(dump + "/edges_fxaa.rgba", filtered)
        write_rgba(dump + "/edges_ref.rgba", truth)

    # ---- MSAA 4x: the same error measure; flat areas as without; the HUD on top; depth for the stages
    var ms = SceneRendererOf[DefaultPasses](device, format, view, caps=msaa_caps())
    var multi = small.shoot(device, ms, SCENE_EDGES)
    var e_msaa = edge_error(multi, truth, Int(W), Int(H))
    print("edge error, MSAA 4x:", e_msaa, "levels ; reduction to", e_msaa / e_none)
    s.check(e_msaa < 0.5 * e_none, "MSAA 4x lowers the edge error against the supersampled reference by at least half")
    s.check(e_msaa < e_fxaa, "and by more than FXAA does")
    var far_ms = far_change(none, multi, truth, Int(W), Int(H))
    print("pixels farther than 2 px from an edge that MSAA changed:", far_ms)
    s.eqi(far_ms, 0, "MSAA leaves the flat areas alone")
    if dump.byte_length() > 0:
        write_rgba(dump + "/edges_msaa.rgba", multi)
    var one = SceneRendererOf[DefaultPasses](device, format, view, caps=RenderCaps.default())
    s.eqi(diff(none, small.shoot(device, one, SCENE_EDGES)), 0, "samples 1 (the default) is the frame as before")
    var hud_rig = Rig(device, format, W, H)
    var dl = DrawList()
    dl.fill(Rect(10.0, 10.0, 60.0, 30.0), Color.rgb(1.0, 0.0, 1.0))
    hud_rig.hud.set(dl, Float32(W), Float32(H))
    var with_hud = hud_rig.shoot(device, ms, SCENE_EDGES)
    var o_hud = (20 * Int(W) + 20) * 4
    print("HUD pixel with MSAA:", Int(with_hud[o_hud]), Int(with_hud[o_hud + 1]), Int(with_hud[o_hud + 2]))
    s.check(with_hud[o_hud] > 200 and with_hud[o_hud + 1] < 40 and with_hud[o_hud + 2] > 200, "the HUD is drawn over the resolved frame")
    comptime ZFrame = ThenPost[Stage[ZDump], Fxaa]
    var z1 = SceneRendererOf[DefaultPasses, ZFrame](device, format, view)
    var z4 = SceneRendererOf[DefaultPasses, ZFrame](device, format, view, caps=msaa_caps())
    z1.fxaa_strength = 0.0
    z4.fxaa_strength = 0.0
    var depth1 = small.shoot(device, z1, SCENE_EDGES)
    var depth4 = small.shoot(device, z4, SCENE_EDGES)
    var zfar = far_change(depth1, depth4, truth, Int(W), Int(H))
    var zmid = lum(depth4, Int(W), Int(W) // 2, Int(H) // 2 + 60)
    print("stages' depth with MSAA: pixels away from edges that differ from the one-sample depth:", zfar, "; sample value", zmid)
    s.eqi(zfar, 0, "the stages read the same depth with MSAA as without, away from edges")
    s.check(lum(depth4, Int(W), 5, 5) > 0.0 or zmid > 0.0, "(the depth frame is not all black)")
    var both = SceneRendererOf[DefaultPasses, Fxaa](device, format, view, caps=msaa_caps())
    both.fxaa_strength = 0.0
    var through = small.shoot(device, both, SCENE_EDGES)
    s.eqi(diff(multi, through), 0, "MSAA through a stage (here FXAA at strength 0): the same frame as MSAA drawn straight to the target")
    both.fxaa_strength = 1.0
    var e_both = edge_error(small.shoot(device, both, SCENE_EDGES), truth, Int(W), Int(H))
    print("edge error, MSAA 4x then FXAA:", e_both, "levels (FXAA moves edges the resolve already placed: worse than MSAA alone)")
    s.check(e_both > e_msaa, "FXAA on top of MSAA is not an improvement: use one of the two")

    # ---- bloom
    var base = SceneRendererOf[DefaultPasses](device, format, view)
    var glow_plain = small.shoot(device, base, SCENE_GLOW)
    var box_l = lum(glow_plain, Int(W), Int(W) // 2, Int(H) // 2)
    var wall_l = lum(glow_plain, Int(W), 4, 4)
    print("box brightness", box_l, "wall brightness", wall_l)
    var b = SceneRendererOf[DefaultPasses, Bloom](device, format, view)
    b.bloom_threshold = Float32(0.5 * box_l / 255.0)
    b.bloom_intensity = 1.0
    var glow = small.shoot(device, b, SCENE_GLOW)
    # the box covers x in [cx - hw, cx + hw]: find its edge on the middle row
    var row = Int(H) // 2
    var cx = Int(W) // 2
    var hw = 0
    while hw < Int(W) // 2 and lum(glow_plain, Int(W), cx + hw, row) > 0.5 * (box_l + wall_l):
        hw += 1
    print("the box is", hw * 2, "pixels wide")
    var added_at = List[Float64]()
    for d in [2, 6, 12, 24, 48]:
        added_at.append(lum(glow, Int(W), cx + hw + d, row) - lum(glow_plain, Int(W), cx + hw + d, row))
    print("brightness added at 2, 6, 12, 24, 48 px from the box's edge:", added_at[0], added_at[1], added_at[2], added_at[3], added_at[4])
    s.check(added_at[0] > 8.0, "energy above the threshold shows beside the box (more than 8 levels at 2 px)")
    s.check(added_at[0] > added_at[1] and added_at[1] > added_at[2] and added_at[2] > added_at[3], "and falls off with distance")
    s.check(added_at[3] >= 1.0, "reaching 24 px: the mip chain spreads it past a single blur")
    s.check(added_at[4] < added_at[2], "less at 48 px than at 12 px")
    # the energy the prefilter takes (the stage's own cut, here on the CPU) against the energy the stage added
    var thr = Float64(b.bloom_threshold)
    var predicted = 0.0
    for y in range(Int(H)):
        for x in range(Int(W)):
            var o = (y * Int(W) + x) * 4
            var l = Float64(max(glow_plain[o], max(glow_plain[o + 1], glow_plain[o + 2]))) / 255.0
            var soft = min(max(l - thr + 0.1, 0.0), 0.2)
            soft = soft * soft / 0.4
            var w = max(soft, l - thr) / max(l, 1e-4)
            predicted += w * lum(glow_plain, Int(W), x, y)
    var energy = 0.0
    var energy_out = 0.0
    for y in range(Int(H)):
        for x in range(Int(W)):
            var d = lum(glow, Int(W), x, y) - lum(glow_plain, Int(W), x, y)
            energy += d
            if abs(x - cx) > hw + 1 or abs(y - row) > hw + 1:
                energy_out += d
    print("energy above the threshold:", predicted, "level-pixels ; added by the stage:", energy, "(ratio", energy / predicted, ") of which outside the box:", energy_out)
    s.check(energy / predicted > 0.8 and energy / predicted < 1.05, "intensity 1 adds back the energy above the threshold (0.8 to 1.05 of it: 8-bit levels round the faint tails)")
    s.check(energy_out > 0.1 * energy, "at least a tenth of it lies outside the box")
    b.bloom_intensity = 0.5
    var half = small.shoot(device, b, SCENE_GLOW)
    var energy_half = 0.0
    for y in range(Int(H)):
        for x in range(Int(W)):
            energy_half += lum(half, Int(W), x, y) - lum(glow_plain, Int(W), x, y)
    print("half the intensity: energy added", energy_half, "against", energy, ": ratio", energy_half / energy)
    s.check(energy_half / energy > 0.45 and energy_half / energy < 0.55, "half the intensity adds half the energy (0.45 to 0.55)")
    b.bloom_intensity = 0.0
    s.eqi(diff(glow_plain, small.shoot(device, b, SCENE_GLOW)), 0, "intensity 0: the frame without the stage, pixel for pixel")
    b.bloom_intensity = 1.0
    b.bloom_threshold = 1.0
    s.eqi(diff(glow_plain, small.shoot(device, b, SCENE_GLOW)), 0, "threshold above the brightest pixel: the frame without the stage")
    b.bloom_threshold = Float32(0.5 * box_l / 255.0)
    var dim_plain = small.shoot(device, base, SCENE_DIM)
    var dim = small.shoot(device, b, SCENE_DIM)
    var dim_l = lum(dim_plain, Int(W), cx, row)
    print("the dim box is", dim_l, "against a threshold of", Float64(b.bloom_threshold) * 255.0, "(knee 0.1 below it)")
    s.check(dim_l < (Float64(b.bloom_threshold) - 0.1) * 255.0, "(the dim box lies below threshold minus knee)")
    s.eqi(diff(dim_plain, dim), 0, "a box below the threshold gives no glow")

    # ---- grading: all 2^24 inputs through the neutral table, then a graded one against the CPU reading of it
    var ramp = Rig(device, format, 256, 256)
    comptime RampLut = ThenPost[Stage[Ramp], Grade]
    var g = SceneRendererOf[DefaultPasses, RampLut](device, format, view_for(256, 256))
    g.set_lut(device, 16, neutral_lut(16))
    var wrong = 0
    for blue in range(256):
        g.post_user = SIMD[DType.float32, 4](Float32(blue), 0.0, 0.0, 0.0)
        var out = ramp.shoot(device, g, SCENE_EDGES)
        for y in range(256):
            for x in range(256):
                var o = (y * 256 + x) * 4
                if Int(out[o]) != x or Int(out[o + 1]) != y or Int(out[o + 2]) != blue:
                    wrong += 1
    print("neutral table, size 16: inputs that changed, of 16777216:", wrong)
    s.eqi(wrong, 0, "a neutral table returns all 2^24 inputs unchanged")
    var lut = graded_lut(16, 0.8, 1.2, 0.7)
    g.set_lut(device, 16, lut.copy())
    var worst = 0.0
    var changed = 0
    for blue in [0, 1, 17, 64, 100, 180, 254, 255]:
        g.post_user = SIMD[DType.float32, 4](Float32(blue), 0.0, 0.0, 0.0)
        var out = ramp.shoot(device, g, SCENE_EDGES)
        for y in range(0, 256, 3):
            for x in range(0, 256, 3):
                var want = lut_lookup(lut, 16, x, y, blue)
                var o = (y * 256 + x) * 4
                for c in range(3):
                    worst = max(worst, abs(Float64(Int(out[o + c])) - want[c]))
                if Int(out[o]) != x or Int(out[o + 1]) != y or Int(out[o + 2]) != blue:
                    changed += 1
    print("graded table: largest difference from the CPU reading", worst, "levels ;", changed, "of", 8 * 86 * 86, "sampled inputs changed")
    s.check(worst <= 1.0, "a graded table: the stage gives the table's value within one level")
    s.check(changed > 8 * 86 * 86 // 2, "and the grade changes most colours")
    g.lut_amount = 0.0
    g.post_user = SIMD[DType.float32, 4](Float32(100.0), 0.0, 0.0, 0.0)
    var o0 = ramp.shoot(device, g, SCENE_EDGES)
    var kept = 0
    for y in range(256):
        for x in range(256):
            var o = (y * 256 + x) * 4
            if Int(o0[o]) == x and Int(o0[o + 1]) == y and Int(o0[o + 2]) == 100:
                kept += 1
    s.eqi(kept, 256 * 256, "amount 0: the frame without the grade")

    # ---- the three together, everything off: the frame as drawn
    comptime Look = ThenPost[Fxaa, ThenPost[Bloom, Grade]]
    var all = SceneRendererOf[DefaultPasses, Look](device, format, view)
    all.fxaa_strength = 0.0
    all.bloom_intensity = 0.0
    all.lut_amount = 0.0
    s.eqi(diff(none, small.shoot(device, all, SCENE_EDGES)), 0, "FXAA, bloom and grade in one pipeline, all off: the frame as drawn")
    all.fxaa_strength = 1.0
    all.bloom_intensity = 0.0
    all.lut_amount = 1.0  # the default table is the neutral one
    s.eqi(diff(filtered, small.shoot(device, all, SCENE_EDGES)), 0, "with the default (neutral) table the pipeline equals FXAA alone")

    s.finish()
