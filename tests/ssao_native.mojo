# tier: integration
# Screen-space ambient occlusion (app/ssao.mojo) on native wgpu (lavapipe).
#   A grey floor and a 1 m cube on it under a uniform environment and no sun (the ambient is the only light), the camera
#   3 m up looking at the cube. With the occlusion on, the floor 0.1 m in front of the cube's foot is darker than without
#   (the cube covers part of its sky); the floor 2.5 m away, outside the 0.5 m radius, is not changed. Intensity 0 after
#   a frame with it on gives the frame without it, pixel for pixel, and its textures shrink back to 1 x 1.
#   temporal  two frames in a row of a still scene: the sampling pattern turns every frame, so the result flickers;
#   with ao_temporal 0.9 the mean difference between the frames falls.
#   cost  `ssao_native --cost`: frame times at 1920 x 1080 (lavapipe, a CPU rasteriser: not GPU times).
# `ssao_native --dump DIR` writes the frames as DIR/*.rgba (640 x 360; scripts/tier4_shots.py makes PNGs).
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
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
from app.render_pass import Then
from app.shadow_pass import ShadowPass
from app.lights import uniform_environment, sun_shadow_vp

comptime W: UInt32 = 640
comptime H: UInt32 = 360
comptime Lit = Then[ShadowPass, DefaultPasses]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 3, 0), look_rotation(_v(0, -0.55, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 200.0), aspect)


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
            w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="ssao_target",
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

    def shoot(mut self, device: Device, mut r: SceneRendererOf[Lit]) raises -> List[UInt8]:
        r.begin(view_for(self.w, self.h))
        r.push(DrawItem(0, _v(0, -0.05, -15), 0.0, 0.0, 0.0, 1.0, _v(40, 0.1, 40), _v(0.6, 0.6, 0.6), r.cube, -1, MAT_COLOR))
        r.push(DrawItem(0, _v(0, 0.5, -5), 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(0.8, 0.5, 0.3), r.cube, -1, MAT_COLOR))
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


def setup(device: Device, mut r: SceneRendererOf[Lit]) raises:
    var to_sun = _v(0.3, 0.9, 0.3)
    r.set_environment(device, uniform_environment(_v(0.7, 0.7, 0.7)))
    r.set_sun(device, to_sun, _v(1, 1, 1), 0.0)
    r.set_shadow(device, sun_shadow_vp(to_sun, _v(0, 0, -10), 30.0, 60.0), False)


