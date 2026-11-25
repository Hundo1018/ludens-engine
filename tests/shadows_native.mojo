# tier: integration
# The sun's cascaded shadow and the dynamic shadow atlas (app/lights.mojo, app/render_res.mojo, app/wgsl.mojo), against
# geometry worked out by hand, on lavapipe.
#   CPU: the atlas sizes and places (no overlap, inside, near lights keep the large tiles); the cascade splits; a
#   cascade's size does not change as the camera turns; its texel grid stays put as the camera moves.
#   GPU: a 3 m wall 120 m long casts a shadow whose edge is where similar triangles put it at every depth from 3 to 95 m
#   (all four cascades and the blends between them); a 0.1 m pole 6 m away against the fixed box of before; 16 shadowed
#   point lights and 8 shadowed spot lights (104 tiles; the 4 x 4 atlas of before held 16) each shadow their own cube.
#   Contact shadows (app/contact_shadows.mojo): the camera's view-projection equals View.project (perspective and parallel);
#   a 1 m cube on the floor shadows the floor beside it over the ray's reach (0.6 m toward the sun = 0.27 m of floor) and
#   no further, a floor without objects stays exactly as lit as with the effect off, and the mask and depth textures exist
#   only while the effect is on.
# `shadows_native --dump DIR` also writes before / after frames of a 100 m scene (DIR/*.rgba, 960 x 540; scripts/native_shots.py
# makes PNGs); `--cost` prints the frame time at 1920 x 1080 of the fixed box, the cascades and a full atlas (lavapipe).
from std.math import sqrt, tan
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.render_res import PointLight
from app.shadow_pass import ShadowPass
from app.contact_shadows import camera_vp
from app.lights import (
    SpotLight, uniform_environment, sun_shadow_vp, apply_vp, atlas_sizes, atlas_place, cascade_splits, cascade_sphere,
    cascade_vp, TILE_MIN, TILE_START, MAX_TILES,
)

comptime W: UInt32 = 640
comptime H: UInt32 = 360
comptime Lit = Then[ShadowPass, DefaultPasses]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


struct Rig(Movable):
    var w: UInt32
    var h: UInt32
    var device: Device
    var target: Texture
    var cap: FrameCapture
    var hud: Hud
    var r: SceneRendererOf[Lit]
    var view: View
    var px: List[UInt8]

    def __init__(out self, w: UInt32 = W, h: UInt32 = H) raises:
        self.w = w
        self.h = h
        self.device = Instance().request_adapter().request_device()
        var format = WGPUTextureFormat.RGBA8Unorm
        self.target = self.device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="shadows")
        self.hud = Hud(self.device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(w), Float32(h))
        self.cap = FrameCapture(self.device, w, h)
        self.view = Self.look(_v(0, 3, 0), _v(0, -0.35, -1), w, h)
        self.r = SceneRendererOf[Lit](self.device, format, self.view)
        self.px = List[UInt8]()

    @staticmethod
    def look(eye: Vec3, fwd: Vec3, w: UInt32 = W, h: UInt32 = H) raises -> View:
        var aspect = Real(Float32(w) / Float32(h))
        return View(CameraPose(eye, look_rotation(fwd, _v(0, 1, 0)), 0.9, aspect, 0.1, 400.0), aspect)

    def shoot(mut self, items: List[DrawItem]) raises -> Float64:
        """Draw the items and read the frame back; the milliseconds of draw + submit + the wait for the pixels."""
        self.r.begin(self.view.copy())
        for it in items:
            self.r.push(it)
        var t0 = perf_counter_ns()
        self.r.draw(self.device, self.target.handle().raw, self.w, self.h, self.hud)
        var req = self.cap.capture(self.device, self.target.handle().raw)
        req.wait()
        var t1 = perf_counter_ns()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(self.w))
        self.px.clear()
        for y in range(Int(self.h)):
            for x in range(Int(self.w) * 4):
                self.px.append(p[unsafe_offset=y * pitch + x])
        self.cap.unmap()
        return Float64(t1 - t0) / 1e6

    def dump(self, dir: String, name: String) raises:
        if dir.byte_length() == 0:
            return
        with open(dir + "/" + name + ".rgba", "w") as f:
            f.write_bytes(Span(self.px))

    def at(self, x: Float64, z: Float64) -> Float64:
        """The red channel (0 .. 1) of the pixel showing the floor point (x, 0, z); -1 off screen."""
        var c = self.view.project(_v(x, 0, z))
        if Float64(c.w) <= 0.0:
            return -1.0
        var u = Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(self.w))
        var w = Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(self.h))
        if u < 0 or w < 0 or u >= Int(self.w) or w >= Int(self.h):
            return -1.0
        return Float64(Int(self.px[(w * Int(self.w) + u) * 4])) / 255.0


