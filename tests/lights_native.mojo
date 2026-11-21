# tier: integration
# The lights (app/lights.mojo, app/wgsl.mojo), each against a value worked out by hand. A white floor at y = 0 seen from
# straight above, atmosphere off, so a pixel's colour is the light on the floor point under it, 0 .. 1.
#   the fixed sun; set_sun; a uniform and a sky environment; a directional light; a spot light's cone and falloff;
#   an area light against the closed-form form factor of a rectangle; a spot light's and a point light's shadow of a
#   cube (the atlas), the point light's across the seams of its cube faces; the same spot on a primitive floor;
#   MatPbr's reflection of a uniform environment.
from std.math import sqrt, cos, sin, pi
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
from app.render_res import PointLight
from app.shadow_pass import ShadowPass
from app.lights import (
    SpotLight, DirLight, AreaLight, Environment, uniform_environment, sky_environment, equirect_environment, sh_lit,
    sky_color, rect_form_factor, area_taps_factor, sun_shadow_vp, spot_vp, point_face_vp, apply_vp,
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

    def __init__(out self) raises:
        self.device = Instance().request_adapter().request_device()
        var format = WGPUTextureFormat.RGBA8Unorm
        self.target = self.device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="lights")
        self.hud = Hud(self.device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(W), Float32(H))
        self.cap = FrameCapture(self.device, W, H)
        var aspect = Real(Float32(W) / Float32(H))
        var eye = _v(0, 12, 0)
        self.view = View(CameraPose(eye, look_rotation(_v(0, -1, 0), _v(0, 0, -1)), 0.9, aspect, 0.1, 100.0), aspect)
        self.r = SceneRendererOf[Lit](self.device, format, self.view)
        self.px = List[UInt8]()

    def clear(mut self) raises:
        """No lights but the fixed sun: the state of a new renderer."""
        self.r.set_lights(self.device, List[PointLight]())
        self.r.set_spot_lights(self.device, List[SpotLight]())
        self.r.set_dir_lights(self.device, List[DirLight]())
        self.r.set_area_lights(self.device, List[AreaLight]())
        self.r.res.reset_sun(self.device)
        self.r.res.reset_environment(self.device)

    def dark(mut self) raises:
        """No sun and a black environment: only the lights set after this reach the floor."""
        self.clear()
        self.r.set_sun(self.device, _v(0, 1, 0), _v(1, 1, 1), 0.0)
        self.r.set_environment(self.device, uniform_environment(_v(0, 0, 0)))

    def shoot(mut self, cube: Bool = False, primitive_floor: Bool = False, slab: Bool = False, material: Int = MAT_COLOR, rough: Float32 = 0.5, metal: Float32 = 0.0) raises:
        self.r.begin(self.view.copy())
        if primitive_floor:
            self.r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(30, 0.25, 30), _v(1, 1, 1)))
        else:
            self.r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(60, 0.5, 60), _v(1, 1, 1), self.r.cube, -1, material, 1, rough, metal))
        if slab:  # a thin plate 2 m up, from x = 0.5 to 4.5
            self.r.push(DrawItem(0, _v(2.5, 2, 0), 0.0, 0.0, 0.0, 1.0, _v(4, 0.1, 6), _v(1, 1, 1), self.r.cube, -1, MAT_COLOR))
        if cube:
            self.r.push(DrawItem(0, _v(0, 2, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(1, 1, 1), self.r.cube, -1, MAT_COLOR))
        self.r.draw(self.device, self.target.handle().raw, W, H, self.hud)
        var req = self.cap.capture(self.device, self.target.handle().raw)
        req.wait()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(W))
        self.px.clear()
        for y in range(Int(H)):
            for x in range(Int(W) * 4):
                self.px.append(p[unsafe_offset=y * pitch + x])
        self.cap.unmap()

    def pixel(self, x: Float64, z: Float64) -> Tuple[Int, Int]:
        var c = self.view.project(_v(x, 0, z))
        return (Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W)), Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(H)))

    def snap(self, x: Float64, z: Float64) -> Tuple[Float64, Float64]:
        """The floor point at the centre of the pixel that shows (x, 0, z): the camera looks straight down from above
        the origin, so pixels and floor metres differ by one scale and a sign per axis."""
        var p = self.pixel(x, z)
        var c1 = self.view.project(_v(1, 0, 0))
        var c2 = self.view.project(_v(0, 0, 1))
        var mx = Float64(c1.x) / Float64(c1.w) * 0.5 * Float64(W)  # pixels per metre along x
        var mz = -Float64(c2.y) / Float64(c2.w) * 0.5 * Float64(H)
        return ((Float64(p[0]) + 0.5 - Float64(W) * 0.5) / mx, (Float64(p[1]) + 0.5 - Float64(H) * 0.5) / mz)

    def at(self, x: Float64, z: Float64) -> Vec3:
        """The colour (0 .. 1) of the pixel showing the floor point (x, 0, z)."""
        var uw = self.pixel(x, z)
        var u = uw[0]
        var w = uw[1]
        var o = (min(max(w, 0), Int(H) - 1) * Int(W) + min(max(u, 0), Int(W) - 1)) * 4
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


