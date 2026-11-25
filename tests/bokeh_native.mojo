# tier: integration
# The bokeh's shape and the anamorphic streak (app/lens.mojo), on native wgpu (lavapipe).
#   shape    three small bright spheres 20 m away against a dark wall, the lens focused at 2 m, so each is drawn as a
#            blur disc of lens_max_coc pixels. The middle one's outline is measured: the frame is averaged over 8 draws
#            (the shaped aperture turns its sample pattern by a random angle per pixel and frame), the pixels brighter
#            than half way between the wall and the disc's inside form the bokeh, and its radius is read along 72
#            directions from its centre. A round aperture gives a nearly constant radius; six blades give the hexagon's
#            ratio of corner to edge radius and its corners where the blade rotation puts them; a squeeze of 2 gives a
#            disc twice as tall as wide.
#   streak   one bright sphere in front of the dark wall, no depth of field: the light the streak adds runs along the
#            row of the sphere and not along its column; at intensity 0 the frame is the frame without the effect.
#   cost     `bokeh_native --cost`: frame times at 1920 x 1080 (lavapipe, a CPU rasteriser: not GPU times).
# `bokeh_native --dump DIR` writes the frames as DIR/*.rgba (640 x 360; scripts/tier4_shots.py turns them into PNGs).
from std.math import sqrt, cos, sin, atan2
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
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect, Stage, ThenPost, Copy
from app.lens import DepthOfField, AnamorphicStreak, Bokeh

comptime W: UInt32 = 640
comptime H: UInt32 = 360
comptime TAU = 6.283185307179586


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 0, 0), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)


struct Rig(Movable):
    var w: UInt32
    var h: UInt32
    var target: Texture
    var cap: FrameCapture
    var hud: Hud

    def __init__(out self, device: Device, format: UInt32, w: UInt32, h: UInt32) raises:
        self.w = w
        self.h = h
        self.target = device.create_texture(
            w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="bokeh_target",
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

    def read(mut self, device: Device) raises -> List[UInt8]:
        var req = self.cap.capture(device, self.target.handle().raw)
        req.wait()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(self.w))
        var out = List[UInt8]()
        for y in range(Int(self.h)):
            for x in range(Int(self.w) * 4):
                out.append(p[unsafe_offset=y * pitch + x])
        self.cap.unmap()
        return out^

    def shoot[P: RenderPass, F: PostEffect, A: AuxTarget](mut self, device: Device, mut r: SceneRendererOf[P, F, A], which: Int) raises -> List[UInt8]:
        r.begin(view_for(self.w, self.h))
        scene(r, which)
        r.draw(device, self.target.handle().raw, self.w, self.h, self.hud)
        return self.read(device)


comptime SCENE_LIGHTS = 0  # three small bright spheres 20 m away, before a dark wall at 40 m
comptime SCENE_ONE = 1  # one bright sphere 10 m away before the wall
comptime SCENE_NIGHT = 2  # a grey sphere 2 m away in focus, coloured lights scattered 12 to 30 m behind it


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], which: Int):
    r.push(DrawItem(0, _v(0, 0, -40), 0.0, 0.0, 0.0, 1.0, _v(80, 50, 1), _v(0.03, 0.03, 0.04), r.cube, -1, MAT_COLOR))
    if which == SCENE_NIGHT:
        r.push(DrawItem(1, _v(0.6, -0.3, -2.0), 0.0, 0.0, 0.0, 1.0, _v(0.35, 0.35, 0.35), _v(0.5, 0.5, 0.55), r.sphere, -1, MAT_COLOR))
        var cols = [_v(1.0, 0.85, 0.5), _v(0.6, 0.85, 1.0), _v(1.0, 0.55, 0.45), _v(0.9, 1.0, 0.7)]
        for i in range(14):
            var x = -9.0 + 1.37 * Float64(i) + 0.8 * Float64((i * 5) % 3)
            var y = -1.5 + 0.45 * Float64((i * 7) % 6)
            var z = -12.0 - 1.3 * Float64((i * 3) % 14)
            r.push(DrawItem(1, _v(x, y, z), 0.0, 0.0, 0.0, 1.0, _v(0.25, 0.25, 0.25), cols[i % 4], r.sphere, -1, MAT_COLOR))
    elif which == SCENE_LIGHTS:
        for i in range(3):
            r.push(DrawItem(1, _v(-6.0 + 6.0 * Float64(i), 0.0, -20.0), 0.0, 0.0, 0.0, 1.0, _v(0.4, 0.4, 0.4), _v(1.0, 0.95, 0.85), r.sphere, -1, MAT_COLOR))
    else:
        r.push(DrawItem(1, _v(0.0, 0.0, -10.0), 0.0, 0.0, 0.0, 1.0, _v(0.2, 0.2, 0.2), _v(1.0, 1.0, 1.0), r.sphere, -1, MAT_COLOR))


