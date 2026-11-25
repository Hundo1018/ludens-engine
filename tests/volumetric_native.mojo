# tier: integration
# The froxel volumetric fog (app/volumetric.mojo, issue #141), on native wgpu (lavapipe), 320 x 180:
#   off        with vol_density 0 the frame is the frame without the effect, pixel for pixel.
#   uniform    fog with no height falloff, isotropic phase, the default sun and ambient: a sky pixel (the view's far
#              end, so the ray crosses the whole grid) against the closed form colour * T + L / sigma * (1 - T), at
#              three densities, within 2 levels.
#   height     with a height falloff, a pixel looking up gets less fog than with none.
#   shafts     a roof over the left half of the volume and the sun's shadow on: the fog's added light on the left is
#              cut, on the right it is the same as with the shadow off.
#   point      a point light inside the fog brightens the pixels around it, not the corners.
#   cost       frame time at 1920 x 1080 with and without the effect (printed; lavapipe is a CPU rasteriser).
# `volumetric_native --dump DIR` writes the frames as DIR/vol_*.rgba (scripts/tier3_shots.py makes PNGs of them);
# `volumetric_native --cost` runs only the cost table.
from std.math import exp, sqrt, pi
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
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_res import PointLight
from app.render_pass import RenderPass, AuxTarget, Then
from app.shadow_pass import ShadowPass
from app.post import PostEffect, Stage, Copy
from app.lights import sun_shadow_vp
from app.volumetric import VolumetricFog, uniform_fog, volume_bytes

comptime Lit = Then[ShadowPass, DefaultPasses]
comptime W: UInt32 = 320
comptime H: UInt32 = 180


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32, pitch: Float64 = 0.0) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 1, 0), look_rotation(_v(0, pitch, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)


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


comptime SCENE_EMPTY = 0  # nothing: the sky (clear colour) everywhere
comptime SCENE_ROOF = 1  # a roof over x < 0 at 6 m
comptime SCENE_WALL = 2  # a dark wall 30 m away, and a pillar


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], which: Int):
    if which == SCENE_ROOF:
        r.push(DrawItem(0, _v(-40.0, 7.0, -40.0), 0.0, 0.0, 0.0, 1.0, _v(80.0, 2.0, 120.0), _v(0.2, 0.2, 0.2), r.cube, -1, MAT_COLOR))
        r.push(DrawItem(0, _v(0.0, -1.0, -40.0), 0.0, 0.0, 0.0, 1.0, _v(160.0, 1.0, 160.0), _v(0.0, 0.0, 0.0), r.cube, -1, MAT_COLOR))
    elif which == SCENE_WALL:
        r.push(DrawItem(0, _v(0.0, 0.0, -30.0), 0.0, 0.0, 0.0, 1.0, _v(60.0, 40.0, 1.0), _v(0.05, 0.05, 0.06), r.cube, -1, MAT_COLOR))
        r.push(DrawItem(1, _v(2.0, 1.0, -10.0), 0.0, 0.0, 0.0, 1.0, _v(1.0, 4.0, 1.0), _v(0.4, 0.3, 0.2), r.cube, -1, MAT_COLOR))


struct Rig(Movable):
    var w: UInt32
    var h: UInt32
    var target: Texture
    var cap: FrameCapture
    var hud: Hud

    def __init__(out self, device: Device, format: UInt32, w: UInt32, h: UInt32) raises:
        self.w = w
        self.h = h
        self.target = device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="vol_target")
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
        mut self, device: Device, mut r: SceneRendererOf[P, F, A], which: Int, pitch: Float64 = 0.0,
    ) raises -> List[UInt8]:
        r.begin(view_for(self.w, self.h, pitch))
        scene(r, which)
        r.draw(device, self.target.handle().raw, self.w, self.h, self.hud)
        return read(device, self.cap, self.target.handle().raw, self.w, self.h)


def px(p: List[UInt8], x: Int, y: Int, c: Int) -> Float64:
    return Float64(Int(p[(y * Int(W) + x) * 4 + c]))


def lum(p: List[UInt8], x: Int, y: Int) -> Float64:
    return (px(p, x, y, 0) + px(p, x, y, 1) + px(p, x, y, 2)) / 3.0


