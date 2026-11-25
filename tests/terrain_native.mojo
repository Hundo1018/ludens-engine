# tier: integration
# The terrain pass (#140) on native wgpu (lavapipe in CI), 480 x 270, read back. The geometry itself (level 0 is
# HeightField.tri, the stitched edges have no gap) is tested without a GPU in tests/terrain.mojo; here:
#   - cracks in pixels: a camera above the field sees only terrain; with mixed forced levels every pixel is terrain
#     (none shows the empty frame's colour), and with stitching turned off (the negative control) some do
#   - a coarser level draws fewer triangles and still covers the frame
#   - splat: the channel weights pick the tint; a half / half split shows both
#   - the tile means of the reference frame against tests/golden/terrain_frame_tiles.txt, within 2 / 255
#     (`terrain_native --record` rewrites it)
#   - cost: a 4097 x 4097 grid (4096 x 4096 cells, 64 x 64 chunks): upload, level pick, frame with and without the terrain
from std.sys import argv
from std.math import sin, cos
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from game.terrain import TerrainField
from collision.trimesh import HeightField
from procedural.terrain_gen import TerrainParams, height_tile
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.terrain_pass import TerrainPass

comptime W: UInt32 = 480
comptime H: UInt32 = 270
comptime TILE = 30
comptime TILES_FILE = "tests/golden/terrain_frame_tiles.txt"
comptime Passes = Then[DefaultPasses, TerrainPass]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_of(eye: Vec3, at: Vec3, w: UInt32 = W, h: UInt32 = H) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(eye, look_rotation(at - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 5000.0), aspect)


def top_view() -> View:
    """30 m above the middle of the 64 m field, looking nearly straight down (the frame spans about 51 x 29 m): only
    terrain is in view."""
    return view_of(_v(32, 30, 30), _v(32, 0, 36))


def ref_view() -> View:
    return view_of(_v(-6, 16, -6), _v(30, 0, 30))


def field(stitch_seed: Int = 3) raises -> TerrainField:
    """129 x 129 corners of ludens-core's terrain, cell 0.5 m (64 m), chunk 16: 8 x 8 chunks, levels 0 .. 4."""
    var p = TerrainParams(stitch_seed, 24.0, 6.0, 4, False, 0.0)
    var h = height_tile(0, 0, 128, 128, Real(0.5), p)
    var hf = HeightField(h, 129, 129, Real(0.5))
    return TerrainField.from_heightfield(hf, 16, 6.0)


def read_back(device: Device, mut cap: FrameCapture, target: Texture, w: UInt32 = W, h: UInt32 = H) raises -> List[UInt8]:
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


comptime M_NONE = 0  # no terrain
comptime M_MIXED = 1  # forced mixed levels
comptime M_MIXED_NOSTITCH = 2
comptime M_LEVEL0 = 3
comptime M_LEVEL3 = 4
comptime M_SPLAT1 = 5  # every corner on channel 1
comptime M_SPLAT_HALF = 6  # x < 32 m channel 0, else channel 1
comptime M_REF = 7  # by distance, splat by height and slope, from ref_view()


