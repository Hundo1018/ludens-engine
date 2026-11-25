# tier: integration
# Colour temperature, photometric units, IES profiles and cookies on the GPU (app/photometry.mojo, app/lights.mojo,
# app/wgsl.mojo), each against a value worked out on the CPU. A white floor at y = 0 seen from straight above, as in
# tests/lights_native.mojo: a pixel is the light on the floor point under it, 0 .. 1.
#   unchanged     the frame with nothing set is the same, pixel for pixel, after an IES profile and cookies are loaded
#   kelvin        a directional light and the sun: colour * kelvin_rgb
#   units         a spot light in cd and in lm, a point light in lm, the sun in lx, an area light in nit and lm, through
#                 the exposure; one EV more halves the picture; units a light type does not have raise
#   IES           a point light with the downlight profile, at five angles; the street profile's two sides and its
#                 spin; a spot light with a profile; MatPbr under a profile (the ratio to the same light without)
#   cookies       a spot light's colour, left-right and top-bottom; a directional light's repeat and offset; the sun's;
#                 on a primitive floor; a layer with no picture raises
# `light_profiles_native --dump DIR` writes before / after pictures as DIR/lp_*.rgba (scripts/light_profiles_shots.py);
# `--cost` prints the frame time with 8 spot lights and 16 point lights, with and without profiles and cookies.
from std.math import sqrt, cos, sin, tan, acos, atan2, pi
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_PBR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.render_res import COOKIE_SIZE
from app.shadow_pass import ShadowPass
from app.lights import PointLight, SpotLight, DirLight, AreaLight, uniform_environment, rect_form_factor, sun_shadow_vp
from app.photometry import (
    Exposure, IesProfile, kelvin_rgb, baked_lookup, spot_solid_angle, UNITS_CANDELA, UNITS_LUMEN, UNITS_LUX, UNITS_NIT,
)

comptime W: UInt32 = 480
comptime H: UInt32 = 270
comptime Lit = Then[ShadowPass, DefaultPasses]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


struct Rig(Movable):
    var device: Device
    var target: Texture
    var cap: FrameCapture
    var hud: Hud
    var r: SceneRendererOf[Lit]
    var view: View
    var px: List[UInt8]
    var w: UInt32
    var h: UInt32

    def __init__(out self, w: UInt32, h: UInt32, eye: Vec3, at: Vec3) raises:
        self.w = w
        self.h = h
        self.device = Instance().request_adapter().request_device()
        var format = WGPUTextureFormat.RGBA8Unorm
        self.target = self.device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="lp")
        self.hud = Hud(self.device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(w), Float32(h))
        self.cap = FrameCapture(self.device, w, h)
        var aspect = Real(Float32(w) / Float32(h))
        var fwd = at - eye
        var hint = _v(0, 0, -1) if abs(Float64(fwd[1])) > 0.99 * sqrt(Float64(fwd[0] * fwd[0] + fwd[1] * fwd[1] + fwd[2] * fwd[2])) else _v(0, 1, 0)
        self.view = View(CameraPose(eye, look_rotation(fwd, hint), 0.9, aspect, 0.1, 100.0), aspect)
        self.r = SceneRendererOf[Lit](self.device, format, self.view)
        self.px = List[UInt8]()

    def dark(mut self) raises:
        """No lights, no sun and a black environment: only the lights set after this reach the floor."""
        self.r.set_lights(self.device, List[PointLight]())
        self.r.set_spot_lights(self.device, List[SpotLight]())
        self.r.set_dir_lights(self.device, List[DirLight]())
        self.r.set_area_lights(self.device, List[AreaLight]())
        self.r.set_sun(self.device, _v(0, 1, 0), _v(1, 1, 1), 0.0)
        self.r.set_environment(self.device, uniform_environment(_v(0, 0, 0)))

    def shoot(mut self, primitive_floor: Bool = False, material: Int = MAT_COLOR, scene: Int = 0) raises:
        self.r.begin(self.view.copy())
        if primitive_floor:
            self.r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(30, 0.25, 30), _v(1, 1, 1)))
        else:
            self.r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(60, 0.5, 60), _v(1, 1, 1), self.r.cube, -1, material, 1, 1.0, 0.0))
        if scene == 1:  # the pictures: a back wall, two boxes and a ball
            self.r.push(DrawItem(0, _v(0, 3, -4), 0.0, 0.0, 0.0, 1.0, _v(30, 6, 0.5), _v(0.9, 0.9, 0.9), self.r.cube, -1, MAT_COLOR))
            self.r.push(DrawItem(0, _v(-2.5, 0.5, -1), 0.0, 0.38, 0.0, 0.925, _v(1, 1, 1), _v(0.8, 0.8, 0.8), self.r.cube, -1, MAT_COLOR))
            self.r.push(DrawItem(0, _v(2.6, 0.75, 0.5), 0.0, -0.2, 0.0, 0.98, _v(1.5, 1.5, 1.5), _v(0.8, 0.8, 0.8), self.r.cube, -1, MAT_COLOR))
            self.r.push(DrawItem(1, _v(0.2, 0.6, 1.2), 0.0, 0.0, 0.0, 1.0, _v(1.2, 1.2, 1.2), _v(0.85, 0.85, 0.85), self.r.sphere, -1, MAT_COLOR))
        self.r.draw(self.device, self.target.handle().raw, self.w, self.h, self.hud)
        var req = self.cap.capture(self.device, self.target.handle().raw)
        req.wait()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(self.w))
        self.px.clear()
        for y in range(Int(self.h)):
            for x in range(Int(self.w) * 4):
                self.px.append(p[unsafe_offset=y * pitch + x])
        self.cap.unmap()

    def at(self, x: Float64, z: Float64) -> Vec3:
        """The colour (0 .. 1) of the pixel showing the floor point (x, 0, z)."""
        var c = self.view.project(_v(x, 0, z))
        var u = Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(self.w))
        var w = Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(self.h))
        var o = (min(max(w, 0), Int(self.h) - 1) * Int(self.w) + min(max(u, 0), Int(self.w) - 1)) * 4
        return _v(Float64(Int(self.px[o])) / 255.0, Float64(Int(self.px[o + 1])) / 255.0, Float64(Int(self.px[o + 2])) / 255.0)