def region(p: List[UInt8], x0: Int, x1: Int, y0: Int, y1: Int) -> Float64:
    var s = 0.0
    for y in range(y0, y1):
        for x in range(x0, x1):
            s += lum(p, x, y)
    return s / Float64((x1 - x0) * (y1 - y0))


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def dump(dir: String, name: String, p: List[UInt8]) raises:
    if dir.byte_length() == 0:
        return
    with open(dir + "/" + name + ".rgba", "w") as f:
        f.write_bytes(Span(p))


def set_fog[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], density: Float32, g: Float32, falloff: Float32):
    r.vol_density = density
    r.vol_anisotropy = g
    r.vol_falloff = falloff
    r.vol_base = 0.0
    r.vol_albedo = 0.9
    r.vol_far = 40.0
    r.vol_ambient = 0.3


def _time[P: RenderPass, F: PostEffect, A: AuxTarget](device: Device, mut big: Rig, mut r: SceneRendererOf[P, F, A]) raises -> Float64:
    for _ in range(2):  # warm up
        _ = big.shoot(device, r, SCENE_WALL)
    var t0 = perf_counter_ns()
    for _ in range(5):
        _ = big.shoot(device, r, SCENE_WALL)
    return Float64(perf_counter_ns() - t0) / 5.0 / 1e6


def cost(device: Device, format: UInt32) raises:
    var big = Rig(device, format, 1920, 1080)
    var plain = SceneRendererOf[Lit](device, format, view_for(1920, 1080))
    var copy = SceneRendererOf[Lit, Stage[Copy]](device, format, view_for(1920, 1080))
    var fog = SceneRendererOf[Lit, VolumetricFog](device, format, view_for(1920, 1080))
    set_fog(fog, 0.03, 0.6, 0.1)
    var t_plain = _time(device, big, plain)
    var t_copy = _time(device, big, copy)
    var t_fog = _time(device, big, fog)
    print("| frame at 1920 x 1080 (lavapipe, wall clock incl. read-back) | ms |")
    print("|---|---:|")
    print("| no stage |", t_plain, "|")
    print("| one copy stage (the offscreen scene target every stage needs) |", t_copy, "|")
    print("| volumetric fog, 160 x 90 x 64 froxels |", t_fog, "|")
    print("| added by the fog over the copy stage |", t_fog - t_copy, "|")
    print("froxel textures:", volume_bytes(), "bytes")


