# tier: integration
# Screen-space reflections (app/ssr.mojo) on native wgpu (lavapipe).
#   A glossy grey floor (MatPbr, roughness 0.05) under a sky environment, a red box and a blue box standing on it, the
#   camera 1.6 m up looking slightly down. The floor's reflection of each box is where the box's mirror image through
#   the floor projects; there the stage turns the floor toward the box's colour. Where the reflected ray leaves the
#   screen or meets nothing the frame keeps the environment's reflection (the fallback): within 2 levels of the frame
#   without the stage. Intensity 0, a floor rougher than ssr_max_roughness, and a pipeline with no surface target each
#   give the frame without the stage, pixel for pixel. The same in the linear workflow (ACES), which the stage undoes
#   and redoes (to_linear / to_display).
#   cost  `ssr_native --cost`: frame times at 1920 x 1080 (lavapipe, a CPU rasteriser: not GPU times).
# `ssr_native --dump DIR` writes the frames as DIR/*.rgba (640 x 360; scripts/tier4_shots.py makes PNGs).
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.texture import Texture
from game.draw_item import DrawItem, MAT_COLOR, MAT_PBR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget, Aux
from app.post import PostEffect, Stage, Copy
from app.lights import sky_environment
from app.ssr import Ssr, SurfacePasses

comptime W: UInt32 = 640
comptime H: UInt32 = 360


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 1.6, 0), look_rotation(_v(0, -0.25, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)


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
            w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="ssr_target",
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

    def shoot[P: RenderPass, F: PostEffect, A: AuxTarget](mut self, device: Device, mut r: SceneRendererOf[P, F, A], rough: Float32 = 0.05) raises -> List[UInt8]:
        r.begin(view_for(self.w, self.h))
        scene(r, rough)
        r.draw(device, self.target.handle().raw, self.w, self.h, self.hud)
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


def scene[P: RenderPass, F: PostEffect, A: AuxTarget](mut r: SceneRendererOf[P, F, A], rough: Float32):
    r.push(DrawItem(0, _v(0, -0.05, -15), 0.0, 0.0, 0.0, 1.0, _v(24, 0.1, 30), _v(0.35, 0.35, 0.37), r.cube, -1, MAT_PBR, 1, rough, 0.0))
    r.push(DrawItem(0, _v(-0.9, 0.6, -6), 0.0, 0.0, 0.0, 1.0, _v(1.2, 1.2, 1.2), _v(0.85, 0.1, 0.08), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(1.6, 0.5, -8), 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(0.1, 0.2, 0.9), r.cube, -1, MAT_COLOR))


def setup[P: RenderPass, F: PostEffect, A: AuxTarget](device: Device, mut r: SceneRendererOf[P, F, A], linear: Bool) raises:
    r.set_environment(device, sky_environment(_v(0.35, 0.55, 0.9), _v(0.75, 0.8, 0.85), _v(0.3, 0.28, 0.25)))
    if linear:
        r.set_atmosphere(device, _v(0.35, 0.55, 0.9), _v(0.75, 0.8, 0.85), 0.0, 1.0, False, True)
    r.ssr_intensity = 1.0


def px_at(px: List[UInt8], x: Int, y: Int) -> Tuple[Int, Int, Int]:
    var o = (y * Int(W) + x) * 4
    return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def worst_in(a: List[UInt8], b: List[UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> Int:
    var m = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            var o = (y * Int(W) + x) * 4
            for c in range(3):
                m = max(m, abs(Int(a[o + c]) - Int(b[o + c])))
    return m


def project(v: View, p: Vec3) -> Tuple[Int, Int]:
    var c = v.project(p)
    return (Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W)), Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(H)))


def dump(dir: String, name: String, px: List[UInt8]) raises:
    if dir == "":
        return
    with open(dir + "/" + name + ".rgba", "w") as f:
        f.write_bytes(Span(px))


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
    var t0 = perf_counter_ns()
    _ = rig.shoot(device, r)
    return Float64(perf_counter_ns() - t0) / 1e6