def _ms(x: Float64) -> String:
    var n = Int(x * 10.0 + 0.5)
    return String(n // 10) + "." + String(n % 10)


def _clip(m: List[Float32], p: Vec3) -> List[Float64]:
    """A world point through a column-major view-projection: x, y, z, w."""
    var out = List[Float64]()
    for r in range(4):
        out.append(
            Float64(m[r]) * Float64(p[0]) + Float64(m[4 + r]) * Float64(p[1]) + Float64(m[8 + r]) * Float64(p[2]) + Float64(m[12 + r])
        )
    return out^


def box(c: Vec3, half: Vec3, cube: Int) -> DrawItem:
    return DrawItem(0, c, 0.0, 0.0, 0.0, 1.0, half * Real(2.0), _v(1, 1, 1), cube, -1, MAT_COLOR)


def coloured(c: Vec3, half: Vec3, colour: Vec3, cube: Int) -> DrawItem:
    return DrawItem(0, c, 0.0, 0.0, 0.0, 1.0, half * Real(2.0), colour, cube, -1, MAT_COLOR)


def town(cube: Int) -> List[DrawItem]:
    """A 100 m street: pillars 0.3 m across and 4 m high every 4 m on both sides, crates, a fence of 5 cm posts near the
    camera, a long low wall; a 400 m floor."""
    var out = List[DrawItem]()
    out.append(box(_v(0, -0.25, -150), _v(200, 0.25, 200), cube))
    for k in range(26):
        var z = -3.0 - 4.0 * Float64(k)
        out.append(box(_v(-3.5, 2.0, z), _v(0.15, 2.0, 0.15), cube))
        out.append(box(_v(3.5, 2.0, z), _v(0.15, 2.0, 0.15), cube))
        if k % 3 == 1:
            out.append(box(_v(-1.2 + 0.4 * Float64(k % 5), 0.4, z - 1.5), _v(0.4, 0.4, 0.4), cube))
    for k in range(14):
        out.append(box(_v(-2.0 + 0.3 * Float64(k), 0.5, -1.8), _v(0.025, 0.5, 0.025), cube))
    out.append(box(_v(-2.0 + 0.3 * 6.5, 0.95, -1.8), _v(2.1, 0.03, 0.03), cube))
    out.append(box(_v(6.5, 0.75, -55), _v(0.2, 0.75, 50), cube))
    return out^


def shots_and_cost(dir: String, cost: Bool) raises:
    """The street in a 960 x 540 picture (or 1920 x 1080 for --cost): no shadow, the fixed 1024 box over 120 m of before,
    four cascades; then 24 shadowed lights at night."""
    var w: UInt32 = 1920 if cost else 960
    var h: UInt32 = 1080 if cost else 540
    var g = Rig(w, h)
    g.view = Rig.look(_v(0.5, 1.7, 2.0), _v(-0.05, -0.12, -1), w, h)
    var to_sun = _v(0.7, 0.8, 0.35)
    g.r.set_environment(g.device, uniform_environment(_v(0.22, 0.24, 0.28)))
    g.r.set_sun(g.device, to_sun, _v(1.0, 0.93, 0.82), 0.9)
    var items = town(g.r.cube)
    var names = [
        "shadow off", "fixed box, 1024 over 120 m (before)", "4 cascades of 1024 (after)", "24 shadowed lights, 104 atlas tiles",
        "the same 24 lights without shadows", "contact shadows only (16 steps, 0.6 m)", "4 cascades + contact shadows",
    ]
    var times = List[List[Float64]]()
    for _ in range(7):
        times.append(List[Float64]())
    var rounds = 13 if cost else 1
    for round in range(rounds):
        for mode in range(3):
            if mode == 0:
                g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -50), 60.0, 100.0), False)
            elif mode == 1:
                g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -50), 60.0, 100.0), True)
            else:
                g.r.set_sun_cascades(g.device, 4, 100.0, 0.75, 0.1, 50.0, 1024)
            var ms = g.shoot(items)
            if round >= 2 or not cost:
                times[mode].append(ms)
            if not cost:
                g.dump(dir, ["town_off", "town_before", "town_after"][mode])
        for mode in range(2):  # contact shadows alone, then on top of the cascades
            if mode == 0:
                g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -50), 60.0, 100.0), False)
            g.r.set_contact_shadows(g.device, True, 0.6, 16, 0.3, 1.0)
            var ms = g.shoot(items)
            if round >= 2 or not cost:
                times[5 + mode].append(ms)
            g.r.set_contact_shadows(g.device, False)
            if mode == 0:
                g.r.set_sun_cascades(g.device, 4, 100.0, 0.75, 0.1, 50.0, 1024)
    # night: 16 point lights and 8 spots along the street, every one with a shadow
    g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -50), 60.0, 100.0), False)
    g.r.set_sun(g.device, to_sun, _v(1, 1, 1), 0.0)
    g.r.set_environment(g.device, uniform_environment(_v(0.02, 0.02, 0.03)))
    var points = List[PointLight]()
    var spots = List[SpotLight]()
    for k in range(16):
        var z = -1.0 - 4.0 * Float64(k // 2)
        var x = -2.2 if k % 2 == 0 else 2.2
        points.append(PointLight(_v(x, 2.6, z), 7.0, _v(1.0, 0.75, 0.45), 0.45, shadow=True))
    for k in range(8):
        spots.append(SpotLight(_v(0.0, 5.0, -36.0 - 6.0 * Float64(k)), _v(0, -1, 0.15), 9.0, 0.35, 0.55, _v(0.6, 0.75, 1.0), 0.8, True))
    var points_off = List[PointLight]()
    var spots_off = List[SpotLight]()
    for l in points:
        points_off.append(PointLight(l.pos, l.range, l.color, l.intensity, shadow=False))
    for l in spots:
        spots_off.append(SpotLight(l.pos, l.dir, l.range, l.inner, l.outer, l.color, l.intensity, False))
    for round in range(rounds):
        for mode in range(2):
            if not cost and mode == 1:
                continue
            g.r.set_lights(g.device, points if mode == 0 else points_off)
            g.r.set_spot_lights(g.device, spots if mode == 0 else spots_off)
            var ms = g.shoot(items)
            if round >= 2 or not cost:
                times[3 + mode].append(ms)
    if not cost:
        g.dump(dir, "town_night")
        # contact shadows: a close shot of crates, a stack and a fence under a coarse sun map (the fixed 140 m box), without and with
        g.r.set_lights(g.device, List[PointLight]())
        g.r.set_spot_lights(g.device, List[SpotLight]())
        g.r.set_environment(g.device, uniform_environment(_v(0.22, 0.24, 0.28)))
        g.r.set_sun(g.device, _v(0.6, 0.55, 0.35), _v(1.0, 0.93, 0.82), 0.9)
        g.r.set_shadow(g.device, sun_shadow_vp(_v(0.6, 0.55, 0.35), _v(0, 0, -30), 70.0, 100.0), True)  # the fixed 140 m box: 0.14 m texels
        g.view = Rig.look(_v(-2.4, 1.3, 0.3), _v(0.5, -0.2, -1.0), w, h)
        var close = List[DrawItem]()
        close.append(box(_v(0, -0.25, -150), _v(200, 0.25, 200), g.r.cube))
        close.append(coloured(_v(0.0, 0.3, -4.0), _v(0.3, 0.3, 0.3), _v(0.85, 0.55, 0.3), g.r.cube))
        close.append(coloured(_v(0.9, 0.2, -3.4), _v(0.2, 0.2, 0.2), _v(0.3, 0.6, 0.85), g.r.cube))
        close.append(coloured(_v(0.0, 0.75, -4.0), _v(0.2, 0.15, 0.2), _v(0.85, 0.3, 0.3), g.r.cube))
        close.append(coloured(_v(-1.0, 0.05, -2.6), _v(0.5, 0.05, 0.35), _v(0.4, 0.8, 0.4), g.r.cube))
        for k in range(9):
            close.append(coloured(_v(-0.2 + 0.45 * Float64(k), 0.45, -5.6), _v(0.03, 0.45, 0.03), _v(0.8, 0.8, 0.75), g.r.cube))
        close.append(coloured(_v(1.6, 0.4, -5.6), _v(0.06, 0.4, 0.06), _v(0.9, 0.9, 0.9), g.r.cube))
        _ = g.shoot(close)
        g.dump(dir, "contact_off")
        g.r.set_contact_shadows(g.device, True, 0.6, 16, 0.3, 1.0)
        _ = g.shoot(close)
        g.dump(dir, "contact_on")
        return
    print("frame cost at 1920 x 1080 on lavapipe (a CPU rasteriser: not GPU times), the street (", len(items), "items), median of 11 frames; draw + submit + wait for the pixels")
    print("| sun / lights | ms / frame | min | max |")
    print("|---|---:|---:|---:|")
    for m in range(7):
        var t = times[m].copy()
        for i in range(len(t)):  # insertion sort
            var j = i
            while j > 0 and t[j - 1] > t[j]:
                var x = t[j]
                t[j] = t[j - 1]
                t[j - 1] = x
                j -= 1
        print("|", names[m], "|", _ms(t[len(t) // 2]), "|", _ms(t[0]), "|", _ms(t[len(t) - 1]), "|")


def main() raises:
    var s = Suite("shadows_native")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            shots_and_cost(String(args[i + 1]), False)
            return
        if args[i] == "--cost":
            shots_and_cost(String(""), True)
            return

    # ---- the atlas, CPU
    var faces = List[Int]()
    var scores = List[Float64]()
    for i in range(16):
        faces.append(6)
        scores.append(Float64(i))
    for i in range(16):
        faces.append(1)
        scores.append(Float64(16 + i))
    var sizes = atlas_sizes(faces, scores, 2048)
    var tiles = List[Int]()
    for j in range(len(faces)):
        for _ in range(faces[j]):
            tiles.append(sizes[j])
    var at = atlas_place(tiles, 2048)
    var overlap = 0
    var outside = 0
    var area = 0
    for a in range(len(tiles)):
        area += tiles[a] * tiles[a]
        if at[2 * a] + tiles[a] > 2048 or at[2 * a + 1] + tiles[a] > 2048:
            outside += 1
        for b in range(a + 1, len(tiles)):
            if at[2 * a] < at[2 * b] + tiles[b] and at[2 * b] < at[2 * a] + tiles[a] and at[2 * a + 1] < at[2 * b + 1] + tiles[b] and at[2 * b + 1] < at[2 * a + 1] + tiles[a]:
                overlap += 1
    print("atlas 2048: 16 point lights (6 tiles each) and 16 single-tile lights =", len(tiles), "tiles; sizes of the point lights:",
          sizes[0], sizes[7], sizes[15], "; of the others:", sizes[16], sizes[31], "; texels used", area, "of", 2048 * 2048)
    s.eqi(overlap, 0, "atlas: no two tiles overlap")
    s.eqi(outside, 0, "atlas: every tile is inside the atlas")
    s.check(area <= 2048 * 2048, "atlas: the tiles cover at most the atlas")
    s.check(sizes[0] >= sizes[15] and sizes[16] >= sizes[31], "atlas: a nearer light keeps a tile at least as large as a farther one")
    var few = atlas_sizes([6, 1, 1], [0.0, 1.0, 2.0], 2048)
    s.check(few[0] == TILE_START and few[1] == TILE_START and few[2] == TILE_START, "atlas: lights that fit keep TILE_START (512), as before")
    var raised = False
    try:
        _ = atlas_sizes(List[Int](length=MAX_TILES + 1, fill=1), List[Float64](length=MAX_TILES + 1, fill=0.0), 2048)
    except:
        raised = True
    s.check(raised, "atlas: more than MAX_TILES tiles is refused")

    # ---- the cascades, CPU
    var sp = cascade_splits(0.1, 100.0, 4, 0.75)
    print("cascade splits, 0.1 .. 100 m, lambda 0.75:", sp[0], sp[1], sp[2], sp[3], sp[4])
    s.check(abs(sp[0] - 0.1) < 1e-9 and abs(sp[4] - 100.0) < 1e-9 and sp[1] < sp[2] and sp[2] < sp[3], "cascades: the splits rise from near to far")
    var v1 = Rig.look(_v(0, 3, 0), _v(0, -0.35, -1))
    var v2 = Rig.look(_v(0, 3, 0), _v(0.8, 0.3, -0.2))
    var r1 = cascade_sphere(v1.eye, v1.fwd, Float64(v1.sx), Float64(v1.sy), False, sp[1], sp[2])[1]
    var r2 = cascade_sphere(v2.eye, v2.fwd, Float64(v2.sx), Float64(v2.sy), False, sp[1], sp[2])[1]
    s.almost(r1, r2, "cascades: the sphere's radius is the same whichever way the camera looks", tol=1e-9)
    # the texel grid: a world point's place in the map changes by whole texels when the camera moves a little
    var to_sun = _v(1, 2, 0)
    var res = 1024
    var worst = 0.0
    for k in range(1, 20):
        var c0 = cascade_sphere(_v(0, 3, 0), v1.fwd, Float64(v1.sx), Float64(v1.sy), False, sp[1], sp[2])
        var c1 = cascade_sphere(_v(0.013 * Float64(k), 3, -0.007 * Float64(k)), v1.fwd, Float64(v1.sx), Float64(v1.sy), False, sp[1], sp[2])
        var m0 = cascade_vp(to_sun, c0[0], c0[1], res, 50.0)
        var m1 = cascade_vp(to_sun, c1[0], c1[1], res, 50.0)
        var p0 = apply_vp(m0, _v(1.234, 0, -5.678))
        var p1 = apply_vp(m1, _v(1.234, 0, -5.678))
        for d in [(p1[0] - p0[0]) * Float64(res) * 0.5, (p1[1] - p0[1]) * Float64(res) * 0.5]:
            worst = max(worst, abs(d - Float64(Int(d + (0.5 if d >= 0 else -0.5)))))
    print("cascade texel grid: largest fraction of a texel a fixed point moved by, over 19 small camera moves:", worst)
    s.check(worst < 1e-2, "cascades: a world point moves in the map by whole texels only (the shadow's edges stay still)")

    # ---- GPU
    var g = Rig()
    var lit = 0.2 + 0.8 * 2.0 / sqrt(5.0)  # uniform 0.2 ambient + the sun (1, 2, 0) at 0.8 on the floor
    g.r.set_environment(g.device, uniform_environment(_v(0.2, 0.2, 0.2)))
    g.r.set_sun(g.device, to_sun, _v(1, 1, 1), 0.8)
    var floor = box(_v(0, -0.25, -150), _v(200, 0.25, 200), g.r.cube)
    # a wall 3 m high along z, its face toward -x at x = 2.9, the sun from +x: its shadow covers the floor from the wall
    # to x = 2.9 - 3 / 2 = 1.4
    var scene = List[DrawItem]()
    scene.append(floor.copy())
    scene.append(box(_v(3.0, 1.5, -62), _v(0.1, 1.5, 60), g.r.cube))
    g.r.set_sun_cascades(g.device, 4, 100.0, 0.75, 0.1, 50.0, 1024)
    g.shoot(scene)
    var checked = 0
    var good = 0
    var bad_z = List[Float64]()
    var z = -4.0
    while z > -86.0:
        # inside the shadow and outside its edge by 0.4 m to 30 m (the first three cascades), by 0.8 m beyond, where the
        # last cascade's texels are 0.19 m (a sphere of 98.5 m radius on 1024 texels)
        var m = 0.4 if z > -30.0 else 0.8
        var a_in = g.at(1.4 + m, z)
        var a_out = g.at(1.4 - m, z)
        if a_in >= 0.0 and a_out >= 0.0:
            checked += 1
            if abs(a_in - 0.2) < 0.03 and abs(a_out - lit) < 0.03:
                good += 1
            elif len(bad_z) < 8:
                bad_z.append(z)
        z -= 1.0
    print("cascades: wall shadow edge at x = 1.4, floor 0.4 m (0.8 m past 30 m) either side, depths 4 .. 85 m: right at", good, "of", checked)
    for b in bad_z:
        print("   wrong at z =", b, ":", g.at(1.8, b), g.at(1.0, b), g.at(2.2, b), g.at(0.6, b))
    s.check(checked > 70, "cascades: the wall's shadow is on screen from 4 to 85 m")
    s.eqi(good, checked, "cascades: shadowed inside the edge and lit outside it at every depth (4 cascades, 3 blends)")

    # a pole 0.1 m across, 3 m high, 6 m away: its shadow on the floor is a strip 0.1 m wide toward -x
    var pole = List[DrawItem]()
    pole.append(floor.copy())
    pole.append(box(_v(0.0, 1.5, -6.0), _v(0.05, 1.5, 0.05), g.r.cube))
    var darkest = List[Float64]()
    var widths = List[Int]()
    for mode in range(2):
        if mode == 0:  # the fixed box of before, large enough for this 120 m scene
            g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -60), 70.0, 100.0), True)
        else:
            g.r.set_sun_cascades(g.device, 4, 100.0, 0.75, 0.1, 50.0, 1024)
        g.shoot(pole)
        var lo = 1.0
        var n = 0
        var zz = -6.3
        while zz < -5.7:
            var a = g.at(-0.75, zz)
            lo = min(lo, a)
            if a >= 0.0 and a < (0.2 + lit) * 0.5:
                n += 1
            zz += 0.002
        darkest.append(lo)
        widths.append(n)
    print("pole 0.1 m wide at 6 m: darkest floor in its shadow, fixed 140 m box", darkest[0], ", cascades", darkest[1],
          "; samples (2 mm apart) darker than half-way:", widths[0], "and", widths[1], "(0.1 m is 50)")
    s.check(darkest[1] < 0.2 + 0.05, "cascades: the 0.1 m pole's shadow reaches the shadowed level")
    s.check(darkest[0] > darkest[1] + 0.2, "cascades: the fixed box of before (texels 0.14 m) loses most of that shadow")
    s.check(widths[1] >= 35 and widths[1] <= 65, "cascades: the pole's shadow is about 0.1 m wide")

    # ---- the camera's view-projection (the depth prepass of the contact shadows) is View.project's map
    var vp_persp = Rig.look(_v(1.5, 2.0, 0.5), _v(0.3, -0.4, -1.0))
    var vp_ortho = View.orthographic(CameraPose(_v(1.5, 2.0, 0.5), look_rotation(_v(0.3, -0.4, -1.0), _v(0, 1, 0)), 0.9, Real(1.7), 0.1, 400.0), Real(6.0), Real(1.7))
    var worst_vp = 0.0
    for which in range(2):
        var vw = vp_persp.copy() if which == 0 else vp_ortho.copy()
        var m = camera_vp(vw)
        for k in range(12):
            var q = _v(-3.0 + 0.9 * Float64(k), 0.2 * Float64(k % 5), -2.0 - 3.7 * Float64(k))
            var a = _clip(m, q)
            var b = vw.project(q)
            worst_vp = max(worst_vp, abs(a[0] - Float64(b.x)) / (1.0 + abs(a[0])), abs(a[1] - Float64(b.y)) / (1.0 + abs(a[1])))
            worst_vp = max(worst_vp, abs(a[2] - Float64(b.z)) / (1.0 + abs(a[2])), abs(a[3] - Float64(b.w)) / (1.0 + abs(a[3])))
    print("camera_vp against View.project, perspective and parallel, 24 points: largest relative difference", worst_vp)
    s.check(worst_vp < 2e-6, "contact shadows: the camera's view-projection is View.project's map (perspective and parallel)")

    # ---- contact shadows: a 1 m cube on the floor, the sun from +x at 2 : 1 up, no sun map at all
    g.view = Rig.look(_v(-4.0, 3.0, 0.0), _v(0.5, -0.35, -1.0))
    g.r.set_shadow(g.device, sun_shadow_vp(to_sun, _v(0, 0, -6), 20.0, 40.0), False)
    var on_floor = List[DrawItem]()
    on_floor.append(floor.copy())
    on_floor.append(box(_v(0.0, 0.5, -6.0), _v(0.5, 0.5, 0.5), g.r.cube))
    var bytes_off = g.r.res.texture_bytes()
    g.shoot(on_floor)
    var off_near = g.at(-0.55, -6.0)
    g.r.set_contact_shadows(g.device, True, 0.6, 16, 0.3, 1.0)
    g.shoot(on_floor)
    var c05 = g.at(-0.55, -6.0)
    var c12 = g.at(-0.62, -6.0)
    var c40 = g.at(-0.90, -6.0)
    var c_sun = g.at(0.0, -5.0)  # in front of the cube: the ray toward the sun passes beside it
    var acne = 0.0
    var plain = 0
    for k in range(20):  # floor away from the cube: the effect changes nothing there
        var q = g.at(-3.0 + 0.3 * Float64(k % 5), -2.0 - 1.3 * Float64(k))
        if q >= 0.0:
            plain += 1
            acne = max(acne, abs(q - lit))
    var bytes_on = g.r.res.texture_bytes()
    print("contact shadows, a cube on the floor, the sun 2 : 1 up (floor lit", lit, ", in shadow 0.2): off, 0.05 m beside it", off_near,
          "; on, 0.05 m", c05, ", 0.12 m", c12, ", 0.4 m", c40, ", in front", c_sun, "; 20 plain floor points off by at most", acne, "(", plain, "on screen )")
    print("textures: off", bytes_off, "bytes, on", bytes_on, "(+", bytes_on - bytes_off, ", 8 bytes per pixel of the scene less the 4 of the 1 x 1 mask:", 8 * Int(W) * Int(H) - 4, ")")
    s.check(abs(off_near - lit) < 0.03, "contact shadows: off, the floor beside the cube is lit (no sun map)")
    s.check(abs(c05 - 0.2) < 0.04 and abs(c12 - 0.2) < 0.04, "contact shadows: on, the floor within the ray's reach of the cube is in shadow")
    s.check(abs(c40 - lit) < 0.03 and abs(c_sun - lit) < 0.03, "contact shadows: beyond the ray's reach, and in front of the cube where the ray passes beside it, the floor is lit")
    s.check(plain >= 12 and acne < 0.01, "contact shadows: the floor away from the cube is exactly as lit as with the effect off (no acne)")
    s.eqi(bytes_on - bytes_off, 8 * Int(W) * Int(H) - 4, "contact shadows: the depth and mask textures take 8 bytes a pixel while on")
    g.r.set_contact_shadows(g.device, False)
    g.shoot(on_floor)
    var back = g.at(-0.55, -6.0)
    s.check(abs(back - lit) < 0.03 and g.r.res.texture_bytes() == bytes_off, "contact shadows: off again, the shadow and both textures are gone")

    # ---- many shadowed lights: 16 point lights and 8 spot lights with a shadow each (104 tiles)
    g.view = Rig.look(_v(0, 14, 0.01), _v(0, -1, -0.001))
    g.r.set_sun(g.device, _v(0, 1, 0), _v(1, 1, 1), 0.0)
    g.r.set_environment(g.device, uniform_environment(_v(0, 0, 0)))
    var points = List[PointLight]()
    var cubes = List[DrawItem]()
    cubes.append(box(_v(0, -0.25, 0), _v(60, 0.25, 60), g.r.cube))
    var spots = List[SpotLight]()
    var centres = List[Vec3]()
    for i in range(24):
        var cx = -8.75 + 2.5 * Float64(i % 8)
        var cz = -5.0 + 5.0 * Float64(i // 8)
        centres.append(_v(cx, 0, cz))
        if i < 16:
            points.append(PointLight(_v(cx, 1.2, cz), 1.6, _v(1, 1, 1), 4.0, shadow=True))
        else:
            spots.append(SpotLight(_v(cx, 1.2, cz), _v(0, -1, 0), 1.6, 0.6, 0.9, _v(1, 1, 1), 4.0, True))
        cubes.append(box(_v(cx, 0.6, cz), _v(0.1, 0.1, 0.1), g.r.cube))
    g.r.set_lights(g.device, points)
    g.r.set_spot_lights(g.device, spots)
    g.shoot(cubes)
    print("104 shadow tiles: sizes per light", g.r.res.tile_sizes[0], g.r.res.tile_sizes[15], g.r.res.tile_sizes[16], g.r.res.tile_sizes[23], "; tiles", g.r.res.tiles)
    s.eqi(g.r.res.tiles, 104, "atlas: 16 point lights and 8 spot lights take 104 tiles")
    # under each cube (0.1 m half, 0.6 m up, light 1.2 m up): the shadow reaches 0.1 * 1.2 / 0.5 = 0.24 m from the axis.
    # 0.5 m out the floor is lit as without the cube: 4 (1 - (d / 1.6)^2)^2 * 1.2 / d, d = sqrt(0.25 + 1.44); the
    # neighbours are 2 m away, out of range; a spot's inner cone (0.6 rad) holds the point (0.39 rad off the axis)
    var shadowed = 0
    var open = 0
    var d = sqrt(0.25 + 1.44)
    var x = 1.0 - (d / 1.6) * (d / 1.6)
    var expect = 4.0 * x * x * 1.2 / d
    for i in range(24):
        var c = centres[i]
        # on the side toward the middle of the picture, where the cube does not hide the floor from the camera
        var side = -1.0 if Float64(c[0]) > 0.0 else 1.0
        var a_in = g.at(Float64(c[0]) + 0.12 * side, Float64(c[2]))
        var a_out = g.at(Float64(c[0]) + 0.5 * side, Float64(c[2]))
        if a_in < 0.03:
            shadowed += 1
        if abs(a_out - expect) < 0.03:
            open += 1
        if a_in >= 0.03 or abs(a_out - expect) >= 0.03:
            print("   light", i, "at", c[0], c[2], ": under the cube", a_in, ", 0.5 m out", a_out)
    print("24 lights: the floor 0.12 m from the axis in its cube's shadow under", shadowed, "; the floor 0.5 m out at", expect, "under", open)
    s.eqi(shadowed, 24, "atlas: every one of the 24 lights shadows its cube")
    s.eqi(open, 24, "atlas: and lights the floor beside the shadow")
    s.finish()