def main() raises:
    var s = Suite("volumetric_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var dir = String("")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dir = String(args[i + 1])
        if args[i] == "--cost":
            cost(device, format)
            return
    var rig = Rig(device, format, W, H)
    var plain = SceneRendererOf[Lit](device, format, view_for(W, H))
    var fog = SceneRendererOf[Lit, VolumetricFog](device, format, view_for(W, H))

    # ---- off
    var base_wall = rig.shoot(device, plain, SCENE_WALL)
    set_fog(fog, 0.0, 0.6, 0.0)
    s.eqi(diff(base_wall, rig.shoot(device, fog, SCENE_WALL)), 0, "density 0: the frame without the effect, pixel for pixel")
    dump(dir, "vol_off", base_wall)

    # ---- uniform fog against the closed form, at a sky pixel near the centre
    var sky = rig.shoot(device, plain, SCENE_EMPTY)
    var cx = Int(W) // 2
    var cy = Int(H) // 2
    var worst = 0.0
    for d in [0.01, 0.03, 0.08]:
        set_fog(fog, Float32(d), 0.0, 0.0)
        var f = rig.shoot(device, fog, SCENE_EMPTY)
        var sigma = d
        var scatter = 0.9 * sigma * (0.6 / (4.0 * pi) + 0.4 * 0.3 / (4.0 * pi))
        var v = view_for(W, H)
        var nx = ((Float64(cx) + 0.5) / Float64(W) * 2.0 - 1.0) / Float64(v.sx)
        var ny = (1.0 - (Float64(cy) + 0.5) / Float64(H) * 2.0) / Float64(v.sy)
        var dist = 40.0 * sqrt(1.0 + nx * nx + ny * ny)
        var line = String("density ") + String(d) + ": "
        for c in range(3):
            var want = uniform_fog(px(sky, cx, cy, c) / 255.0, sigma, scatter, dist) * 255.0
            var got = px(f, cx, cy, c)
            worst = max(worst, abs(got - want))
            line += String(got) + " (closed form " + String(want) + ") "
        print(line)
        if d == 0.03:
            dump(dir, "vol_uniform", f)
    print("uniform fog, largest difference from the closed form:", worst, "levels")
    s.check(worst <= 2.0, "uniform fog matches colour * T + L / sigma * (1 - T) within 2 levels (" + String(worst) + ")")

    # ---- height falloff: looking up, less fog than with none
    set_fog(fog, 0.05, 0.0, 0.0)
    var flat = rig.shoot(device, fog, SCENE_EMPTY, 0.4)
    set_fog(fog, 0.05, 0.0, 0.3)
    var falling = rig.shoot(device, fog, SCENE_EMPTY, 0.4)
    var sky_up = rig.shoot(device, plain, SCENE_EMPTY, 0.4)
    var top_flat = abs(region(flat, 0, Int(W), 0, 20) - region(sky_up, 0, Int(W), 0, 20))
    var top_fall = abs(region(falling, 0, Int(W), 0, 20) - region(sky_up, 0, Int(W), 0, 20))
    print("change of the top 20 rows looking up, levels: no falloff", top_flat, "; falloff 0.3 / m", top_fall)
    s.check(top_fall < 0.5 * top_flat, "with a height falloff the fog high up is thinner")

    # ---- light shafts: the sun's shadow cuts the fog under the roof
    var to_sun = _v(0.15, 1.0, 0.1)
    fog.set_sun(device, to_sun, _v(1.0, 0.95, 0.85), 3.0)
    fog.set_shadow(device, sun_shadow_vp(to_sun, _v(0.0, 3.0, -20.0), 40.0, 60.0), True)
    plain.set_sun(device, to_sun, _v(1.0, 0.95, 0.85), 3.0)
    set_fog(fog, 0.03, 0.2, 0.0)
    var lit_base = rig.shoot(device, plain, SCENE_ROOF)
    var shafts = rig.shoot(device, fog, SCENE_ROOF)
    fog.set_shadow(device, sun_shadow_vp(to_sun, _v(0.0, 3.0, -20.0), 40.0, 60.0), False)
    var no_shadow = rig.shoot(device, fog, SCENE_ROOF)
    dump(dir, "vol_shafts", shafts)
    # rows below the horizon (the roof is above), the left and the right quarter
    var y0 = Int(H) // 2 + 10
    var y1 = Int(H) - 10
    var l_on = region(shafts, 10, 70, y0, y1) - region(lit_base, 10, 70, y0, y1)
    var l_off = region(no_shadow, 10, 70, y0, y1) - region(lit_base, 10, 70, y0, y1)
    var r_on = region(shafts, 250, 310, y0, y1) - region(lit_base, 250, 310, y0, y1)
    var r_off = region(no_shadow, 250, 310, y0, y1) - region(lit_base, 250, 310, y0, y1)
    print("fog's added light, levels: under the roof, shadow on", l_on, "off", l_off, "; in the open, on", r_on, "off", r_off)
    s.check(l_on < 0.6 * l_off, "under the roof the sun's shadow removes most of the fog's light")
    s.check(abs(r_on - r_off) <= 1.0, "in the open the shadow changes the fog by at most 1 level")
    fog.set_shadow(device, sun_shadow_vp(to_sun, _v(0.0, 3.0, -20.0), 40.0, 60.0), False)

    # ---- a point light in the fog
    var pfog = SceneRendererOf[DefaultPasses, VolumetricFog](device, format, view_for(W, H))
    set_fog(pfog, 0.03, 0.0, 0.0)
    var before = rig.shoot(device, pfog, SCENE_EMPTY)
    pfog.set_lights(device, [PointLight(_v(0.0, 1.0, -8.0), 5.0, _v(1.0, 0.6, 0.2), 20.0)])
    var with_light = rig.shoot(device, pfog, SCENE_EMPTY)
    dump(dir, "vol_point", with_light)
    var centre = region(with_light, cx - 5, cx + 5, cy - 5, cy + 5) - region(before, cx - 5, cx + 5, cy - 5, cy + 5)
    var corner = region(with_light, 0, 10, 0, 10) - region(before, 0, 10, 0, 10)
    print("point light: added at the centre", centre, "levels, at the corner", corner)
    s.check(centre > 10.0 and corner < 1.0, "the point light lights the fog around it and not the corners")
    dump(dir, "vol_wall", rig.shoot(device, fog, SCENE_WALL))
    s.finish()
