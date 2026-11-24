# tier: integration
# The accessibility stages (app/access_post.mojo) and the reduce-motion flag on the GPU (lavapipe), each against the CPU model in
# game/access_filters.mojo, pixel by pixel on a frame of the scene renderer (ludens-engine #118).
#   colour-blind    five coloured boxes; for each kind and for simulation and correction the stage's frame is compared with the
#                   CPU function applied to the unfiltered frame's pixels; kind off and strength 0 are pixel-identical to it.
#   flash limiter   a full-frame box that is dark, then bright, then dark ... each limited frame is compared with
#                   `flash_limit(previous limited frame, unlimited frame)`; the mean luminance series is counted with `flash_count`.
#   reduce motion   a lens with a blur circle and an open shutter gives a different frame; with `reduce_motion` it gives the
#                   unfiltered frame, pixel for pixel.
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from game.access import Access
from game.access_filters import Rgb, colorblind_apply, flash_count, flash_limit, luminance
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect, Stage, ThenPost, History
from app.access_post import AccessPost, ColorBlind, FlashLimit
from app.lens import DepthOfField, MotionBlur

comptime W: UInt32 = 320
comptime H: UInt32 = 180


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


def color_scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A]):
    """Five boxes of different hue side by side, 6 m in front of a camera at the origin looking along -z."""
    var colors = [_v(0.85, 0.12, 0.10), _v(0.15, 0.70, 0.15), _v(0.12, 0.25, 0.85), _v(0.90, 0.80, 0.10), _v(0.5, 0.5, 0.5)]
    for i in range(5):
        r.push(DrawItem(0, _v(-4.0 + 2.0 * Float64(i), 0, -6.0), 0.0, 0.0, 0.0, 1.0, _v(1.6, 2.4, 1.0), colors[i], r.cube, -1, MAT_COLOR))


def flash_scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], level: Float64):
    """One box that covers the whole frame, of the given grey."""
    r.push(DrawItem(0, _v(0, 0, -3.0), 0.0, 0.0, 0.0, 1.0, _v(40, 40, 1), _v(level, level, level), r.cube, -1, MAT_COLOR))


def px(buf: List[UInt8], i: Int) -> Rgb:
    return Rgb(Float32(Int(buf[4 * i])) / 255.0, Float32(Int(buf[4 * i + 1])) / 255.0, Float32(Int(buf[4 * i + 2])) / 255.0, 1.0)


