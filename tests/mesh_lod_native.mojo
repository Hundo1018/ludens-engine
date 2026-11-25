# tier: integration
# Mesh LOD on a dense scene (app/mesh_lod.mojo, issue #141), on native wgpu (lavapipe), 1920 x 1080:
# 600 spheres of 6144 triangles each, in 30 rows from 4 m to 120 m. Drawn once with the full mesh everywhere and once with
# the level `LodChain.pick` chose (1 pixel of error). Prints the triangles drawn (the renderer's counter) and the frame
# times; checks that the levels cut the triangles to under a third and that the two frames differ by under half a level
# on average, with under 0.5 % of the pixels off by more than 16 levels.
# `mesh_lod_native --dump DIR` writes DIR/lod_full.rgba and DIR/lod_picked.rgba at 320 x 180 (scripts/tier3_shots.py).
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
from app.mesh_pass import unit_sphere_arrays
from app.mesh_lod import LodChain, LodState

comptime ROWS = 30
comptime COLS = 20


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def view_for(w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(_v(0, 2.0, 0), look_rotation(_v(0, -0.12, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 300.0), aspect)


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


def sphere_pos(i: Int) -> Vec3:
    var row = i // COLS
    var col = i % COLS
    var z = -4.0 - 4.0 * Float64(row)
    var x = (Float64(col) - 9.5) * (1.2 + 0.1 * Float64(row))
    return _v(x, 0.5, z)


def frame(
    device: Device, mut r: SceneRendererOf[DefaultPasses], chain: LodChain, mut states: List[LodState], use_lod: Bool,
    target: Texture, w: UInt32, h: UInt32, hud: Hud,
) raises:
    var v = view_for(w, h)
    r.begin(v.copy())
    r.push(DrawItem(0, _v(0.0, -0.5, -60.0), 0.0, 0.0, 0.0, 1.0, _v(200.0, 1.0, 200.0), _v(0.35, 0.4, 0.3), r.cube, -1, MAT_COLOR))
    for i in range(ROWS * COLS):
        var p = sphere_pos(i)
        var id = chain.ids[0]
        if use_lod:
            id = chain.pick(states[i], p, 1.0, v, Float64(h), 1.0)
        var c = 0.3 + 0.05 * Float64(i % 7)
        r.push(DrawItem(1, p, 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(c, 0.5, 0.8 - c), id, -1, MAT_COLOR))
    r.draw(device, target.handle().raw, w, h, hud)


def main() raises:
    var s = Suite("mesh_lod_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var dir = String("")
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dir = String(args[i + 1])
    var w: UInt32 = 1920
    var h: UInt32 = 1080
    var r = SceneRendererOf[DefaultPasses](device, format, view_for(w, h))
    r.cull = True
    var c = unit_sphere_arrays(64, 48)
    var sphere = r.meshes.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())
    var t0 = perf_counter_ns()
    var chain = LodChain.build(r.meshes, sphere, [1.0, 0.5, 0.25, 0.125, 0.0625])
    print("chain built in", Float64(perf_counter_ns() - t0) / 1e6, "ms; triangles per level:", chain.triangles[0], chain.triangles[1], chain.triangles[2], chain.triangles[3], chain.triangles[4])
    var states = List[LodState]()
    for _ in range(ROWS * COLS):
        states.append(LodState())
    var target = device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="lod_target")
    var cap = FrameCapture(device, w, h)
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(w), Float32(h))

    var tris = List[Int]()
    var times = List[Float64]()
    var shots = List[List[UInt8]]()
    for use_lod in [False, True]:
        for _ in range(2):  # warm up (and the levels settle)
            frame(device, r, chain, states, use_lod, target, w, h, hud)
            _ = read(device, cap, target.handle().raw, w, h)
        tris.append(r.counts.triangles)
        var t = perf_counter_ns()
        for _ in range(5):
            frame(device, r, chain, states, use_lod, target, w, h, hud)
            _ = read(device, cap, target.handle().raw, w, h)
        times.append(Float64(perf_counter_ns() - t) / 5.0 / 1e6)
        shots.append(read(device, cap, target.handle().raw, w, h))
    var per_level = List[Int](length=chain.levels(), fill=0)
    for st in states:
        per_level[st.level] += 1
    var hist = String("")
    for k in range(chain.levels()):
        hist += String(per_level[k]) + " "
    print("instances per level (finest first):", hist)
    print("| 600 spheres, 1920 x 1080 (lavapipe, wall clock incl. read-back) | triangles drawn | ms |")
    print("|---|---:|---:|")
    print("| full mesh everywhere |", tris[0], "|", times[0], "|")
    print("| LOD, 1 px error |", tris[1], "|", times[1], "|")
    s.check(tris[1] * 3 < tris[0], "the levels draw under a third of the triangles (" + String(tris[1]) + " of " + String(tris[0]) + ")")
    var sum = 0.0
    var big = 0
    for i in range(0, len(shots[0]), 4):
        var worst = 0
        for ch in range(3):
            var d = abs(Int(shots[0][i + ch]) - Int(shots[1][i + ch]))
            sum += Float64(d)
            worst = max(worst, d)
        if worst > 16:
            big += 1
    var mean = sum / Float64(Int(w * h) * 3)
    var frac = Float64(big) / Float64(Int(w * h))
    print("frame difference, LOD against full: mean", mean, "levels; pixels off by more than 16 levels:", big, "(", frac * 100.0, "% )")
    s.check(mean < 0.5, "the two frames differ by under half a level on average")
    s.check(frac < 0.005, "under 0.5 % of the pixels differ by more than 16 levels")
    if dir.byte_length() > 0:
        var sw: UInt32 = 320
        var sh: UInt32 = 180
        var small = device.create_texture(sw, sh, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="lod_small")
        var scap = FrameCapture(device, sw, sh)
        var shud = Hud(device, format)
        var sdl = DrawList()
        shud.set(sdl, Float32(sw), Float32(sh))
        for use_lod in [False, True]:
            var st2 = List[LodState]()
            for _ in range(ROWS * COLS):
                st2.append(LodState())
            frame(device, r, chain, st2, use_lod, small, sw, sh, shud)
            var px = read(device, scap, small.handle().raw, sw, sh)
            with open(dir + ("/lod_picked.rgba" if use_lod else "/lod_full.rgba"), "w") as f:
                f.write_bytes(Span(px))
    s.finish()