def lum(px: List[UInt8], x: Int, y: Int) -> Float64:
    var o = (y * Int(W) + x) * 4
    return (Float64(Int(px[o])) + Float64(Int(px[o + 1])) + Float64(Int(px[o + 2]))) / 3.0


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def dump(dir: String, name: String, px: List[UInt8]) raises:
    if dir == "":
        return
    with open(dir + "/" + name + ".rgba", "w") as f:
        f.write_bytes(Span(px))


def averaged[P: RenderPass, F: PostEffect, A: AuxTarget](
    device: Device, mut rig: Rig, mut r: SceneRendererOf[P, F, A], frames: Int,
) raises -> List[Float64]:
    """The frame's luminance (mean of r, g, b) averaged over `frames` draws of the same view."""
    var acc = List[Float64](length=Int(W * H), fill=0.0)
    for _ in range(frames):
        var px = rig.shoot(device, r, SCENE_LIGHTS)
        for y in range(Int(H)):
            for x in range(Int(W)):
                acc[y * Int(W) + x] += lum(px, x, y) / Float64(frames)
    return acc^


struct Outline(Copyable, Movable):
    var r: List[Float64]  # radius in pixels along direction k * 5 degrees (0 = +x on the screen, counter-clockwise)
    var width: Float64  # the bokeh's extent along x and along y, pixels
    var height: Float64

    def __init__(out self, var r: List[Float64], width: Float64, height: Float64):
        self.r = r^
        self.width = width
        self.height = height


def smooth_at(lumv: List[Float64], x: Int, y: Int) -> Float64:
    """The 3 x 3 mean around (x, y): the sprites add up in 8 bits, so single pixels are a level or two off."""
    var m = 0.0
    for j in range(-1, 2):
        for i in range(-1, 2):
            m += lumv[(y + j) * Int(W) + x + i] / 9.0
    return m