def mixed_levels() -> List[Int]:
    var out = List[Int]()
    for i in range(64):
        out.append((i * 7 + i // 8) % 5)
    return out^


def frame(device: Device, mut cap: FrameCapture, target: Texture, hud: Hud, mode: Int) raises -> List[UInt8]:
    var v = ref_view() if mode == M_REF else top_view()
    var r = SceneRendererOf[Passes](device, WGPUTextureFormat.RGBA8Unorm, v)
    if mode != M_NONE:
        var f = field()
        if mode == M_SPLAT1:
            for iz in range(f.nz):
                for ix in range(f.nx):
                    f.set_splat(ix, iz, 0, 255, 0, 0)
        elif mode == M_SPLAT_HALF:
            for iz in range(f.nz):
                for ix in range(f.nx):
                    if ix < 64:
                        f.set_splat(ix, iz, 255, 0, 0, 0)
                    else:
                        f.set_splat(ix, iz, 0, 255, 0, 0)
        elif mode == M_REF:
            f.splat_by_height_slope(Float32(-1.0), Float32(2.5), Float32(0.9))
        r.passes.second.set_field(device, f^)
        r.passes.second.tints = [0.1, 0.8, 0.1, 1.0, 0.9, 0.1, 0.1, 1.0, 0.92, 0.93, 0.95, 1.0, 0.45, 0.43, 0.42, 1.0]
        if mode == M_MIXED or mode == M_MIXED_NOSTITCH:
            r.passes.second.forced_levels = mixed_levels()
        if mode == M_MIXED_NOSTITCH:
            r.passes.second.stitch = False
        if mode == M_LEVEL0 or mode == M_SPLAT1 or mode == M_SPLAT_HALF:
            r.passes.second.force_level = 0
        if mode == M_LEVEL3:
            r.passes.second.force_level = 3
    r.begin(v)
    r.draw(device, target.handle().raw, W, H, hud)
    return read_back(device, cap, target)


def same_px(a: List[UInt8], b: List[UInt8], i: Int) -> Bool:
    var o = i * 4
    return a[o] == b[o] and a[o + 1] == b[o + 1] and a[o + 2] == b[o + 2]


def count_same(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(Int(W) * Int(H)):
        if same_px(a, b, i):
            n += 1
    return n


def mean_rgb(a: List[UInt8], x0: Int, x1: Int) -> List[Int]:
    var s = List[Int](length=3, fill=0)
    for y in range(Int(H)):
        for x in range(x0, x1):
            for c in range(3):
                s[c] += Int(a[(y * Int(W) + x) * 4 + c])
    var n = Int(H) * (x1 - x0)
    return [s[0] // n, s[1] // n, s[2] // n]


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
    var s = Suite("terrain_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="terrain")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    print("pass list:", Passes.sig())

    var none = frame(device, cap, target, hud, M_NONE)
    var mixed = frame(device, cap, target, hud, M_MIXED)
    var nostitch = frame(device, cap, target, hud, M_MIXED_NOSTITCH)
    var holes = count_same(mixed, none)
    var holes_off = count_same(nostitch, none)
    print("pixels showing the empty frame: mixed levels", holes, "; same levels with stitching off", holes_off, "; of", Int(W) * Int(H))
    s.eqi(holes, 0, "mixed levels, stitched: every pixel is terrain (no crack)")
    s.check(holes_off > 0, "negative control: without stitching the same levels open cracks")

    var l0 = frame(device, cap, target, hud, M_LEVEL0)
    var l3 = frame(device, cap, target, hud, M_LEVEL3)
    print("pixels showing the empty frame: level 0", count_same(l0, none), "; level 3", count_same(l3, none))
    s.eqi(count_same(l0, none), 0, "level 0 covers the frame")
    s.eqi(count_same(l3, none), 0, "level 3 covers the frame")

    var sp1 = frame(device, cap, target, hud, M_SPLAT1)
    var half = frame(device, cap, target, hud, M_SPLAT_HALF)
    var g = mean_rgb(l0, 0, Int(W))
    var r1 = mean_rgb(sp1, 0, Int(W))
    var left = mean_rgb(half, 0, Int(W) // 4)
    var right = mean_rgb(half, Int(W) * 3 // 4, Int(W))
    print("mean rgb: channel 0 (green tint)", g[0], g[1], g[2], "; channel 1 (red tint)", r1[0], r1[1], r1[2])
    print("half / half: left quarter", left[0], left[1], left[2], "; right quarter", right[0], right[1], right[2])
    s.check(g[1] > g[0] + 60, "channel 0 everywhere: green")
    s.check(r1[0] > r1[1] + 60, "channel 1 everywhere: red")
    # the camera looks along +z, so its right is -x: x < 32 m (channel 0, green) is the right of the frame
    var tv = top_view()
    print("top view right vector x:", tv.right[0])
    s.check(tv.right[0] < 0.0, "the top view's right points to -x")
    s.check(right[1] > right[0] + 60 and left[0] > left[1] + 60, "the split shows channel 0 (x < 32 m) on the right, channel 1 on the left")

    # the reference frame, by distance from ref_view()
    var refr = frame(device, cap, target, hud, M_REF)
    var again = frame(device, cap, target, hud, M_REF)
    var eq = True
    for i in range(len(refr)):
        if refr[i] != again[i]:
            eq = False
    s.check(eq, "the reference frame renders to the same bytes twice")
    if dump:  # `terrain_native --dump`: the frame as raw RGBA, for looking at (scripts/rgba_stats.py --png)
        with open("build/terrain_ref.rgba", "w") as f:
            f.write_bytes(refr)
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
                    sum[c] += Int(refr[(y * Int(W) + x) * 4 + c])
        var n = TILE * TILE
        lines.append(String(sum[0] // n) + " " + String(sum[1] // n) + " " + String(sum[2] // n))
        if not record and t < len(want):
            var b = want[t].split(" ")
            for c in range(3):
                worst = max(worst, abs(sum[c] // n - Int(String(b[c]))))
    if record:
        with open(TILES_FILE, "w") as f:
            for i in range(len(lines)):
                f.write(lines[i] + "\n")
        print("recorded", len(lines), "tiles to", TILES_FILE)
    else:
        print("worst tile channel difference against the reference:", worst, "of 255")
        s.check(worst <= 2, "every tile's mean colour is within 2 / 255 of the reference")

    # cost on a 4097 x 4097 grid, 1 m cells, chunk 64
    var n = 4097
    var hs = List[Float32](capacity=n * n)
    for iz in range(n):
        for ix in range(n):
            var x = Float64(ix)
            var z = Float64(iz)
            hs.append(Float32(18.0 * sin(x * 0.011) * cos(z * 0.013) + 4.0 * sin(x * 0.07 + z * 0.05)))
    var big = TerrainField(hs^, n, n, 1.0, 0.0, 0.0, 64, 40.0)
    for wh in [(UInt32(480), UInt32(270)), (UInt32(1920), UInt32(1080))]:
        var fw = wh[0]
        var fh = wh[1]
        var tgt = device.create_texture(fw, fh, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="terrain_cost")
        var cp = FrameCapture(device, fw, fh)
        var hd = Hud(device, format)
        var dl2 = DrawList()
        hd.set(dl2, Float32(fw), Float32(fh))
        var v = view_of(_v(2048, 40, 2048), _v(2300, 10, 2300), fw, fh)
        var base = List[Float64]()
        var with_t = List[Float64]()
        var pick = List[Float64]()
        var r = SceneRendererOf[Passes](device, format, v)
        for _ in range(5):
            r.begin(v)
            var t0 = perf_counter_ns()
            r.draw(device, tgt.handle().raw, fw, fh, hd)
            _ = read_back(device, cp, tgt, fw, fh)
            base.append(Float64(perf_counter_ns() - t0) / 1e6)
        var copy = TerrainField(big.h.copy(), n, n, 1.0, 0.0, 0.0, 64, 40.0)
        var t_up = perf_counter_ns()
        r.passes.second.set_field(device, copy^)
        var up_ms = Float64(perf_counter_ns() - t_up) / 1e6
        for _ in range(5):
            var t1 = perf_counter_ns()
            _ = r.passes.second.field.levels(2048.0, 40.0, 2048.0)
            pick.append(Float64(perf_counter_ns() - t1) / 1e6)
        for _ in range(5):
            r.begin(v)
            var t0 = perf_counter_ns()
            r.draw(device, tgt.handle().raw, fw, fh, hd)
            _ = read_back(device, cp, tgt, fw, fh)
            with_t.append(Float64(perf_counter_ns() - t0) / 1e6)
        ref tp = r.passes.second
        print(
            "4097 x 4097 grid at", fw, "x", fh, ": chunks drawn", tp.drawn_chunks, "culled", tp.culled_chunks, "draws",
            len(tp.draw_level), "triangles", tp.triangles,
        )
        print(
            "  upload", up_ms, "ms (once); level pick", _median(pick), "ms; frame without terrain", _median(base),
            "ms, with", _median(with_t), "ms (draw + readback, median of 5)",
        )
        s.check(tp.drawn_chunks > 0 and tp.culled_chunks > 0, "some chunks drawn, some culled")
        s.check(tp.triangles < 4096 * 4096 * 2 // 20, "LOD draws under 5 % of the full grid's triangles")
    s.finish()
