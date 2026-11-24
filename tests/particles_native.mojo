# tier: integration
# The particle pass (#121) on native wgpu (lavapipe in CI), 480 x 270, read back. The simulation itself is tested without a
# GPU in tests/particles.mojo; here the checks are about what reaches the frame:
#   - a burst draws, and the same frame without the emitter differs from it on many pixels
#   - depth: particles behind a cube leave the pixels inside the cube's front face unchanged; in front they change them
#   - alpha order: red particles near, blue far, 0.6 opaque: the overlap is red-dominant, and adding the emitters in the
#     other order gives the same frame byte for byte (the pass sorts)
#   - additive: two overlapping additive particles are brighter than one, and the result does not depend on the order
#   - the tile means of the fixed burst's frame against tests/golden/particles_frame_tiles.txt, within 2 / 255
#     (`particles_native --record` rewrites it)
#   - the cost of a frame with 1k / 10k / 100k live particles (printed; lavapipe is a CPU rasteriser, so these are not GPU times)
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from game.particles import ParticleSystem
from game.particles_table import particles_default_table, particles_row, ParticlesRow, PARTICLES_BLEND_ADD
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.particle_pass import ParticlePass

comptime W: UInt32 = 480
comptime H: UInt32 = 270
comptime TILE = 30
comptime TILES_FILE = "tests/golden/particles_frame_tiles.txt"
comptime Passes = Then[DefaultPasses, ParticlePass]

comptime S_NONE = 0
comptime S_BURST = 1  # the fixed burst: `spark`, seed 7, 20 steps
comptime S_BEHIND = 2  # one 3 m disc behind the cube, wider than it
comptime S_FRONT = 3  # the same in front of the cube
comptime S_RED_FIRST = 4  # alpha: red near, blue far, red added first
comptime S_BLUE_FIRST = 5  # the same, blue added first
comptime S_ADD_ONE = 6
comptime S_ADD_TWO = 7
comptime S_ADD_TWO_REV = 8


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view() -> View:
    var aspect = Real(Float32(W) / Float32(H))
    var eye = _v(0, 2.5, 7)
    return View(CameraPose(eye, look_rotation(_v(0, 0.8, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)


def blob(color: List[Float64], size: Float64, additive: Bool) raises -> ParticlesRow:
    """One particle that stays where it is born: a still disc of `color`, `size` metres wide."""
    var r = particles_row(particles_default_table(), "dust")
    r.rate = 0.0
    r.burst_count = 1
    r.speed_min = 0.0
    r.speed_max = 0.0
    r.gravity = [0.0, 0.0, 0.0]
    r.drag = 0.0
    r.lifetime_min = 100.0
    r.lifetime_max = 100.0
    r.size_curve = [size]
    r.size_jitter = 0.0
    r.color_start = color.copy()
    r.color_mid = color.copy()
    r.color_end = color.copy()
    r.blend = 1 if additive else 0
    return r^


def cloud(n: Int, size: Float64) raises -> ParticlesRow:
    """N still alpha particles spread by a wide cone, for depth tests and the cost rows."""
    var r = blob([1.0, 0.8, 0.2, 0.7], size, False)
    r.burst_count = n
    r.max_particles = n
    r.speed_min = 0.5
    r.speed_max = 2.5
    r.cone_deg = 60.0
    r.drag = 0.0
    r.direction = [0.0, 0.0, 1.0]
    return r^


def setup(mut ps: ParticleSystem, scenario: Int) raises:
    if scenario == S_BURST:
        _ = ps.add(particles_row(particles_default_table(), "spark"), 0.0, 1.0, 1.0, 7)
    elif scenario == S_BEHIND:
        _ = ps.add(blob([1.0, 0.9, 0.1, 0.9], 3.0, False), -1.5, 1.0, -1.5, 3)
    elif scenario == S_FRONT:
        _ = ps.add(blob([1.0, 0.9, 0.1, 0.9], 3.0, False), -1.5, 1.0, 2.0, 3)
    elif scenario == S_RED_FIRST or scenario == S_BLUE_FIRST:
        var red = blob([1.0, 0.0, 0.0, 0.6], 2.0, False)
        var blue = blob([0.0, 0.0, 1.0, 0.6], 2.0, False)
        if scenario == S_RED_FIRST:
            _ = ps.add(red^, 1.0, 1.5, 3.0, 1)
            _ = ps.add(blue^, 1.0, 1.5, 1.0, 2)
        else:
            _ = ps.add(blue^, 1.0, 1.5, 1.0, 2)
            _ = ps.add(red^, 1.0, 1.5, 3.0, 1)
    elif scenario == S_ADD_ONE:
        _ = ps.add(blob([0.3, 0.2, 0.1, 1.0], 2.0, True), 1.0, 1.5, 3.0, 1)
    elif scenario == S_ADD_TWO:
        _ = ps.add(blob([0.3, 0.2, 0.1, 1.0], 2.0, True), 1.0, 1.5, 3.0, 1)
        _ = ps.add(blob([0.1, 0.2, 0.3, 1.0], 2.0, True), 1.0, 1.5, 1.0, 2)
    elif scenario == S_ADD_TWO_REV:
        _ = ps.add(blob([0.1, 0.2, 0.3, 1.0], 2.0, True), 1.0, 1.5, 1.0, 2)
        _ = ps.add(blob([0.3, 0.2, 0.1, 1.0], 2.0, True), 1.0, 1.5, 3.0, 1)


def scene(mut r: SceneRendererOf[Passes]) raises:
    r.begin(view())
    r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(16, 0.5, 16), _v(0.6, 0.65, 0.55), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(-1.5, 1.0, 0), 0.0, 0.0, 0.0, 1.0, _v(1.2, 2.0, 1.2), _v(0.85, 0.3, 0.25), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), r.sphere, -1, MAT_SKY))