def outline(lumv: List[Float64], cx: Int, cy: Int, reach: Int) -> Outline:
    """The outline of the bright disc near (cx, cy): pixels (3 x 3 means) above a quarter of the way from the wall (the
    frame's corner) to the mean of the disc's inner part (within reach / 4). Its centre is the centroid of those pixels
    within `reach`; the radius is read along 72 directions from there."""
    var wall = lumv[10 * Int(W) + 10]
    var inner = 0.0
    var n = 0
    for dy in range(-reach // 4, reach // 4 + 1):
        for dx in range(-reach // 4, reach // 4 + 1):
            if dx * dx + dy * dy <= (reach // 4) * (reach // 4):
                inner += lumv[(cy + dy) * Int(W) + cx + dx]
                n += 1
    inner /= Float64(n)
    var cut = wall + 0.25 * (inner - wall)
    var sx = 0.0
    var sy = 0.0
    var cnt = 0.0
    for y in range(cy - reach, cy + reach + 1):
        for x in range(cx - reach, cx + reach + 1):
            if smooth_at(lumv, x, y) > cut:
                sx += Float64(x)
                sy += Float64(y)
                cnt += 1.0
    var ox = sx / cnt
    var oy = sy / cnt
    var rs = List[Float64]()
    for k in range(72):
        var a = Float64(k) * TAU / 72.0
        var last = 0.0
        for step in range(1, reach * 4):
            var d = Float64(step) * 0.25
            var x = Int(ox + cos(a) * d + 0.5)
            var y = Int(oy - sin(a) * d + 0.5)
            if x < 1 or y < 1 or x >= Int(W) - 1 or y >= Int(H) - 1:
                break
            if smooth_at(lumv, x, y) > cut:
                last = d
        rs.append(last)
    var wx = rs[0] + rs[36]
    var hy = rs[18] + rs[54]
    return Outline(rs^, wx, hy)


def hexagon_r(a: Float64, rot: Float64) -> Float64:
    """The hexagon's radius at angle a (corners at rot + k * 60 deg), as a share of its corner radius."""
    var seg = TAU / 6.0
    var t = a - rot
    var k = t - Float64(Int(t / seg + 1000.0) - 1000) * seg - 0.5 * seg
    return cos(0.5 * seg) / cos(k)


def correlation(a: List[Float64], b: List[Float64]) -> Float64:
    var ma = 0.0
    var mb = 0.0
    for i in range(len(a)):
        ma += a[i]
        mb += b[i]
    ma /= Float64(len(a))
    mb /= Float64(len(b))
    var sab = 0.0
    var saa = 0.0
    var sbb = 0.0
    for i in range(len(a)):
        sab += (a[i] - ma) * (b[i] - mb)
        saa += (a[i] - ma) * (a[i] - ma)
        sbb += (b[i] - mb) * (b[i] - mb)
    return sab / sqrt(saa * sbb + 1e-12)


def spread(o: Outline) -> Float64:
    var lo = o.r[0]
    var hi = o.r[0]
    for x in o.r:
        lo = min(lo, x)
        hi = max(hi, x)
    return hi / max(lo, 1e-6)


def lens_setup[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A]):
    r.lens_sensor = 0.15
    r.lens_focus = 1.0
    r.lens_fstop = 1.0
    r.bokeh_gain = 64.0
    r.lens_max_coc = 60.0
    r.bokeh_threshold = 0.5


def ms2(x: Float64) -> String:
    var n = Int(x * 100.0 + 0.5)
    var frac = n % 100
    return String(n // 100) + "." + ("0" if frac < 10 else "") + String(frac)


def _median(mut v: List[Float64]) -> Float64:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v[len(v) // 2]


def timed[P: RenderPass, F: PostEffect, A: AuxTarget](device: Device, mut r: SceneRendererOf[P, F, A], mut rig: Rig) raises -> Float64:
    r.begin(view_for(rig.w, rig.h))
    scene(r, SCENE_LIGHTS)
    var t0 = perf_counter_ns()
    r.draw(device, rig.target.handle().raw, rig.w, rig.h, rig.hud)
    var req = rig.cap.capture(device, rig.target.handle().raw)
    req.wait()
    var t1 = perf_counter_ns()
    _ = req.take()
    rig.cap.unmap()
    return Float64(t1 - t0) / 1e6


def cost(device: Device, format: UInt32) raises:
    comptime CW: UInt32 = 1920
    comptime CH: UInt32 = 1080
    comptime ROUNDS = 9
    var rig = Rig(device, format, CW, CH)
    var v = view_for(CW, CH)
    var copy = SceneRendererOf[DefaultPasses, Stage[Copy]](device, format, v)
    var round = SceneRendererOf[DefaultPasses, Stage[DepthOfField]](device, format, v)
    var shaped = SceneRendererOf[DefaultPasses, Stage[DepthOfField]](device, format, v)
    var hexa = SceneRendererOf[DefaultPasses, Bokeh](device, format, v)
    var streak = SceneRendererOf[DefaultPasses, AnamorphicStreak](device, format, v)
    lens_setup(round)
    lens_setup(shaped)
    lens_setup(hexa)
    round.bokeh_gain = 0.0
    shaped.bokeh_blades = 6
    shaped.bokeh_squeeze = 1.5
    hexa.bokeh_blades = 6
    hexa.bokeh_squeeze = 1.5
    streak.streak_intensity = 1.0
    var t = List[List[Float64]]()
    for _ in range(5):
        t.append(List[Float64]())
    for k in range(ROUNDS + 2):
        var ms = [timed(device, copy, rig), timed(device, round, rig), timed(device, shaped, rig), timed(device, hexa, rig), timed(device, streak, rig)]
        if k >= 2:
            for i in range(5):
                t[i].append(ms[i])
    var names = [
        "one copy stage", "DepthOfField, round aperture (48 samples)", "DepthOfField, 6 blades, squeeze 1.5 (64 samples)",
        "Bokeh: the same, plus the highlight sprites (gain 64)", "AnamorphicStreak (7 stages, 6 half-size targets)",
    ]
    var med = List[Float64]()
    for i in range(5):
        med.append(_median(t[i]))
    print("frame cost at", Int(CW), "x", Int(CH), "on lavapipe (a CPU rasteriser: not GPU times), median of", ROUNDS, "frames")
    print("| pipeline | ms / frame | added over one copy stage |")
    print("|---|---:|---:|")
    for i in range(5):
        print("|", names[i], "|", ms2(med[i]), "|", "-" if i == 0 else "+" + ms2(med[i] - med[0]), "|")


def main() raises:
    var s = Suite("bokeh_native")
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
    var view = view_for(W, H)
    var cx = Int(W) // 2
    var cy = Int(H) // 2
    var reach = 45

    # ---- a round aperture (the shaped path: highlight gain on, no blades)
    var round = SceneRendererOf[DefaultPasses, Bokeh](device, format, view)
    lens_setup(round)
    var lr = averaged(device, rig, round, 1)
    var o_round = outline(lr, cx, cy, reach)
    print("round aperture: bokeh", o_round.width, "x", o_round.height, "px, largest over smallest radius", spread(o_round))
    s.check(o_round.width > 50.0 and o_round.width < 70.0, "round aperture: the disc is lens_max_coc (60 px) across, within 10 px")
    s.check(spread(o_round) < 1.15, "round aperture: the radius is the same in every direction within 15 %")
    dump(dir, "bokeh_round", rig.shoot(device, round, SCENE_LIGHTS))

    # ---- six blades
    var hexa = SceneRendererOf[DefaultPasses, Bokeh](device, format, view)
    lens_setup(hexa)
    hexa.bokeh_blades = 6
    var lh = averaged(device, rig, hexa, 1)
    var o_hex = outline(lh, cx, cy, reach)
    var want = List[Float64]()
    var turned = List[Float64]()
    for k in range(72):
        var a = Float64(k) * TAU / 72.0
        want.append(hexagon_r(a, 0.0))
        turned.append(hexagon_r(a, TAU / 12.0))
    var c_right = correlation(o_hex.r, want)
    var c_wrong = correlation(o_hex.r, turned)
    print("6 blades, rotation 0: bokeh", o_hex.width, "x", o_hex.height, "px, largest over smallest radius", spread(o_hex),
          "(a hexagon: 1.155); correlation of the radius with the hexagon's", c_right, ", with the hexagon turned 30 deg", c_wrong)
    s.check(spread(o_hex) > 1.07 and spread(o_hex) < 1.3, "6 blades: corner radius over edge radius near the hexagon's 1.155")
    s.check(c_right > 0.5 and c_right > c_wrong + 0.5, "6 blades: the corners are where the rotation puts them")
    dump(dir, "bokeh_hexagon", rig.shoot(device, hexa, SCENE_LIGHTS))
    hexa.bokeh_rotation = Float32(TAU / 12.0)
    var lh2 = averaged(device, rig, hexa, 1)
    var o_hex2 = outline(lh2, cx, cy, reach)
    var c2 = correlation(o_hex2.r, turned)
    print("6 blades, rotation 30 deg: correlation with the turned hexagon", c2, ", with the unturned one", correlation(o_hex2.r, want))
    s.check(c2 > 0.5, "6 blades turned 30 deg: the corners turn with them")
    hexa.bokeh_rotation = 0.0
    hexa.bokeh_roundness = 1.0
    var lh3 = averaged(device, rig, hexa, 1)
    var o_hex3 = outline(lh3, cx, cy, reach)
    print("6 blades, roundness 1: largest over smallest radius", spread(o_hex3))
    s.check(spread(o_hex3) < spread(o_hex), "roundness 1 bends the blades into a circle: the radius varies less")

    # ---- anamorphic squeeze
    var ana = SceneRendererOf[DefaultPasses, Bokeh](device, format, view)
    lens_setup(ana)
    ana.bokeh_squeeze = 2.0
    var la = averaged(device, rig, ana, 1)
    var o_ana = outline(la, cx, cy, reach)
    print("squeeze 2: bokeh", o_ana.width, "x", o_ana.height, "px; width over height", o_ana.width / o_ana.height)
    s.check(o_ana.height > 50.0 and o_ana.height < 70.0, "squeeze 2: the disc keeps its height (60 px)")
    s.check(o_ana.width / o_ana.height > 0.42 and o_ana.width / o_ana.height < 0.7, "squeeze 2: half as wide as tall (the sphere's own 15 px widen it)")
    dump(dir, "bokeh_anamorphic", rig.shoot(device, ana, SCENE_LIGHTS))

    # ---- the look together (only dumped: docs/images/tier4/lens_night_*.png)
    if dir != "":
        var flat = SceneRendererOf[DefaultPasses](device, format, view)
        dump(dir, "lens_night_plain", rig.shoot(device, flat, SCENE_NIGHT))
        var cine = SceneRendererOf[DefaultPasses, ThenPost[Bokeh, AnamorphicStreak]](device, format, view)
        cine.lens_sensor = 0.15
        cine.lens_focus = 2.0
        cine.lens_fstop = 1.0
        cine.lens_max_coc = 48.0
        cine.bokeh_threshold = 0.45
        cine.bokeh_gain = 48.0
        cine.bokeh_blades = 7
        cine.bokeh_roundness = 0.15
        dump(dir, "lens_night_7_blades", rig.shoot(device, cine, SCENE_NIGHT))
        cine.bokeh_blades = 0
        cine.bokeh_squeeze = 1.8
        cine.streak_intensity = 0.4
        cine.streak_threshold = 0.6
        dump(dir, "lens_night_anamorphic", rig.shoot(device, cine, SCENE_NIGHT))

    # ---- the streak
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    var base = rig.shoot(device, plain, SCENE_ONE)
    var st = SceneRendererOf[DefaultPasses, AnamorphicStreak](device, format, view)
    st.streak_threshold = 0.5
    st.streak_intensity = 0.0
    var off = rig.shoot(device, st, SCENE_ONE)
    print("streak intensity 0: pixels that differ from the frame without the effect:", diff(base, off))
    s.eqi(diff(base, off), 0, "streak intensity 0: the frame without the effect, pixel for pixel")
    st.streak_intensity = 1.0
    var on = rig.shoot(device, st, SCENE_ONE)
    dump(dir, "streak_off", base)
    dump(dir, "streak_on", on)
    var along = 0.0
    var across = 0.0
    for d in [40, 80]:
        along += 0.5 * (lum(on, cx + d, cy) - lum(base, cx + d, cy) + lum(on, cx - d, cy) - lum(base, cx - d, cy))
        across += 0.5 * (lum(on, cx, cy + d // 2) - lum(base, cx, cy + d // 2) + lum(on, cx, cy - d // 2) - lum(base, cx, cy - d // 2))
    var reach_px = 0
    var near = lum(on, cx + 12, cy) - lum(base, cx + 12, cy)
    for x in range(cx + 12, Int(W)):
        if lum(on, x, cy) - lum(base, x, cy) >= 0.1 * near:
            reach_px = x - cx
    print("streak 1: light added 40 and 80 px along the row", along, "levels (summed), 20 and 40 px along the column", across,
          "; it stays above a tenth of its value 12 px out until", reach_px, "px from the source (", Float64(reach_px) / Float64(W), "of the width)")
    s.check(along > 4.0, "the streak adds light along the source's row")
    s.check(across < 0.1 * along, "and almost none along its column")
    st.streak_length = 0.5
    var short = rig.shoot(device, st, SCENE_ONE)
    var reach_short = 0
    var near_s = lum(short, cx + 12, cy) - lum(base, cx + 12, cy)
    for x in range(cx + 12, Int(W)):
        if lum(short, x, cy) - lum(base, x, cy) >= 0.1 * near_s:
            reach_short = x - cx
    print("streak length 0.5: reaches", reach_short, "px (", reach_px, "at length 1)")
    s.check(reach_short < reach_px, "a shorter streak_length gives a shorter streak")
    s.finish()