def smooth(lo: Float64, hi: Float64, x: Float64) -> Float64:
    var t = min(max((x - lo) / (hi - lo), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def main() raises:
    var s = Suite("lights_native")
    var g = Rig()

    # the numbers that need no GPU
    print("area light, a 2 x 2 m panel: the shader's nine taps against the closed form, by distance")
    var worst_far = 0.0
    for d in [0.5, 1.0, 2.0, 4.0, 8.0]:
        var exact = rect_form_factor(1.0, 1.0, d)
        var taps = area_taps_factor(1.0, 1.0, d)
        print("   distance", d, "closed form", exact, "taps", taps, "relative error", abs(taps - exact) / exact)
        if d >= 2.0:
            worst_far = max(worst_far, abs(taps - exact) / exact)
    s.check(worst_far < 0.005, "area light: from one panel width away the nine taps are within 0.5 % of the closed form")
    s.check(abs(area_taps_factor(1.0, 1.0, 1.0) / rect_form_factor(1.0, 1.0, 1.0) - 1.0) < 0.06, "area light: at half a panel width, within 6 %")
    var env = sky_environment(_v(0.5, 0.7, 1.0), _v(0.8, 0.8, 0.8), _v(0.2, 0.15, 0.1))
    # the exact irradiance over pi of that sky on a surface facing up and one facing down, by direct integration
    var up = [0.0, 0.0, 0.0]
    var down = [0.0, 0.0, 0.0]
    var n = 400
    for i in range(n):
        var th = (Float64(i) + 0.5) / Float64(n) * pi
        var col = sky_color(_v(0.5, 0.7, 1.0), _v(0.8, 0.8, 0.8), _v(0.2, 0.15, 0.1), cos(th))
        var ring = 2.0 * pi * sin(th) * (pi / Float64(n))
        for c in range(3):
            up[c] += Float64(col[c]) * max(cos(th), 0.0) * ring / pi
            down[c] += Float64(col[c]) * max(-cos(th), 0.0) * ring / pi
    var su = sh_lit(env.sh, _v(0, 1, 0))
    var sd = sh_lit(env.sh, _v(0, -1, 0))
    print("sky environment, facing up: order-2 harmonics", su[0], su[1], su[2], "exact", up[0], up[1], up[2])
    print("sky environment, facing down: order-2 harmonics", sd[0], sd[1], sd[2], "exact", down[0], down[1], down[2])
    var sh_err = 0.0
    for c in range(3):
        sh_err = max(sh_err, max(abs(Float64(su[c]) - up[c]), abs(Float64(sd[c]) - down[c])))
    s.check(sh_err < 0.03, "environment: the harmonics are within 0.03 of the sky's exact irradiance, up and down")
    var flat = uniform_environment(_v(0.2, 0.3, 0.4))
    var fl = sh_lit(flat.sh, _v(0.6, 0.0, 0.8))
    s.check(abs(Float64(fl[0]) - 0.2) < 1e-4 and abs(Float64(fl[2]) - 0.4) < 1e-4, "environment: a uniform one lights every normal by its colour")
    var pix = List[Float32]()
    for _ in range(64 * 32):
        pix.append(0.25); pix.append(0.5); pix.append(0.75)
    var eq = sh_lit(equirect_environment(pix, 64, 32).sh, _v(0, 1, 0))
    print("equirectangular 64 x 32 of one colour (0.25, 0.5, 0.75): lit", eq[0], eq[1], eq[2])
    s.check(abs(Float64(eq[0]) - 0.25) < 1e-3 and abs(Float64(eq[2]) - 0.75) < 1e-3, "environment: a one-colour equirectangular picture is that uniform environment")
    # the shadow views put what they look at in the middle and their far edge at depth 1
    var sp = SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, True)
    var c0 = apply_vp(spot_vp(sp), _v(0, 0, 0))
    var c1 = apply_vp(spot_vp(sp), _v(0, -6, 0))
    s.check(abs(c0[0]) < 1e-5 and abs(c0[1]) < 1e-5 and c0[2] / c0[3] > 0.0 and c0[2] / c0[3] < 1.0, "spot view: the point on its axis is at the centre, inside the depth range")
    s.almost(c1[2] / c1[3], 1.0, "spot view: a point at its range is at depth 1", tol=1e-5)
    var fx = apply_vp(point_face_vp(_v(0, 4, 0), 0, 12.0), _v(6, 4, 0))
    var fedge = apply_vp(point_face_vp(_v(0, 4, 0), 0, 12.0), _v(6, 10, 0))
    s.check(abs(fx[0]) < 1e-5 and abs(fx[1]) < 1e-5 and abs(abs(fedge[1] / fedge[3]) - 1.0) < 1e-5, "point light face +x: its axis at the centre, 45 degrees off it at the edge")
    var sv = apply_vp(sun_shadow_vp(_v(0.4, 1.0, 0.6), _v(1, 0, 2), 12.0, 30.0), _v(1, 0, 2))
    s.check(abs(sv[0]) < 1e-5 and abs(sv[1]) < 1e-5 and abs(sv[2] - 0.5) < 1e-5 and abs(sv[3] - 1.0) < 1e-6, "sun view: its centre is the middle of the box")

    # 1. nothing set: the fixed sun, 0.4 + 0.6 N.L with L = normalize(0.4, 1.0, 0.6)
    g.shoot()
    near(s, g.at(0, 0), grey(0.4 + 0.6 / sqrt(0.16 + 1.0 + 0.36)), "fixed sun on the floor")
    # 2. the host's sun, straight above, (1, 0.5, 0.25) at 0.5; the fixed 0.4 ambient stays
    g.r.set_sun(g.device, _v(0, 2, 0), _v(1.0, 0.5, 0.25), 0.5)
    g.shoot()
    near(s, g.at(1, 1), _v(0.9, 0.65, 0.525), "set_sun: 0.4 + colour * intensity * N.L")
    g.r.set_sun(g.device, _v(1, 1, 0), _v(1, 1, 1), 0.5)
    g.shoot()
    near(s, g.at(1, 1), grey(0.4 + 0.5 * sqrt(0.5)), "set_sun: at 45 degrees")
    # 3. environments
    g.dark()
    g.r.set_environment(g.device, uniform_environment(_v(0.2, 0.3, 0.4)))
    g.shoot()
    near(s, g.at(0, 0), _v(0.2, 0.3, 0.4), "uniform environment, no sun")
    g.r.set_environment(g.device, sky_environment(_v(0.5, 0.7, 1.0), _v(0.8, 0.8, 0.8), _v(0.2, 0.15, 0.1)))
    g.shoot()
    near(s, g.at(0, 0), su, "sky environment on the floor: the CPU's harmonics")
    # 4. a directional light on top of nothing
    g.dark()
    g.r.set_dir_lights(g.device, [DirLight(_v(0, 3, 4), _v(0.5, 1.0, 0.0), 0.5)])
    g.shoot()
    near(s, g.at(2, -1), _v(0.25 * 0.6, 0.5 * 0.6, 0.0), "directional light: colour * intensity * N.L (N.L = 0.6)")
    # 5. a spot light 4 m above the origin, pointing down: full to 0.2 rad, none beyond 0.3 rad, range 10 m
    g.dark()
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.2, 0.3, _v(1, 1, 1), 1.0)])
    g.shoot()
    near(s, g.at(0, 0), grey(falloff(4.0, 10.0)), "spot: under it, (1 - (4 / 10)^2)^2")
    var d5 = sqrt(16.0 + 0.25)
    near(s, g.at(0.5, 0), grey(falloff(d5, 10.0) * 4.0 / d5), "spot: 0.5 m off the axis, inside the inner cone")
    var pm = g.snap(4.0 * sin(0.25) / cos(0.25), 0.0)  # the ramp is steep: the value at the pixel's own centre
    var dm = sqrt(16.0 + pm[0] * pm[0] + pm[1] * pm[1])
    print("   between the cones: the pixel's centre is the floor point", pm[0], pm[1], ", at", 4.0 / dm, "= cos of the angle")
    near(s, g.at(pm[0], pm[1]), grey(falloff(dm, 10.0) * 4.0 / dm * smooth(cos(0.3), cos(0.2), 4.0 / dm)), "spot: near 0.25 rad, between the cones", tol=0.02)
    near(s, g.at(2.0, 0), grey(0.0), "spot: at 0.46 rad, outside the cone")
    # the same light on a primitive floor (the primitive pass)
    g.shoot(primitive_floor=True)
    near(s, g.at(0.5, 0), grey(falloff(d5, 10.0) * 4.0 / d5), "spot on a primitive floor")
    # 6. an area light: a 2 x 2 m panel 2 m above the origin facing down, colour (1, 0.8, 0.6) at 1
    g.dark()
    g.r.set_area_lights(g.device, [AreaLight(_v(0, 2, 0), _v(1, 0, 0), _v(0, 0, 1), _v(1.0, 0.8, 0.6), 1.0)])
    g.shoot()
    var ff = rect_form_factor(1.0, 1.0, 2.0)
    print("   form factor of the panel at 2 m, closed form:", ff, "; nine taps:", area_taps_factor(1.0, 1.0, 2.0))
    near(s, g.at(0, 0), _v(ff, 0.8 * ff, 0.6 * ff), "area light under its centre: colour * the rectangle's form factor")
    g.r.set_area_lights(g.device, [AreaLight(_v(0, 2, 0), _v(1, 0, 0), _v(0, 0, -1), _v(1.0, 0.8, 0.6), 1.0)])
    g.shoot()
    near(s, g.at(0, 0), grey(0.0), "area light facing up: nothing below it")
    # 7. a spot light's shadow: a 1 m cube at (0, 2, 0) under a spot at (0, 4, 0). The cube's top edge (y 2.5, x 0.5)
    #    throws the shadow's edge to x = 0.5 * 4 / 1.5 = 1.33 on the floor.
    g.dark()
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, True)])
    g.shoot(cube=True)
    near(s, g.at(1.0, 0), grey(0.0), "spot shadow: the floor 1.0 m from the axis is in the cube's shadow")
    near(s, g.at(0, -1.0), grey(0.0), "spot shadow: and along z")
    var d7 = sqrt(16.0 + 1.8 * 1.8)
    near(s, g.at(1.8, 0), grey(falloff(d7, 10.0) * 4.0 / d7), "spot shadow: 1.8 m out the floor is lit as without the cube")
    near(s, g.at(-1.2, 1.2), grey(0.0), "spot shadow: the corner of the square shadow")
    var lit_count = 0
    var k = 0
    while k < 40:  # no acne: every floor point from 1.6 to 2.0 m is lit
        var x = 1.6 + 0.01 * Float64(k)
        var dd = sqrt(16.0 + x * x)
        if abs(Float64(g.at(x, 0.3)[0]) - falloff(dd, 10.0) * 4.0 / dd) < 0.02:
            lit_count += 1
        k += 1
    s.eqi(lit_count, 40, "spot shadow: 40 lit floor points in a row, none darkened by the map's own surface")
    g.r.set_spot_lights(g.device, [SpotLight(_v(0, 4, 0), _v(0, -1, 0), 10.0, 0.5, 0.6, _v(1, 1, 1), 1.0, False)])
    g.shoot(cube=True)
    var d1 = sqrt(17.0)
    near(s, g.at(1.0, 0), grey(falloff(d1, 10.0) * 4.0 / d1), "the same spot without `shadow`: the floor under the cube is lit")
    # 8. a point light's shadow: the same cube under a point light at (0, 4, 0), range 12
    g.dark()
    g.r.set_lights(g.device, [PointLight(_v(0, 4, 0), 12.0, _v(1, 1, 1), 1.0, True)])
    g.shoot(cube=True)
    near(s, g.at(1.0, 0), grey(0.0), "point shadow: the floor 1.0 m from the axis is in the cube's shadow")
    var seam = 0
    var total = 0
    var xs = 3.0
    while xs <= 5.0:  # the -y face ends and the +x face begins at x = 4
        var dd = sqrt(16.0 + xs * xs)
        total += 1
        if abs(Float64(g.at(xs, 0.5)[0]) - falloff(dd, 12.0) * 4.0 / dd) < 0.02:
            seam += 1
        xs += 0.05
    print("   point shadow: floor points from x = 3 to 5 lit as expected:", seam, "of", total)
    s.eqi(seam, total, "point shadow: lit across the seam between two faces of the cube")
    var zs = sqrt(16.0 + 25.0 + 0.25)
    near(s, g.at(0.5, -5.0), grey(falloff(zs, 12.0) * 4.0 / zs), "point shadow: lit in the -z face")
    # 8b. a directional light's shadow: light from (1, 1, 0); the cube's shadow lies from x = -3 to -1 on the floor
    g.dark()
    g.r.set_dir_lights(g.device, [DirLight(_v(1, 1, 0), _v(1, 1, 1), 0.8, True, _v(0, 0, 0), 8.0, 20.0)])
    g.shoot(cube=True)
    near(s, g.at(-2.0, 0), grey(0.0), "directional shadow: the floor at x = -2 is in the cube's shadow")
    near(s, g.at(2.0, 0), grey(0.8 * sqrt(0.5)), "directional shadow: the floor at x = 2 is lit, colour * intensity * N.L")
    near(s, g.at(-2.0, 1.5), grey(0.8 * sqrt(0.5)), "directional shadow: beside the shadow the floor is lit")
    var acne = 0
    for i in range(60):
        if abs(Float64(g.at(1.0 + 0.05 * Float64(i), -2.0)[0]) - 0.8 * sqrt(0.5)) > 0.02:
            acne += 1
    s.eqi(acne, 0, "directional shadow: 60 lit floor points in a row, none darkened by the map's own surface")
    # 8c. an area light's shadow is as soft as the panel is large. A panel 5 m up over x = 4, a plate 2 m up whose
    #     edge is at x = 0.5: by similar triangles the penumbra on the floor runs from 0.5 + (0.5 - (4 + L / 2)) * 2 / 3
    #     to 0.5 + (0.5 - (4 - L / 2)) * 2 / 3, which is L * 2 / 3 wide. Measured: the floor's light with the plate over
    #     the light without it, and the distance between 10 % and 90 % of that (0.8 of the width for an even ramp).
    var widths = List[Float64]()
    for size in [1.0, 3.0]:
        g.dark()
        g.r.set_area_lights(g.device, [AreaLight(_v(4, 5, 0), _v(size / 2, 0, 0), _v(0, 0, size / 2), _v(1, 1, 1), 4.0, True, 20.0)])
        g.shoot()
        var open_floor = g.px.copy()
        g.shoot(slab=True)
        var lo = 99.0
        var hi = -99.0
        var x = -4.0
        var umbra = 1.0
        var clear = 0.0
        while x <= 0.3:
            var p = g.pixel(x, 0.0)
            var o = (p[1] * Int(W) + p[0]) * 4
            var ratio = Float64(Int(g.px[o])) / max(Float64(Int(open_floor[o])), 1.0)
            if ratio > 0.1 and ratio < 0.9:
                lo = min(lo, x)
                hi = max(hi, x)
            if abs(x - 0.0) < 0.03:
                umbra = ratio
            if abs(x + 3.8) < 0.03:
                clear = ratio
            x += 0.02
        var want = size * 2.0 / 3.0
        print("   area shadow, panel", size, "m: penumbra by similar triangles", want, "m (10 to 90 %:", 0.8 * want, "); measured 10 to 90 %:", hi - lo, "m ; under the plate's edge", umbra, ", in the open", clear)
        widths.append(hi - lo)
        s.check(umbra < 0.05 and clear > 0.95, "area shadow, panel " + String(size) + " m: dark behind the plate's edge, untouched in the open")
        s.check(hi - lo > 0.4 * 0.8 * want and hi - lo < 1.6 * 0.8 * want, "area shadow, panel " + String(size) + " m: the penumbra is 0.4 to 1.6 of the width similar triangles give")
    s.check(widths[1] > 1.8 * widths[0], "area shadow: a panel three times as large has a penumbra more than 1.8 times as wide")
    g.dark()
    g.r.set_area_lights(g.device, [AreaLight(_v(4, 5, 0), _v(0.5, 0, 0), _v(0, 0, 0.5), _v(1, 1, 1), 4.0, False)])
    g.shoot()
    var before = g.px.copy()
    g.shoot(slab=True)
    var p0 = g.pixel(0.0, 0.0)
    s.check(g.px[(p0[1] * Int(W) + p0[0]) * 4] == before[(p0[1] * Int(W) + p0[0]) * 4], "the same panel without `shadow`: the plate changes nothing on the floor")
    # 9. MatPbr reflects the environment: a rough metal floor under a uniform environment of radiance c reflects
    #    c * (f0 * A + B), the split-sum fit at roughness 1 and N.V = 1: A = 0.4524, B = -0.0024
    g.dark()
    g.r.set_environment(g.device, uniform_environment(_v(0.4, 0.6, 0.8)))
    g.shoot(material=MAT_PBR, rough=1.0, metal=1.0)
    near(s, g.at(0, 0), _v(0.4 * 0.45, 0.6 * 0.45, 0.8 * 0.45), "MatPbr: a rough white metal reflects 0.45 of a uniform environment")
    g.shoot(material=MAT_PBR, rough=1.0, metal=0.0)
    var dz = 0.04 * 0.4524 - 0.0024
    near(s, g.at(0, 0), _v(0.4 * (1.0 + dz), 0.6 * (1.0 + dz), 0.8 * (1.0 + dz)), "MatPbr: a matte white dielectric reflects the environment's colour plus 1.6 %")
    # 10. back to nothing set: the first frame again
    g.clear()
    g.shoot()
    near(s, g.at(0, 0), grey(0.4 + 0.6 / sqrt(0.16 + 1.0 + 0.36)), "all lights cleared: the fixed sun again")
    s.finish()
