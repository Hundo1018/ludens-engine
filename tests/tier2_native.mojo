# tier: integration
# Decals and trails (#140) on native wgpu (lavapipe in CI), in the tier 2 reference frame (app/tier2_frame.mojo:
# terrain, a cube, two decals, two trails), 480 x 270, read back. The CPU sides are tests/decals_trails.mojo; the
# terrain pass alone is tests/terrain_native.mojo. Checks:
#   - each feature changes the frame: decals on (terrain and cube), trails on
#   - the scorch decal darkens the terrain at its centre; the cube's mark is red on the cube's face
#   - a decal budget of 0 triangles draws the frame without decals, byte for byte, and counts both decals over budget
#   - alpha trails are sorted: adding two crossing alpha trails in the other order gives the same bytes
#   - additive: the tyre mark brightens what is under it
#   - the frame renders to the same bytes twice; tile means against tests/golden/tier2_frame_tiles.txt within 2 / 255
#     (`tier2_native --record` rewrites it; `--dump` writes build/tier2_ref.rgba)
#   - the frame time each feature adds, at 480 x 270 and 1920 x 1080 (lavapipe: a CPU rasteriser, not GPU times)
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.camera_view import View
from game.trails import TrailStyle, TRAIL_BLEND_ALPHA
from geometry.vec import Real, Vec3
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf
from app.tier2_frame import Tier2Passes, tier2_setup, tier2_items, tyre_point, tier2_view, tier2_field, CUBE_X, CUBE_Z, TIER2_FRAME_W, TIER2_FRAME_H

comptime W = TIER2_FRAME_W
comptime H = TIER2_FRAME_H
comptime TILE = 30
comptime TILES_FILE = "tests/golden/tier2_frame_tiles.txt"