def diff_pixels(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def mean_luminance(buf: List[UInt8]) -> Float32:
    var sum = Float64(0.0)
    var n = len(buf) // 4
    for i in range(n):
        sum += Float64(luminance(px(buf, i)))
    return Float32(sum / Float64(n))


def main() raises:
    var s = Suite("access_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="access")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Real(Float32(W) / Float32(H))
    var view = View(CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)

    # ---- colour-blind stage
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    plain.begin(view.copy())
    color_scene(plain)
    plain.draw(device, target.handle().raw, W, H, hud)
    var base = read(device, cap, target.handle().raw)
    var cb = SceneRendererOf[DefaultPasses, Stage[ColorBlind]](device, format, view)
    var names = ["off", "protanopia", "deuteranopia", "tritanopia"]
    for kind in range(4):
        for mode in range(2):  # 0 correct, 1 simulate
            for strength in [Float32(1.0), Float32(0.5)]:
                if kind == 0 and (mode == 1 or strength != 1.0):
                    continue
                cb.post_user = SIMD[DType.float32, 4](Float32(kind), strength, Float32(mode), 0.0)
                cb.begin(view.copy())
                color_scene(cb)
                cb.draw(device, target.handle().raw, W, H, hud)
                var got = read(device, cap, target.handle().raw)
                var worst = 0
                var off_by_more_than_1 = 0
                var changed = 0
                for i in range(Int(W) * Int(H)):
                    var want = colorblind_apply(kind, mode == 1, strength, px(base, i))
                    for ch in range(3):
                        var w = Int(want[ch] * 255.0 + 0.5)
                        var d = abs(Int(got[4 * i + ch]) - w)
                        worst = max(worst, d)
                        if d > 1:
                            off_by_more_than_1 += 1
                    if got[4 * i] != base[4 * i] or got[4 * i + 1] != base[4 * i + 1] or got[4 * i + 2] != base[4 * i + 2]:
                        changed += 1
                var label = names[kind] + (" simulate" if mode == 1 else " correct") + " strength " + String(strength)
                print(label, ": pixels changed from the unfiltered frame", changed, "of", Int(W) * Int(H), "; largest difference from the CPU model", worst, "of 255 ;", off_by_more_than_1, "channel values off by more than 1")
                if kind == 0:
                    s.eqi(diff_pixels(base, got), 0, "kind off: the frame is unchanged, pixel for pixel")
                else:
                    s.check(worst <= 2, label + ": every channel within 2 of 255 of the CPU model")
                    s.check(changed > 500, label + ": the boxes' pixels changed (" + String(changed) + ")")
    cb.post_user = SIMD[DType.float32, 4](2.0, 0.0, 1.0, 0.0)
    cb.begin(view.copy())
    color_scene(cb)
    cb.draw(device, target.handle().raw, W, H, hud)
    s.eqi(diff_pixels(base, read(device, cap, target.handle().raw)), 0, "strength 0: the frame is unchanged, pixel for pixel")

    # ---- flash limiter on a synthetic flashing scene
    var flash = SceneRendererOf[DefaultPasses, History[Stage[FlashLimit]]](device, format, view)
    var raw_r = SceneRendererOf[DefaultPasses](device, format, view)
    var step = Float32(0.02)
    flash.post_user = SIMD[DType.float32, 4](0.0, 0.0, 0.0, step)
    var raw_series = List[Float32]()
    var out_series = List[Float32]()
    var prev_out = List[UInt8]()
    var worst_model = 0
    var worst_step = Float32(0.0)
    var last_mean = Float32(-1.0)
    for f in range(30):
        var level = 0.9 if (f // 2) % 2 == 0 else 0.03  # two frames bright, two frames dark: 15 flashes a second at 60 fps
        raw_r.begin(view.copy())
        flash_scene(raw_r, level)
        raw_r.draw(device, target.handle().raw, W, H, hud)
        var cur = read(device, cap, target.handle().raw)
        flash.begin(view.copy())
        flash_scene(flash, level)
        flash.draw(device, target.handle().raw, W, H, hud)
        var out = read(device, cap, target.handle().raw)
        raw_series.append(mean_luminance(cur))
        out_series.append(mean_luminance(out))
        if f == 0:
            s.eqi(diff_pixels(cur, out), 0, "the first frame passes through unchanged")
        else:
            for i in range(0, Int(W) * Int(H), 7):
                var want = flash_limit(px(prev_out, i), px(cur, i), step)
                for ch in range(3):
                    worst_model = max(worst_model, abs(Int(out[4 * i + ch]) - Int(want[ch] * 255.0 + 0.5)))
            var d = out_series[f] - out_series[f - 1]
            worst_step = max(worst_step, d if d >= 0.0 else -d)
        prev_out = out^
    var raw_flashes = flash_count(raw_series, 0.1, 60)
    var out_flashes = flash_count(out_series, 0.1, 60)
    print("synthetic flashing scene, 30 frames, 2 bright / 2 dark: mean luminance range", raw_series[0], "/", raw_series[2], "; flashes a second:", raw_flashes, "->", out_flashes, "; largest frame step of the mean:", worst_step, "(limit", step, "); largest difference from the CPU model:", worst_model, "of 255")
    s.check(raw_flashes > 3, "the unlimited scene fails the 3 flashes a second rule (" + String(raw_flashes) + ")")
    s.check(out_flashes <= 3, "the limited scene has at most 3 (" + String(out_flashes) + ")")
    s.check(worst_model <= 2, "each limited frame is within 2 of 255 of flash_limit(previous limited frame, unlimited frame)")
    s.check(worst_step <= step + 0.5 / 255.0 + 1e-4, "the mean luminance moves by at most the step (+ half an 8-bit level): " + String(worst_step))
    # limiter off (step 0) gives the unlimited frame back
    flash.post_user = SIMD[DType.float32, 4](0.0, 0.0, 0.0, 0.0)
    for f in range(3):
        raw_r.begin(view.copy())
        flash_scene(raw_r, 0.9 if f % 2 == 0 else 0.03)
        raw_r.draw(device, target.handle().raw, W, H, hud)
        var cur = read(device, cap, target.handle().raw)
        flash.begin(view.copy())
        flash_scene(flash, 0.9 if f % 2 == 0 else 0.03)
        flash.draw(device, target.handle().raw, W, H, hud)
        s.eqi(diff_pixels(cur, read(device, cap, target.handle().raw)), 0, "limit 0: frame " + String(f) + " is the unlimited frame")

    # ---- both stages together, everything off: the plain frame
    var both = SceneRendererOf[DefaultPasses, AccessPost](device, format, view)
    var access = Access()
    both.post_user = access.post_user(1.0 / 60.0)
    both.begin(view.copy())
    color_scene(both)
    both.draw(device, target.handle().raw, W, H, hud)
    s.eqi(diff_pixels(base, read(device, cap, target.handle().raw)), 0, "AccessPost with every setting at its default: the frame is unchanged")
    access.set("colorblind", "protanopia")
    access.set("flash_limit", "on")
    both.post_user = access.post_user(1.0 / 60.0)
    both.begin(view.copy())
    color_scene(both)
    both.draw(device, target.handle().raw, W, H, hud)
    var one = read(device, cap, target.handle().raw)
    # the previous frame was the same picture, so the limiter has nothing to limit: the result is the correction alone
    var worst_both = 0
    for i in range(Int(W) * Int(H)):
        var want = colorblind_apply(1, False, 1.0, px(base, i))
        for ch in range(3):
            worst_both = max(worst_both, abs(Int(one[4 * i + ch]) - Int(want[ch] * 255.0 + 0.5)))
    s.check(worst_both <= 2, "AccessPost with correction and the limiter on, nothing to limit: within 2 of 255 of the CPU correction (" + String(worst_both) + ")")
    s.check(diff_pixels(base, one) > 500, "AccessPost with protanopia correction and the limiter on changes the boxes")

    # ---- reduce motion
    var lens = SceneRendererOf[DefaultPasses, ThenPost[Stage[MotionBlur], Stage[DepthOfField]]](device, format, view)
    lens.lens_sensor = 0.15
    lens.lens_focus = 6.0
    lens.lens_max_coc = 40.0
    lens.lens_fstop = 0.7
    lens.shutter = 1.0
    var turned = View(CameraPose(_v(0, 0, 0), look_rotation(_v(-0.05, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)
    var frames = List[List[UInt8]]()
    for flag in range(2):
        lens.reduce_motion = flag == 1
        lens.begin(turned.copy())
        color_scene(lens)
        lens.draw(device, target.handle().raw, W, H, hud)
        lens.begin(view.copy())
        color_scene(lens)
        lens.draw(device, target.handle().raw, W, H, hud)
        frames.append(read(device, cap, target.handle().raw))
    var n_blur = diff_pixels(base, frames[0])
    var n_reduced = diff_pixels(base, frames[1])
    print("camera turned between two frames, f/0.7 and an open shutter: pixels that differ from the unfiltered frame:", n_blur, "; with reduce motion:", n_reduced)
    s.check(n_blur > 1000, "without the flag the lens stages change the frame (" + String(n_blur) + " pixels)")
    s.eqi(n_reduced, 0, "with reduce motion the frame is the unfiltered frame, pixel for pixel")
    s.check(target.handle().raw == target.handle().raw, "the target is alive until here")
    s.finish()