def px_at(px: List[UInt8], x: Int, y: Int, w: Int = Int(W)) -> Int:
    var o = (y * w + x) * 4
    return (Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2])) // 3


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def mean_abs(a: List[UInt8], b: List[UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> Float64:
    var sum = 0
    var n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            var o = (y * Int(W) + x) * 4
            for c in range(3):
                sum += abs(Int(a[o + c]) - Int(b[o + c]))
                n += 1
    return Float64(sum) / Float64(n)


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


def timed(device: Device, mut r: SceneRendererOf[Lit], mut rig: Rig) raises -> Float64:
    var t0 = perf_counter_ns()
    _ = rig.shoot(device, r)
    return Float64(perf_counter_ns() - t0) / 1e6


def main() raises:
    var s = Suite("ssao_native")
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
            var off = SceneRendererOf[Lit](device, format, v)
            var on = SceneRendererOf[Lit](device, format, v)
            setup(device, off)
            setup(device, on)
            on.ao_intensity = 1.0
            on.ao_temporal = 0.9
            var t = List[List[Float64]]()
            for _ in range(2):
                t.append(List[Float64]())
            for k in range(11):
                var ms = [timed(device, off, rig), timed(device, on, rig)]
                if k >= 2:
                    for i in range(2):
                        t[i].append(ms[i])
            var med0 = _median(t[0])
            var med1 = _median(t[1])
            print("frame cost at", Int(CW), "x", Int(CH), "on lavapipe (a CPU rasteriser: not GPU times), median of 9 frames")
            print("| pipeline | ms / frame | added |")
            print("|---|---:|---:|")
            print("| no occlusion | ", ms2(med0), " | - |")
            print("| ambient occlusion, temporal 0.9 | ", ms2(med1), " | +", ms2(med1 - med0), " |")
            return
    var view = view_for(W, H)
    var rig = Rig(device, format, W, H)
    var r = SceneRendererOf[Lit](device, format, view)
    setup(device, r)
    var base = rig.shoot(device, r)
    print("textures of the occlusion while it is off:", r.ssao.bytes(), "bytes")
    s.eqi(r.ssao.bytes(), 3 * 8, "off: three 1 x 1 RGBA16Float targets")
    r.ao_intensity = 1.0
    r.ao_radius = 0.5
    var on = rig.shoot(device, r)
    print("textures of the occlusion while it is on:", r.ssao.bytes(), "bytes (", Int(W), "x", Int(H), "x 24 =", Int(W) * Int(H) * 24, ")")
    s.eqi(r.ssao.bytes(), Int(W) * Int(H) * 24, "on: three RGBA16Float targets of the scene's size")
    dump(dir, "ssao_off", base)
    dump(dir, "ssao_on", on)
    # the floor 0.1 m in front of the cube's foot (its front face is at z = -4.5), and 2.5 m to the side of it
    var near = project(view, _v(0, 0, -4.4))
    var far = project(view, _v(3.0, 0, -4.4))
    var nb = px_at(base, near[0], near[1])
    var no = px_at(on, near[0], near[1])
    var fb = px_at(base, far[0], far[1])
    var fo = px_at(on, far[0], far[1])
    print("floor 0.1 m from the cube's foot at", near[0], near[1], ": without", nb, ", with", no)
    print("floor 2.5 m from the cube at", far[0], far[1], ": without", fb, ", with", fo)
    s.check(nb - no > 15, "the floor at the cube's foot is darker (more than 15 levels)")
    s.check(abs(fb - fo) <= 2, "the floor outside the radius is left as it was (within 2 levels)")
    # the cube's top, 0.5 m from its edges, has nothing above it
    var top = project(view, _v(0, 1.0, -5.0))
    var tb = px_at(base, top[0], top[1])
    var to = px_at(on, top[0], top[1])
    print("the cube's top centre at", top[0], top[1], ": without", tb, ", with", to)
    s.check(abs(tb - to) <= 3, "the open top of the cube is left as it was (within 3 levels)")
    r.ao_intensity = 0.0
    var back = rig.shoot(device, r)
    print("intensity back to 0: pixels that differ from the frame without it:", diff(base, back))
    s.eqi(diff(base, back), 0, "intensity 0 gives the frame back")
    s.eqi(r.ssao.bytes(), 3 * 8, "intensity 0 returns the textures")
    # temporal accumulation: two frames in a row of the still scene, 8 frames in
    var raw0 = SceneRendererOf[Lit](device, format, view)
    var acc = SceneRendererOf[Lit](device, format, view)
    setup(device, raw0)
    setup(device, acc)
    raw0.ao_intensity = 1.0
    acc.ao_intensity = 1.0
    acc.ao_temporal = 0.9
    var a1 = List[UInt8]()
    var a2 = List[UInt8]()
    var b1 = List[UInt8]()
    var b2 = List[UInt8]()
    for k in range(9):
        var fa = rig.shoot(device, raw0)
        var fb2 = rig.shoot(device, acc)
        if k == 7:
            a1 = fa^
            b1 = fb2^
        elif k == 8:
            a2 = fa^
            b2 = fb2^
    var x0 = near[0] - 60
    var x1 = near[0] + 60
    var flicker0 = mean_abs(a1, a2, x0, near[1] - 6, x1, near[1] + 6)
    var flicker1 = mean_abs(b1, b2, x0, near[1] - 6, x1, near[1] + 6)
    print("mean difference between two frames in a row near the cube's foot: temporal 0:", flicker0, ", temporal 0.9:", flicker1)
    s.check(flicker0 > 0.1, "without accumulation the frames differ (the sampling turns)")
    s.check(flicker1 < 0.5 * flicker0, "with ao_temporal 0.9 the difference falls to less than half")
    dump(dir, "ssao_temporal", b2)
    s.finish()