comptime X_NONE = 0
comptime X_BUDGET0 = 1  # decal budget 0
comptime X_CROSS_AB = 2  # two crossing alpha trails, red added first
comptime X_CROSS_BA = 3


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def read_back(device: Device, mut cap: FrameCapture, target: Texture, w: UInt32, h: UInt32) raises -> List[UInt8]:
    var req = cap.capture(device, target.handle().raw)
    req.wait()
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(w))
    var out = List[UInt8]()
    for y in range(Int(h)):
        for x in range(Int(w) * 4):
            out.append(px[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


def cross_style(r: Float64, g: Float64, b: Float64) raises -> TrailStyle:
    return TrailStyle(10.0, 0.1, 256, [0.8], [r, g, b, 0.7], [r, g, b, 0.7], [r, g, b, 0.7], TRAIL_BLEND_ALPHA)


def frame(
    device: Device, mut cap: FrameCapture, target: Texture, hud: Hud, terrain: Bool, decals: Bool, trails: Bool,
    extra: Int = X_NONE,
) raises -> List[UInt8]:
    var r = SceneRendererOf[Tier2Passes](device, WGPUTextureFormat.RGBA8Unorm, tier2_view())
    if extra == X_BUDGET0:
        r.passes.second.second.first.decals.max_triangles = 0
    if extra == X_CROSS_AB or extra == X_CROSS_BA:
        ref tp = r.passes.second.second.second
        var first = tp.trails.add(cross_style(1.0, 0.1, 0.1) if extra == X_CROSS_AB else cross_style(0.1, 0.2, 1.0))
        var second = tp.trails.add(cross_style(0.1, 0.2, 1.0) if extra == X_CROSS_AB else cross_style(1.0, 0.1, 0.1))
        var red = first if extra == X_CROSS_AB else second
        var blue = second if extra == X_CROSS_AB else first
        for i in range(30):
            var u = Float64(i) / 29.0
            tp.trails.trails[red].move_to(0.0, CUBE_X - 6.0 + 4.0 * u, 4.0, CUBE_Z - 7.0)  # nearer the camera
            tp.trails.trails[blue].move_to(0.0, CUBE_X - 4.0, 2.5 + 3.0 * u, CUBE_Z - 4.0)
    tier2_setup(r, device, terrain, decals, trails)
    r.draw(device, target.handle().raw, W, H, hud)
    if extra == X_BUDGET0:
        print("decal budget 0: over budget", r.passes.second.second.first.decals.over_budget, "; triangles drawn", r.passes.second.second.first.triangles)
    return read_back(device, cap, target, W, H)


def changed(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(len(a) // 4):
        var o = i * 4
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
    var v = tier2_view()
    var d = p - v.eye
    var x = Float64(d[0] * v.right[0] + d[1] * v.right[1] + d[2] * v.right[2])
    var y = Float64(d[0] * v.up[0] + d[1] * v.up[1] + d[2] * v.up[2])
    var z = Float64(d[0] * v.fwd[0] + d[1] * v.fwd[1] + d[2] * v.fwd[2])
    return (Int((x * Float64(v.sx) / z * 0.5 + 0.5) * Float64(W)), Int((0.5 - y * Float64(v.sy) / z * 0.5) * Float64(H)))


def rgb(a: List[UInt8], p: Tuple[Int, Int]) -> List[Int]:
    var o = (p[1] * Int(W) + p[0]) * 4
    return [Int(a[o]), Int(a[o + 1]), Int(a[o + 2])]


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


def main() raises:
    var record = False
    var dump = False
    for a in argv():
        if String(a) == "--record":
            record = True
        if String(a) == "--dump":
            dump = True
    var s = Suite("tier2_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="tier2")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    print("pass list:", Tier2Passes.sig())

    var full = frame(device, cap, target, hud, True, True, True)
    var no_decals = frame(device, cap, target, hud, True, False, True)
    var no_trails = frame(device, cap, target, hud, True, True, False)
    var d_dec = changed(full, no_decals)
    var d_tr = changed(full, no_trails)
    print("pixels changed by the decals", d_dec, "; by the trails", d_tr)
    s.check(d_dec > 500, "the decals change the frame")
    s.check(d_tr > 500, "the trails change the frame")

    var f = tier2_field()
    var ground = Float64(f.height(Int(CUBE_X / 0.5), Int(CUBE_Z / 0.5)))
    var sc = project(_v(CUBE_X - 2.5, Float64(f.height(Int((CUBE_X - 2.5) / 0.5), Int((CUBE_Z - 2.0) / 0.5))), CUBE_Z - 2.0))
    var bare = frame(device, cap, target, hud, True, False, False)  # terrain and cube only: the trails would cover the spot
    var with_sc = rgb(no_trails, sc)
    var without_sc = rgb(bare, sc)
    print("scorch centre pixel", sc[0], sc[1], ": with", with_sc[0], with_sc[1], with_sc[2], "; without", without_sc[0], without_sc[1], without_sc[2])
    s.check(with_sc[0] + with_sc[1] + with_sc[2] + 150 < without_sc[0] + without_sc[1] + without_sc[2], "the scorch darkens the terrain at its centre")
    var mk = project(_v(CUBE_X, ground + 1.1, CUBE_Z - 1.0))
    var with_mk = rgb(full, mk)
    var without_mk = rgb(no_decals, mk)
    print("cube mark pixel", mk[0], mk[1], ": with", with_mk[0], with_mk[1], with_mk[2], "; without", without_mk[0], without_mk[1], without_mk[2])
    s.check(with_mk[0] > with_mk[1] + 80 and without_mk[0] < without_mk[1] + 30, "the cube's face is red under the mark and grey without it")

    var budget0 = frame(device, cap, target, hud, True, True, True, X_BUDGET0)
    s.check(equal(budget0, no_decals), "a decal budget of 0 triangles draws the frame without decals, byte for byte")

    var ab = frame(device, cap, target, hud, True, True, True, X_CROSS_AB)
    var ba = frame(device, cap, target, hud, True, True, True, X_CROSS_BA)
    print("crossing alpha trails change", changed(ab, full), "pixels against the plain frame")
    s.check(changed(ab, full) > 200, "the crossing trails are drawn")
    s.check(equal(ab, ba), "alpha trails added in the other order give the same bytes (sorted far to near)")

    # the tyre mark (additive, flat) brightens what is under it: its middle point at t = 1 s
    var tp = tyre_point(f, 1.0)
    var ty = project(_v(tp[0], tp[1], tp[2]))
    var t_on = rgb(full, ty)
    var t_off = rgb(no_trails, ty)
    print("tyre mark pixel: with", t_on[0], t_on[1], t_on[2], "; without", t_off[0], t_off[1], t_off[2])
    s.check(t_on[2] > t_off[2] + 30 and t_on[0] >= t_off[0], "the additive mark adds blue and takes nothing away")

    var again = frame(device, cap, target, hud, True, True, True)
    s.check(equal(full, again), "the frame renders to the same bytes twice")
    if dump:
        with open("build/tier2_ref.rgba", "w") as fo:
            fo.write_bytes(full)
    var tx = Int(W) // TILE
    var ty2 = Int(H) // TILE
    var lines = List[String]()
    var worst = 0
    var want = List[String]()
    if not record:
        with open(TILES_FILE, "r") as fi:
            for line in fi.read().split("\n"):
                if line.strip().byte_length() > 0:
                    want.append(String(line.strip()))
        s.eqi(len(want), tx * ty2, "the reference has one line per tile (16 x 9)")
    for t in range(tx * ty2):
        var x0 = (t % tx) * TILE
        var y0 = (t // tx) * TILE
        var sum = List[Int](length=3, fill=0)
        for y in range(y0, y0 + TILE):
            for x in range(x0, x0 + TILE):
                for c in range(3):
                    sum[c] += Int(full[(y * Int(W) + x) * 4 + c])
        var n = TILE * TILE
        lines.append(String(sum[0] // n) + " " + String(sum[1] // n) + " " + String(sum[2] // n))
        if not record and t < len(want):
            var b = want[t].split(" ")
            for c in range(3):
                worst = max(worst, abs(sum[c] // n - Int(String(b[c]))))
    if record:
        with open(TILES_FILE, "w") as fo:
            for i in range(len(lines)):
                fo.write(lines[i] + "\n")
        print("recorded", len(lines), "tiles to", TILES_FILE)
    else:
        print("worst tile channel difference against the reference:", worst, "of 255")
        s.check(worst <= 2, "every tile's mean colour is within 2 / 255 of the reference")

    # frame time each feature adds: draw + readback, median of 7, the same scene with the features added one by one
    for wh in [(UInt32(480), UInt32(270)), (UInt32(1920), UInt32(1080))]:
        var fw = wh[0]
        var fh = wh[1]
        var tgt = device.create_texture(fw, fh, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="tier2_cost")
        var cp = FrameCapture(device, fw, fh)
        var hd = Hud(device, format)
        var dl2 = DrawList()
        hd.set(dl2, Float32(fw), Float32(fh))
        var cube_y = ground + 0.9
        var names: List[String] = ["cube and sky", "+ terrain", "+ decals", "+ trails"]
        var rs = List[SceneRendererOf[Tier2Passes]]()
        for step in range(4):
            var r = SceneRendererOf[Tier2Passes](device, format, tier2_view())
            tier2_setup(r, device, step >= 1, step >= 2, step >= 3)
            rs.append(r^)
        var times = List[List[Float64]]()
        for _ in range(4):
            times.append(List[Float64]())
        for _ in range(15):  # rounds, the four scenes interleaved so drift in the machine's speed hits all four alike
            for step in range(4):
                tier2_items(rs[step], cube_y)
                var t0 = perf_counter_ns()
                rs[step].draw(device, tgt.handle().raw, fw, fh, hd)
                _ = read_back(device, cp, tgt, fw, fh)
                times[step].append(Float64(perf_counter_ns() - t0) / 1e6)
        print("frame cost at", fw, "x", fh, "(draw + readback, median of 15 interleaved rounds, lavapipe):")
        var prev = 0.0
        for i in range(4):
            var m = _median(times[i])
            print("  ", names[i], m, "ms; added", m - prev if i > 0 else 0.0, "ms")
            prev = m
    s.finish()