def check_case(mut s: Suite, device: Device, format: UInt32, linear: Bool, dir: String) raises:
    var tag = String("linear workflow: ") if linear else String("")
    var view = view_for(W, H)
    var rig = Rig(device, format, W, H)
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    setup(device, plain, linear)
    var base = rig.shoot(device, plain)
    var r = SceneRendererOf[DefaultPasses, Ssr, Aux[SurfacePasses]](device, format, view)
    setup(device, r, linear)
    r.ssr_intensity = 0.0
    var zero = rig.shoot(device, r)
    print(tag + "intensity 0: pixels that differ from the frame without the stage:", diff(base, zero))
    s.eqi(diff(base, zero), 0, tag + "intensity 0 gives the frame back")
    r.ssr_intensity = 1.0
    var on = rig.shoot(device, r)
    dump(dir, "ssr_off" + ("_linear" if linear else ""), base)
    dump(dir, "ssr_on" + ("_linear" if linear else ""), on)
    # the mirror image of each box's front face, a third of the way up, through the floor (y = 0)
    var red_at = project(view, _v(-0.9, -0.4, -5.4))
    var blue_at = project(view, _v(1.6, -0.33, -7.5))
    var rb = px_at(base, red_at[0], red_at[1])
    var ro = px_at(on, red_at[0], red_at[1])
    var bb = px_at(base, blue_at[0], blue_at[1])
    var bo = px_at(on, blue_at[0], blue_at[1])
    print(tag + "floor under the red box's mirror image at", red_at[0], red_at[1], ": without", rb[0], rb[1], rb[2], ", with", ro[0], ro[1], ro[2])
    print(tag + "floor under the blue box's mirror image at", blue_at[0], blue_at[1], ": without", bb[0], bb[1], bb[2], ", with", bo[0], bo[1], bo[2])
    s.check((ro[0] - ro[2]) - (rb[0] - rb[2]) > 15, tag + "the red box's reflection: the floor turns red where its mirror image is")
    s.check((bo[2] - bo[0]) - (bb[2] - bb[0]) > 15, tag + "the blue box's reflection: the floor turns blue where its mirror image is")
    # the floor's left edge, near the camera: the reflected rays leave through the top of the screen
    var miss = worst_in(base, on, 10, Int(H) - 40, 110, Int(H) - 10)
    print(tag + "near floor, left (rays leave the screen): largest channel difference", miss)
    s.check(miss <= 2, tag + "where the ray misses the frame keeps the environment's reflection (within 2 levels)")
    var rough = rig.shoot(device, plain, 0.9)
    var rough_on = rig.shoot(device, r, 0.9)
    print(tag + "floor roughness 0.9 (max 0.6): pixels changed", diff(rough, rough_on))
    s.eqi(diff(rough, rough_on), 0, tag + "a surface rougher than ssr_max_roughness is left as it was")


def main() raises:
    var s = Suite("ssr_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var dir = String("")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dir = String(args[i + 1])
        if args[i] == "--cost":
            comptime CW: UInt32 = 1920
            comptime CH: UInt32 = 1080
            var rig = Rig(device, format, CW, CH)
            var v = view_for(CW, CH)
            var copy = SceneRendererOf[DefaultPasses, Stage[Copy]](device, format, v)
            var aux = SceneRendererOf[DefaultPasses, Stage[Copy], Aux[SurfacePasses]](device, format, v)
            var ssr = SceneRendererOf[DefaultPasses, Ssr, Aux[SurfacePasses]](device, format, v)
            setup(device, copy, True)
            setup(device, aux, True)
            setup(device, ssr, True)
            var t = List[List[Float64]]()
            for _ in range(3):
                t.append(List[Float64]())
            for k in range(11):
                var ms = [timed(device, copy, rig), timed(device, aux, rig), timed(device, ssr, rig)]
                if k >= 2:
                    for i in range(3):
                        t[i].append(ms[i])
            var names = ["one copy stage", "one copy stage + the surface aux pass", "Ssr + the surface aux pass"]
            var med = List[Float64]()
            for i in range(3):
                med.append(_median(t[i]))
            print("frame cost at", Int(CW), "x", Int(CH), "on lavapipe (a CPU rasteriser: not GPU times), median of 9 frames")
            print("| pipeline | ms / frame | added over one copy stage |")
            print("|---|---:|---:|")
            for i in range(3):
                print("|", names[i], "|", ms2(med[i]), "|", "-" if i == 0 else "+" + ms2(med[i] - med[0]), "|")
            return
    check_case(s, device, format, False, dir)
    check_case(s, device, format, True, dir)
    # no surface target: the aux view is the scene's colour, whose alpha (255) reads as "no surface data"
    var view = view_for(W, H)
    var rig = Rig(device, format, W, H)
    var plain = SceneRendererOf[DefaultPasses](device, format, view)
    setup(device, plain, False)
    var base = rig.shoot(device, plain)
    var bare = SceneRendererOf[DefaultPasses, Ssr](device, format, view)
    setup(device, bare, False)
    var b = rig.shoot(device, bare)
    print("no surface target (NoAux): pixels that differ from the frame without the stage:", diff(base, b))
    s.eqi(diff(base, b), 0, "without the surface target the stage gives the frame back")
    s.finish()