def read_back(device: Device, mut cap: FrameCapture, target: Texture) raises -> List[UInt8]:
    var req = cap.capture(device, target.handle().raw)
    req.wait()
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(W))
    var out = List[UInt8]()
    for y in range(Int(H)):
        for x in range(Int(W) * 4):
            out.append(px[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


def frame(device: Device, mut cap: FrameCapture, target: Texture, hud: Hud, scenario: Int, steps: Int) raises -> List[UInt8]:
    var r = SceneRendererOf[Passes](device, WGPUTextureFormat.RGBA8Unorm, view())
    setup(r.passes.second.system, scenario)
    for _ in range(steps):
        r.passes.second.advance(1.0 / 60.0, view())
    scene(r)
    r.draw(device, target.handle().raw, W, H, hud)
    return read_back(device, cap, target)


def changed(a: List[UInt8], b: List[UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> Int:
    """Pixels in the rectangle whose colour differs by more than 6 / 255 in total."""
    var n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            var o = (y * Int(W) + x) * 4
            if abs(Int(a[o]) - Int(b[o])) + abs(Int(a[o + 1]) - Int(b[o + 1])) + abs(Int(a[o + 2]) - Int(b[o + 2])) > 6:
                n += 1
    return n


def equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def project(p: Vec3) -> Tuple[Int, Int]:
    """Pixel of a world point under view()."""
    var v = view()
    var d = p - v.eye
    var x = Float64(d[0] * v.right[0] + d[1] * v.right[1] + d[2] * v.right[2])
    var y = Float64(d[0] * v.up[0] + d[1] * v.up[1] + d[2] * v.up[2])
    var z = Float64(d[0] * v.fwd[0] + d[1] * v.fwd[1] + d[2] * v.fwd[2])
    return (Int((x * Float64(v.sx) / z * 0.5 + 0.5) * Float64(W)), Int((0.5 - y * Float64(v.sy) / z * 0.5) * Float64(H)))


def lum(a: List[UInt8], x: Int, y: Int) -> Int:
    var o = (y * Int(W) + x) * 4
    return Int(a[o]) + Int(a[o + 1]) + Int(a[o + 2])


def main() raises:
    var record = False
    for a in argv():
        if String(a) == "--record":
            record = True
    var s = Suite("particles_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="particles")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    print("pass list:", Passes.sig())

    var none = frame(device, cap, target, hud, S_NONE, 20)
    var burst = frame(device, cap, target, hud, S_BURST, 20)
    var d_burst = changed(burst, none, 0, 0, Int(W), Int(H))
    print("burst: pixels changed against the frame without the emitter:", d_burst)
    s.check(d_burst > 300, "a burst of 400 sparks changes the frame")
    var again = frame(device, cap, target, hud, S_BURST, 20)
    s.check(equal(burst, again), "the same burst renders to the same bytes twice")

    # depth: the cube's front face is x -2.1 .. -0.9, y 0 .. 2 at z = 0.6; take its middle
    var p0 = project(_v(-1.95, 0.15, 0.6))
    var p1 = project(_v(-1.05, 1.85, 0.6))
    var c0 = (min(p0[0], p1[0]), min(p0[1], p1[1]))
    var c1 = (max(p0[0], p1[0]), max(p0[1], p1[1]))
    var behind = frame(device, cap, target, hud, S_BEHIND, 1)
    var front = frame(device, cap, target, hud, S_FRONT, 1)
    var in_behind = changed(behind, none, c0[0], c0[1], c1[0], c1[1])
    var in_front = changed(front, none, c0[0], c0[1], c1[0], c1[1])
    var around_behind = changed(behind, none, 0, 0, Int(W), Int(H))
    print("cube face rectangle", c0[0], c0[1], "-", c1[0], c1[1], ": changed pixels, particles behind the cube", in_behind, "; in front", in_front, "; whole frame, behind", around_behind)
    s.check(around_behind > 2000, "the particles behind the cube are on screen (outside the face)")
    s.eqi(in_behind, 0, "particles behind the cube do not show through its face")
    s.check(in_front * 2 > (c1[0] - c0[0]) * (c1[1] - c0[1]), "the same particles in front of the cube cover its face")

    # alpha order
    var rf = frame(device, cap, target, hud, S_RED_FIRST, 1)
    var bf = frame(device, cap, target, hud, S_BLUE_FIRST, 1)
    var mid = project(_v(1.0, 1.5, 2.0))
    var o = (mid[1] * Int(W) + mid[0]) * 4
    print("alpha overlap at the centre (r g b): red added first", Int(rf[o]), Int(rf[o + 1]), Int(rf[o + 2]), "; blue added first", Int(bf[o]), Int(bf[o + 1]), Int(bf[o + 2]))
    s.check(Int(rf[o]) > Int(rf[o + 2]) + 40, "near red over far blue: the overlap is red-dominant")
    s.check(equal(rf, bf), "the order the emitters were added in does not change the frame (sorted by depth)")

    # additive
    var a1 = frame(device, cap, target, hud, S_ADD_ONE, 1)
    var a2 = frame(device, cap, target, hud, S_ADD_TWO, 1)
    var a2r = frame(device, cap, target, hud, S_ADD_TWO_REV, 1)
    var ao = (mid[1] * Int(W) + mid[0]) * 4
    print("additive centre r+g+b: none", lum(none, mid[0], mid[1]), "; one particle", lum(a1, mid[0], mid[1]), "; two", lum(a2, mid[0], mid[1]))
    s.check(lum(a1, mid[0], mid[1]) > lum(none, mid[0], mid[1]) + 40, "an additive particle brightens the frame")
    s.check(lum(a2, mid[0], mid[1]) > lum(a1, mid[0], mid[1]) + 40, "two overlapping additive particles are brighter than one")
    s.check(equal(a2, a2r), "additive blending does not depend on the order")
    _ = ao

    # tile means of the fixed burst, against the reference
    var tx = Int(W) // TILE
    var ty = Int(H) // TILE
    var lines = List[String]()
    var worst = 0
    var want = List[String]()
    if not record:
        with open(TILES_FILE, "r") as f:
            for line in f.read().split("\n"):
                if line.strip().byte_length() > 0:
                    want.append(String(line.strip()))
        s.eqi(len(want), tx * ty, "the reference has one line per tile (16 x 9)")
    for t in range(tx * ty):
        var x0 = (t % tx) * TILE
        var y0 = (t // tx) * TILE
        var sum = List[Int](length=3, fill=0)
        for y in range(y0, y0 + TILE):
            for x in range(x0, x0 + TILE):
                for c in range(3):
                    sum[c] += Int(burst[(y * Int(W) + x) * 4 + c])
        var n = TILE * TILE
        var line = String(sum[0] // n) + " " + String(sum[1] // n) + " " + String(sum[2] // n)
        lines.append(line)
        if not record and t < len(want):
            var b = want[t].split(" ")
            for c in range(3):
                worst = max(worst, abs(sum[c] // n - Int(String(b[c]))))
    if record:
        with open(TILES_FILE, "w") as f:
            for i in range(len(lines)):
                f.write(lines[i] + "\n")
        print("recorded", len(lines), "tiles to", TILES_FILE)
        return
    print("worst tile channel difference against the reference:", worst, "of 255")
    s.check(worst <= 2, "every tile's mean colour is within 2 / 255 of the reference")

    # frame cost: scene_none, then n live alpha particles; prepare (sort, pack, upload) + record + submit + readback
    for n in [1000, 10000, 100000]:
        var r = SceneRendererOf[Passes](device, WGPUTextureFormat.RGBA8Unorm, view())
        _ = r.passes.second.system.add(cloud(n, 0.05), 0.0, 1.0, 0.0, 5)
        r.passes.second.advance(1.0 / 60.0, view())
        s.eqi(r.passes.second.system.live_total, n, "n particles live")
        var times = List[Float64]()
        for _ in range(5):
            scene(r)
            var t0 = perf_counter_ns()
            r.draw(device, target.handle().raw, W, H, hud)
            _ = read_back(device, cap, target)
            times.append(Float64(perf_counter_ns() - t0) / 1e6)
        var t_pack = List[Float64]()
        var staging = List[Float32]()
        for _ in range(5):
            staging.clear()
            var t0 = perf_counter_ns()
            _ = r.passes.second.system.pack(0.0, 2.5, 7.0, 0.0, 0.0, -1.0, staging, 131072)
            t_pack.append(Float64(perf_counter_ns() - t0) / 1e6)
        var med = _median(times)
        var med_pack = _median(t_pack)
        print("frame cost,", n, "particles: draw + readback", med, "ms (median of 5); sort + pack alone", med_pack, "ms")
    s.finish()


def _median(v: List[Float64]) -> Float64:
    var c = v.copy()
    for i in range(1, len(c)):
        var x = c[i]
        var j = i - 1
        while j >= 0 and c[j] > x:
            c[j + 1] = c[j]
            j -= 1
        c[j + 1] = x
    return c[len(c) // 2]