def near(mut s: Suite, got: Vec3, want: Vec3, label: String, tol: Float64 = 0.012):
    var worst = 0.0
    for c in range(3):
        worst = max(worst, abs(Float64(got[c]) - min(Float64(want[c]), 1.0)))
    print("  ", label, ": got", got[0], got[1], got[2], "want", want[0], want[1], want[2])
    s.check(worst <= tol, label)


def grey(v: Float64) -> Vec3:
    return _v(v, v, v)


def falloff(d: Float64, r: Float64) -> Float64:
    var x = min(max(1.0 - (d / r) * (d / r), 0.0), 1.0)
    return x * x


def inv_square(d: Float64, r: Float64) -> Float64:
    var x = d / r
    var w = min(max(1.0 - x * x * x * x, 0.0), 1.0)
    return w * w / (d * d)


def srgb_to_linear(v: Int) -> Float64:
    var c = Float64(v) / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def solid_cookie(r: Int, g: Int, b: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=COOKIE_SIZE * COOKIE_SIZE * 4)
    for _ in range(COOKIE_SIZE * COOKIE_SIZE):
        out.append(UInt8(r)); out.append(UInt8(g)); out.append(UInt8(b)); out.append(255)
    return out^


def half_cookie(left: Bool) -> List[UInt8]:
    """White on the left half of the picture (left) or on its top half (not left), black elsewhere."""
    var out = List[UInt8](capacity=COOKIE_SIZE * COOKIE_SIZE * 4)
    for y in range(COOKIE_SIZE):
        for x in range(COOKIE_SIZE):
            var on = (x < COOKIE_SIZE // 2) if left else (y < COOKIE_SIZE // 2)
            var v = UInt8(255) if on else UInt8(0)
            out.append(v); out.append(v); out.append(v); out.append(255)
    return out^


def window_cookie() -> List[UInt8]:
    """A window of 2 x 3 panes: a 16 texel frame and 10 texel mullions, black; the panes white, a little warm."""
    var n = COOKIE_SIZE
    var out = List[UInt8](capacity=n * n * 4)
    for y in range(n):
        for x in range(n):
            var edge = x < 16 or x >= n - 16 or y < 16 or y >= n - 16
            var mull = abs(x - n // 2) < 5 or abs(y - n // 3) < 5 or abs(y - 2 * n // 3) < 5
            var v = 0 if edge or mull else 255
            out.append(UInt8(v)); out.append(UInt8(v)); out.append(UInt8(v * 235 // 255)); out.append(255)
    return out^


def _hash(ix: Int, iy: Int, period: Int) -> Float64:
    var x = ((ix % period) + period) % period
    var y = ((iy % period) + period) % period
    var h = UInt32(x * 374761393 + y * 668265263 + period * 97)
    h = (h ^ (h >> 13)) * 1274126177
    return Float64(Int((h ^ (h >> 16)) & 65535)) / 65535.0


def _noise(x: Float64, y: Float64, period: Int) -> Float64:
    var ix = Int(x)
    var iy = Int(y)
    var fx = x - Float64(ix)
    var fy = y - Float64(iy)
    var sx = fx * fx * (3.0 - 2.0 * fx)
    var sy = fy * fy * (3.0 - 2.0 * fy)
    var a = _hash(ix, iy, period) + (_hash(ix + 1, iy, period) - _hash(ix, iy, period)) * sx
    var b = _hash(ix, iy + 1, period) + (_hash(ix + 1, iy + 1, period) - _hash(ix, iy + 1, period)) * sx
    return a + (b - a) * sy


def cloud_cookie() -> List[UInt8]:
    """Tiling value noise, four octaves: bright gaps between clouds that let 35 % through."""
    var n = COOKIE_SIZE
    var out = List[UInt8](capacity=n * n * 4)
    for y in range(n):
        for x in range(n):
            var v = 0.0
            var amp = 0.5
            for o in range(4):
                var period = 4 << o
                v += amp * _noise(Float64(x) * Float64(period) / Float64(n), Float64(y) * Float64(period) / Float64(n), period)
                amp *= 0.5
            var c = min(max((v - 0.35) * 3.0, 0.0), 1.0)
            var g = UInt8(Int(255.0 * (1.0 - 0.65 * c) + 0.5))
            out.append(g); out.append(g); out.append(g); out.append(255)
    return out^


def dump(dir: String, name: String, p: List[UInt8]) raises:
    if dir.byte_length() == 0:
        return
    with open(dir + "/" + name + ".rgba", "w") as f:
        f.write_bytes(Span(p))


def pictures(dir: String, downlight: IesProfile, street: IesProfile) raises:
    """Before / after pairs for docs/LIGHTS_CAMERA.md, 640 x 360, a perspective view of a floor, a back wall, two boxes and
    a ball."""
    var g = Rig(640, 360, _v(0, 5.5, 9), _v(0, 1, -1))
    g.r.set_ies(g.device, 0, downlight)
    g.r.set_ies(g.device, 1, street)
    g.r.set_cookie(g.device, 0, window_cookie())
    g.r.set_cookie(g.device, 1, cloud_cookie())
    var amb = uniform_environment(_v(0.03, 0.03, 0.035))
    # 1. colour temperature: four spots on the wall, all white, then 1900, 2700, 4000 and 8000 K
    for after in range(2):
        g.dark()
        g.r.set_environment(g.device, amb)
        var spots = List[SpotLight]()
        var ks = [1900.0, 2700.0, 4000.0, 8000.0]
        for i in range(4):
            var x = -4.5 + 3.0 * Float64(i)
            spots.append(SpotLight(_v(x, 5, 1.5), _v(0, -1, -0.55), 14.0, 0.3, 0.45, _v(1, 1, 1), 0.75, True, Float32(ks[i]) if after == 1 else Float32(0.0)))
        g.r.set_spot_lights(g.device, spots)
        g.shoot(scene=1)
        dump(dir, "lp_kelvin_" + ("after" if after == 1 else "before"), g.px)
    # 2. IES: three point lights 0.4 m from the wall at 4.5 m: none, then the downlight twice and the street light, its street side toward the room
    for after in range(2):
        g.dark()
        g.r.set_environment(g.device, amb)
        var pts = List[PointLight]()
        for i in range(3):
            var x = -4.0 + 4.0 * Float64(i)
            var ies = -1 if after == 0 else (0 if i != 2 else 1)
            pts.append(PointLight(_v(x, 4.5, -3.35), 12.0, _v(1, 0.95, 0.85), Float32(1.1) if after == 0 else Float32(2.0), False, ies=ies))
        g.r.set_lights(g.device, pts)
        g.shoot(scene=1)
        dump(dir, "lp_ies_" + ("after" if after == 1 else "before"), g.px)
    # 3. cookies: a spot through a window onto the floor, and the sun through drifting clouds
    for after in range(2):
        g.dark()
        g.r.set_environment(g.device, uniform_environment(_v(0.05, 0.06, 0.08)))
        g.r.set_spot_lights(g.device, [SpotLight(_v(-1, 7, 3), _v(0.1, -1, -0.35), 20.0, 0.3, 0.38, _v(1, 0.97, 0.9), 2.4, True, cookie=0 if after == 1 else -1)])
        g.r.set_sun_light(g.device, DirLight(_v(0.3, 1, 0.6), _v(1, 0.98, 0.95), 0.55, cookie=1 if after == 1 else -1, cookie_size=9.0))
        g.r.set_shadow(g.device, sun_shadow_vp(_v(0.3, 1, 0.6), _v(0, 0, 0), 12.0, 30.0), True)
        g.shoot(scene=1)
        dump(dir, "lp_cookie_" + ("after" if after == 1 else "before"), g.px)
        g.r.set_shadow(g.device, sun_shadow_vp(_v(0.3, 1, 0.6), _v(0, 0, 0), 12.0, 30.0), False)


def _time(mut g: Rig, frames: Int) raises -> Float64:
    for _ in range(2):
        g.shoot(scene=1)
    var t0 = perf_counter_ns()
    for _ in range(frames):
        g.shoot(scene=1)
    return Float64(perf_counter_ns() - t0) / Float64(frames) / 1e6


def cost(downlight: IesProfile) raises:
    var g = Rig(1920, 1080, _v(0, 5.5, 9), _v(0, 1, -1))
    g.r.set_ies(g.device, 0, downlight)
    g.r.set_cookie(g.device, 0, window_cookie())
    print("| 1920 x 1080, 8 spot + 16 point lights, no shadows (lavapipe: a CPU rasteriser; wall clock incl. read-back) | ms |")
    print("|---|---:|")
    for mode in range(4):
        var pts = List[PointLight]()
        for i in range(16):
            pts.append(PointLight(_v(-6.0 + 0.8 * Float64(i), 3.0, -2.0), 8.0, _v(1, 1, 1), 0.2, kelvin=Float32(3000.0) if mode >= 1 else Float32(0.0), ies=0 if mode >= 2 else -1))
        var spots = List[SpotLight]()
        for i in range(8):
            spots.append(SpotLight(_v(-6.0 + 1.7 * Float64(i), 5.0, 2.0), _v(0, -1, -0.3), 12.0, 0.3, 0.5, _v(1, 1, 1), 0.3, ies=0 if mode >= 2 else -1, cookie=0 if mode == 3 else -1))
        g.r.set_lights(g.device, pts)
        g.r.set_spot_lights(g.device, spots)
        var names = ["plain", "with kelvin (CPU only: the same shader work)", "with an IES profile on every light", "with IES on every light and a cookie on every spot"]
        print("|", names[mode], "|", _time(g, 5), "|")


def main() raises:
    var s = Suite("light_profiles_native")
    var downlight = IesProfile.parse(open("assets/lights/downlight_cos8.ies", "r").read())
    var street = IesProfile.parse(open("assets/lights/street_type2.ies", "r").read())
    var dir = String("")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dir = String(args[i + 1])
        if args[i] == "--cost":
            cost(downlight)
            return
    if dir.byte_length() > 0:
        pictures(dir, downlight, street)
    var g = Rig(W, H, _v(0, 12, 0), _v(0, 0, 0))

    # 0. loading a profile and cookies changes nothing until a light names them
    g.shoot()
    var plain = g.px.copy()
    g.r.set_ies(g.device, 0, downlight)
    g.r.set_ies(g.device, 1, street)
    g.r.set_cookie(g.device, 0, solid_cookie(255, 128, 0))
    g.r.set_cookie(g.device, 1, half_cookie(True))
    g.r.set_cookie(g.device, 2, half_cookie(False))
    g.shoot()
    var changed = 0
    for i in range(len(plain)):
        if plain[i] != g.px[i]:
            changed += 1
    s.eqi(changed, 0, "a profile and three cookies loaded, no light naming them: the frame is the same")

    # 1. colour temperature
    g.dark()
    g.r.set_dir_lights(g.device, [DirLight(_v(0, 1, 0), _v(1, 1, 1), 0.3, kelvin=2700.0)])
    g.shoot()
    near(s, g.at(1, 1), kelvin_rgb(2700.0) * Real(0.3), "directional light at 2700 K: 0.3 * kelvin_rgb(2700)")
    g.dark()
    g.r.set_sun(g.device, _v(0, 1, 0), _v(1.0, 0.5, 1.0), 0.3, kelvin=4000.0)
    g.shoot()
    var k4 = kelvin_rgb(4000.0)
    near(s, g.at(1, 1), _v(0.3 * Float64(k4[0]), 0.15 * Float64(k4[1]), 0.3 * Float64(k4[2])), "the sun at 4000 K with a tint: tint * kelvin_rgb * 0.3")

    # 2. photometric units: EV100 5 (scale 1 / 38.4 per cd/m^2)
    g.dark()
    var ev5 = Exposure.from_ev100(5.0)
    g.r.set_exposure(g.device, ev5)
    var scale = ev5.scale()
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 20.0, 0.6, 0.7, _v(1, 1, 1), 1000.0, units=UNITS_CANDELA)])
    g.shoot()
    near(s, g.at(0, 0), grey(1000.0 * inv_square(4.0, 20.0) / pi * scale), "spot, 1000 cd, 4 m: 62.5 lx, a white floor shows 62.5 / pi / 38.4")
    var d2 = sqrt(20.0)
    near(s, g.at(2, 0), grey(1000.0 * inv_square(d2, 20.0) * 4.0 / d2 / pi * scale), "spot, 1000 cd, 2 m off its axis: I cos / d^2")
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 20.0, 0.6, 0.7, _v(1, 1, 1), Float32(1000.0 * spot_solid_angle(0.6, 0.7)), units=UNITS_LUMEN)])
    g.shoot()
    near(s, g.at(0, 0), grey(1000.0 * inv_square(4.0, 20.0) / pi * scale), "spot in lumens: 1000 cd times its cone's solid angle is the same light")
    g.r.set_spot_lights(g.device, List[SpotLight]())
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 20.0, _v(1, 1, 1), Float32(4.0 * pi * 1000.0), units=UNITS_LUMEN)])
    g.shoot()
    near(s, g.at(0, 0), grey(1000.0 * inv_square(4.0, 20.0) / pi * scale), "point light, 12 566 lm (1000 cd): the same")
    g.r.set_exposure(g.device, Exposure.from_ev100(6.0))
    g.shoot()
    near(s, g.at(0, 0), grey(0.5 * 1000.0 * inv_square(4.0, 20.0) / pi * scale), "one EV more: half", tol=0.008)
    g.dark()
    g.r.set_exposure(g.device, Exposure())
    g.r.set_sun(g.device, _v(0, 1, sqrt(3.0)), _v(1, 1, 1), 100000.0, units=UNITS_LUX)
    g.shoot()
    near(s, g.at(1, 1), grey(100000.0 / pi * Exposure().scale() * 0.5), "the sun, 100 000 lx at 30 degrees, sunny 16: 1.036 * 0.5")
    g.dark()
    g.r.set_exposure(g.device, ev5)
    var ff = rect_form_factor(1.0, 1.0, 2.0)
    g.r.set_area_lights(g.device, [AreaLight(_v(0, 2, 0), _v(1, 0, 0), _v(0, 0, 1), _v(1, 1, 1), 30.0, units=UNITS_NIT)])
    g.shoot()
    near(s, g.at(0, 0), grey(30.0 * scale * ff), "area light, 30 nit, 2 x 2 m at 2 m: L * scale * the form factor")
    g.r.set_area_lights(g.device, [AreaLight(_v(0, 2, 0), _v(1, 0, 0), _v(0, 0, 1), _v(1, 1, 1), Float32(pi * 4.0 * 30.0), units=UNITS_LUMEN)])
    g.shoot()
    near(s, g.at(0, 0), grey(30.0 * scale * ff), "area light, 377 lm over 4 m^2: 30 nit")
    var wrong = 0
    try:
        g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 20.0, _v(1, 1, 1), 10.0, units=UNITS_LUX)])
    except:
        wrong += 1
    try:
        g.r.set_dir_lights(g.device, [DirLight(_v(0, 1, 0), _v(1, 1, 1), 10.0, units=UNITS_CANDELA)])
    except:
        wrong += 1
    try:
        g.r.set_area_lights(g.device, [AreaLight(_v(0, 2, 0), _v(1, 0, 0), _v(0, 0, 1), _v(1, 1, 1), 1.0, units=UNITS_LUX)])
    except:
        wrong += 1
    s.eqi(wrong, 3, "lux on a point light, candela on a directional one, lux on an area light: each raises")
    g.r.set_exposure(g.device, Exposure())

    # 3. IES profiles
    var tdown = downlight.bake()
    var tstreet = street.bake()
    g.dark()
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 30.0, _v(1, 1, 1), 1.0, ies=0)])
    g.shoot()
    for deg in [0.0, 15.0, 30.0, 45.0, 65.0]:
        var x = 4.0 * tan(deg * pi / 180.0)
        var d = sqrt(16.0 + x * x)
        var want = falloff(d, 30.0) * 4.0 / d * baked_lookup(tdown, deg * pi / 180.0, pi)
        near(s, g.at(x, 0), grey(want), "point light with the downlight profile, " + String(Int(deg)) + " degrees off its axis")
    var zs = 5.0 * tan(55.0 * pi / 180.0)
    var ds = sqrt(25.0 + zs * zs)
    var th = acos(5.0 / ds)
    for spin in range(2):
        g.r.set_lights(g.device, [PointLight(_v(0, 5, 0), 30.0, _v(1, 1, 1), 1.0, ies=1, spin=Float32(pi / 2.0) if spin == 1 else Float32(0.0))])
        g.shoot()
        var to_street = g.at(0, zs) if spin == 0 else g.at(zs, 0)
        var to_houses = g.at(0, -zs) if spin == 0 else g.at(-zs, 0)
        var lit = falloff(ds, 30.0) * 5.0 / ds
        near(s, to_street, grey(lit * baked_lookup(tstreet, th, pi / 2.0)), "street profile" + (", spun 90 degrees" if spin == 1 else "") + ": 55 degrees toward the street")
        near(s, to_houses, grey(lit * baked_lookup(tstreet, th, 1.5 * pi)), "street profile" + (", spun 90 degrees" if spin == 1 else "") + ": 55 degrees toward the houses")
    g.r.set_lights(g.device, List[PointLight]())
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 30.0, 1.2, 1.3, _v(1, 1, 1), 1.0, ies=0)])
    g.shoot()
    var x30 = 4.0 * tan(pi / 6.0)
    var d30 = sqrt(16.0 + x30 * x30)
    near(s, g.at(x30, 0), grey(falloff(d30, 30.0) * 4.0 / d30 * baked_lookup(tdown, pi / 6.0, pi)), "spot light with the downlight profile, 30 degrees off its axis")
    g.r.set_spot_lights(g.device, List[SpotLight]())
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 30.0, _v(1, 1, 1), 1.0)])
    g.shoot(material=MAT_PBR)
    var pbr_plain = g.at(x30, 0)
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 30.0, _v(1, 1, 1), 1.0, ies=0)])
    g.shoot(material=MAT_PBR)
    var ratio = Float64(g.at(x30, 0)[0]) / Float64(pbr_plain[0])
    print("   MatPbr, 30 degrees: with the profile", g.at(x30, 0)[0], "without", pbr_plain[0], "ratio", ratio, "profile", baked_lookup(tdown, pi / 6.0, pi))
    s.check(abs(ratio - baked_lookup(tdown, pi / 6.0, pi)) < 0.03, "MatPbr under the downlight profile: the profile's ratio at 30 degrees")
    var bad = False
    try:
        g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 30.0, _v(1, 1, 1), 1.0, ies=5)])
    except:
        bad = True
    s.check(bad, "an IES slot with no profile raises")
    var lm = 1200.0
    g.r.set_exposure(g.device, ev5)
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 30.0, _v(1, 1, 1), Float32(lm), units=UNITS_LUMEN, ies=0)])
    g.shoot()
    var cd0 = lm * downlight.peak() / downlight.lumens()
    near(s, g.at(0, 0), grey(cd0 * inv_square(4.0, 30.0) / pi * scale), "1200 lm through the downlight profile: its peak is 1200 * peak / the file's flux cd")
    g.r.set_exposure(g.device, Exposure())

    # 4. cookies (layer 0: sRGB (255, 128, 0); layer 1: the left half white; layer 2: the top half white)
    g.dark()
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, cookie=0)])
    g.shoot()
    var d5 = sqrt(16.25)
    var base = falloff(d5, 10.0) * 4.0 / d5
    near(s, g.at(0.5, 0), _v(base, base * srgb_to_linear(128), 0.0), "spot cookie of one colour: the light times the texel, decoded from sRGB")
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, cookie=1)])
    g.shoot()
    var d1 = sqrt(17.0)
    near(s, g.at(1, 0), grey(falloff(d1, 10.0) * 4.0 / d1), "spot cookie: the picture's left half lands on +x (the cone's right vector is -x)")
    near(s, g.at(-1, 0), grey(0.0), "spot cookie: its dark right half on -x")
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, cookie=2)])
    g.shoot()
    near(s, g.at(0, 1), grey(falloff(d1, 10.0) * 4.0 / d1), "spot cookie: the picture's top half toward the cone's up vector, +z")
    near(s, g.at(0, -1), grey(0.0), "spot cookie: its bottom half on -z")
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, cookie=2, spin=Float32(pi / 2.0))])
    g.shoot()
    near(s, g.at(1, 0), grey(falloff(d1, 10.0) * 4.0 / d1), "spot cookie spun 90 degrees (up turns from +z to +x): the top half on +x")
    near(s, g.at(-1, 0), grey(0.0), "spot cookie spun 90 degrees: the bottom half on -x")
    g.dark()
    g.r.set_dir_lights(g.device, [DirLight(_v(0, 1, 0), _v(1, 1, 1), 0.5, cookie=1, cookie_size=4.0)])
    g.shoot()
    near(s, g.at(-1, 0.5), grey(0.5), "directional cookie, 4 m repeat: x = -1 is u 0.25, lit")
    near(s, g.at(1, 0.5), grey(0.0), "directional cookie: x = 1 is u 0.75, dark")
    near(s, g.at(3, 0.5), grey(0.5), "directional cookie: x = 3 is one repeat on from x = -1, lit")
    g.r.set_dir_lights(g.device, [DirLight(_v(0, 1, 0), _v(1, 1, 1), 0.5, cookie=1, cookie_size=4.0, cookie_u=0.5)])
    g.shoot()
    near(s, g.at(-1, 0.5), grey(0.0), "directional cookie shifted half a repeat: x = -1 dark")
    near(s, g.at(1, 0.5), grey(0.5), "directional cookie shifted half a repeat: x = 1 lit")
    g.shoot(primitive_floor=True)
    near(s, g.at(1, 0.5), grey(0.5), "directional cookie on a primitive floor")
    g.dark()
    g.r.set_sun_light(g.device, DirLight(_v(0, 1, 0), _v(1, 1, 1), 0.5, cookie=1, cookie_size=4.0))
    g.shoot()
    near(s, g.at(-1, 0.5), grey(0.5), "the sun's cookie (clouds): lit at u 0.25")
    near(s, g.at(1, 0.5), grey(0.0), "the sun's cookie: dark at u 0.75")
    g.shoot(material=MAT_PBR)
    s.check(Float64(g.at(-1, 0.5)[0]) > 0.2 and Float64(g.at(1, 0.5)[0]) < 0.01, "the sun's cookie on MatPbr")
    var missing = False
    try:
        g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, cookie=6)])
    except:
        missing = True
    s.check(missing, "a cookie layer with no picture raises")
    s.finish()
