# tier: integration
# A whole frame of ArenaRenderer with every pass and option on (issue #90, step 1): colour primitives, textured
# primitives on the mesh pass (uv and triplanar), the skinned probe cube, the shadow pass, the baked AO grid, the
# atmosphere (sky sphere, fog, linear workflow with ACES) and the HUD. 960 x 540 on native wgpu, read back.
#
# Two results:
#   - the mean colour of each 60 x 60 tile (16 x 9 tiles) against tests/golden/arena_frame_tiles.txt, within 2 / 255.
#     This is what CI checks: it holds across Mesa versions and catches a pass that stopped drawing or changed its
#     shading.
#   - "frame hash", an FNV-1a of every pixel. It is printed, not checked: it is exact only for one driver build. A
#     change that claims to leave the renderer's output unchanged quotes this line before and after, from one machine.
# A third result: the pass list is customisable. ArenaRendererOf[Then[ShadowPass, DefaultPasses]] renders the shadow map
# itself, in its own command buffer; its frame must equal the default renderer's after a separate ShadowPass.draw.
# A fourth: materials (app/material.mojo) shade the same on both mesh passes. A skinned cube at the identity pose in each
# built-in material gives the frame of the static unit cube in that material (shadow and AO off: the skinned pass has
# no AO).
# A seventh: the engine-specific view (#90 step 5), motor skinning beside LBS. A bar along x whose right end is
# twisted 170 degrees about its axis: with LinearBlend (the default renderer) its middle collapses toward the axis (the
# candy wrapper); ArenaRendererOf[..MotorSkinnedPass] keeps its cross-section. Measured as the bar's height on screen at
# its middle column over its height near the ends; --dump writes both frames (out.rgba.lbs.rgba / .motor.rgba).
# A sixth: MAT_PBR (#90 step 4). A smooth PBR sphere has a highlight brighter than the colour-only sphere's brightest
# pixel; a rough one's is lower than the smooth one's.
# A fifth: point lights (#90 step 3). A red light beside the floor adds red to many pixels and takes no more than 1 / 255
# from any; with the lights cleared again the frame is the no-light frame exactly.
# `arena_frame_native --record` rewrites the tile file (a deliberate change of the picture);
# `arena_frame_native --dump out.rgba` also writes the frame (960 x 540 RGBA8, tightly packed) to look at, and the
# three spheres of the MAT_PBR checks as out.rgba.color.rgba / .pbr_smooth.rgba / .pbr_rough.rgba.
# The scene and camera are written out here, not taken from the arena game, so a change to the game does not move them.
from std.math import sqrt, sin, cos
from std.sys import argv
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY, MAT_PBR
from game.camera_view import View
from geometry.aabb import AABB
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.ao_bake import ao_bake
from app.render_res import PointLight
from app.render3d import ArenaRenderer, ArenaRendererOf, DefaultPasses
from app.render_pass import RenderPass, Then
from app.primitive_pass import PrimitivePass
from app.mesh_pass import MeshPass
from app.skin_draw import MotorSkinnedPass
from app.skin_pass import build_palette
from geometry.mat import Mat4
from app.shadow_pass import ShadowPass

comptime W: UInt32 = 960
comptime H: UInt32 = 540
comptime TILE = 60
comptime TILES_FILE = "tests/golden/arena_frame_tiles.txt"


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def sun_light_vp() -> List[Float32]:
    """The sun's orthographic view-projection (16 floats, column-major, z in [0, 1]) along (0.4, 1.0, 0.6), the mesh
    shader's light direction: 12 m half-extent, 30 m either side of the origin."""
    var ln = sqrt(0.4 * 0.4 + 1.0 * 1.0 + 0.6 * 0.6)
    var fx = -0.4 / ln
    var fy = -1.0 / ln
    var fz = -0.6 / ln
    var rl = sqrt(fy * fy + fx * fx)
    var rx = fy / rl
    var ry = -fx / rl
    var ux = ry * fz
    var uy = -rx * fz
    var uz = rx * fy - ry * fx
    var m = List[Float32]()
    for c in [rx / 12.0, ux / 12.0, fx / 60.0, 0.0, ry / 12.0, uy / 12.0, fy / 60.0, 0.0, 0.0, uz / 12.0, fz / 60.0, 0.0, 0.0, 0.0, 0.5, 1.0]:
        m.append(Float32(c))
    return m^


def _keep(t: Texture):
    """A last use: Mojo destroys a value after its last use, and `target.handle().raw` alone does not keep the texture
    alive until the readback."""
    pass


def _capture_hash(device: Device, mut cap: FrameCapture, target: Texture) raises -> UInt64:
    """FNV-1a of the target's pixels (960 x 540 RGBA8)."""
    var req = cap.capture(device, target.handle().raw)
    req.wait()
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(W))
    var h = UInt64(0xCBF29CE484222325)
    for y in range(Int(H)):
        for x in range(Int(W)):
            for c in range(4):
                h = (h ^ UInt64(px[unsafe_offset=y * pitch + x * 4 + c])) * UInt64(0x100000001B3)
    cap.unmap()
    return h


def _capture_pixels(device: Device, mut cap: FrameCapture, target: Texture) raises -> List[UInt8]:
    """The target's pixels, 960 x 540 RGBA8, tightly packed."""
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


def _sphere_peak(
    device: Device, mut r: ArenaRenderer, mut cap: FrameCapture, target: Texture, hud: Hud, material: Int,
    roughness: Float32, metallic: Float32, dump: String = String(),
) raises -> Int:
    """The brightest pixel (r + g + b) of a grey sphere (radius 1, the unit sphere mesh) alone in front of the camera."""
    r.probe = 0
    r.begin(r.view.copy())
    # on the unit sphere mesh (1 across, so half 2 is radius 1): all three through the mesh pass and its atmosphere
    r.push(DrawItem(1, _v(0, 1.2, 4), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(0.6, 0.6, 0.6), r.sphere, -1, material, 1, roughness, metallic))
    r.draw(device, target.handle().raw, W, H, hud)
    var px = _capture_pixels(device, cap, target)
    if dump.byte_length() > 0:
        with open(dump, "w") as f:
            f.write_bytes(px)
    var peak = 0
    for i in range(0, len(px), 4):
        peak = max(peak, Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]))
    return peak


def _rot_x(deg: Float64) -> Mat4:
    var a = deg * 3.141592653589793 / 180.0
    var m = Mat4.identity()
    m.set(1, 1, Real(cos(a)))
    m.set(1, 2, Real(-sin(a)))
    m.set(2, 1, Real(sin(a)))
    m.set(2, 2, Real(cos(a)))
    return m^


def _twist_bar[P: RenderPass](mut r: ArenaRendererOf[P]) raises -> Int:
    """Register the bar (x from -2 to 2, 16 segments, square cross-section 0.6 wide; joint 0 at the left end, joint 1
    at the right, weights linear in x) and set the palette: joint 0 identity, joint 1 turned 170 degrees about x.
    Returns the skinned mesh id."""
    var pos = List[Float32]()
    var nrm = List[Float32]()
    var uv = List[Float32]()
    var jt = List[UInt16]()
    var wt = List[Float32]()
    var idx = List[UInt32]()
    comptime SEG = 16
    for i in range(SEG + 1):
        var t = Float32(i) / Float32(SEG)
        for c in range(4):
            var a = Float64(c) * 1.5707963267948966 + 0.7853981633974483
            pos.append(Float32(-2.0) + 4.0 * t)
            pos.append(Float32(0.42 * cos(a)))
            pos.append(Float32(0.42 * sin(a)))
            nrm.append(0.0)
            nrm.append(Float32(cos(a)))
            nrm.append(Float32(sin(a)))
            uv.append(t)
            uv.append(Float32(c) / 4.0)
            for k in [UInt16(0), UInt16(1), UInt16(0), UInt16(0)]:
                jt.append(k)
            for w in [1.0 - t, t, Float32(0), Float32(0)]:
                wt.append(w)
    for i in range(SEG):
        for c in range(4):
            var a0 = UInt32(4 * i + c)
            var a1 = UInt32(4 * i + (c + 1) % 4)
            var b0 = a0 + 4
            var b1 = a1 + 4
            for v in [a0, b0, a1, a1, b0, b1]:
                idx.append(v)
    var id = r.meshes.add_skinned(pos^, nrm^, uv^, jt^, wt^, idx^)
    var locals = List[Mat4]()
    locals.append(Mat4.identity())
    locals.append(_rot_x(170.0))
    var parents: List[Int] = [-1, -1]
    var ibm = List[Mat4]()
    ibm.append(Mat4.identity())
    ibm.append(Mat4.identity())
    r.skin_palette = build_palette(locals, parents, ibm)
    return id


def _bar_heights[P: RenderPass](
    device: Device, mut r: ArenaRendererOf[P], mesh: Int, mut cap: FrameCapture, target: Texture, hud: Hud, dump: String,
) raises -> Tuple[Int, Int]:
    """Draw the bar alone and measure it: (pixels it covers in the middle column, the mean over the columns a tenth of
    its width in from each end). A pixel is the bar's when it differs from the top-left (clear colour) pixel."""
    r.probe = 0
    r.begin(r.view.copy())
    r.push(DrawItem(0, _v(0, 1.2, 4), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(0.8, 0.6, 0.3), mesh, 0, 0, 1))
    r.draw(device, target.handle().raw, W, H, hud)
    var px = _capture_pixels(device, cap, target)
    if dump.byte_length() > 0:
        with open(dump, "w") as f:
            f.write_bytes(px)
    var cols = List[Int]()
    for x in range(Int(W)):
        var n = 0
        for y in range(Int(H)):
            var o = (y * Int(W) + x) * 4
            if px[o] != px[0] or px[o + 1] != px[1] or px[o + 2] != px[2]:
                n += 1
        cols.append(n)
    var first = -1
    var last = -1
    for x in range(Int(W)):
        if cols[x] > 0:
            if first < 0:
                first = x
            last = x
    if first < 0:
        return (0, 0)
    var inset = (last - first) // 10
    return (cols[(first + last) // 2], (cols[first + inset] + cols[last - inset]) // 2)


def _options[P: RenderPass](device: Device, mut r: ArenaRendererOf[P], light: List[Float32], ao: List[Float32]) raises:
    """Every option on, as frame 0 of the reference; no probe cube (it is added inside draw(), after a separate shadow
    pass has run, so only a shadow pass inside the list would see it)."""
    r.set_atmosphere(device, _v(0.25, 0.45, 0.8), _v(0.75, 0.8, 0.85), 0.02, 1.0, True, True)
    r.set_shadow(device, light, True)
    r.set_ao(device, ao, 32, 32, -8.0, -8.0, 16.0, 16.0, True)
    r.probe = 0
    r.begin(r.view.copy())
    for it in scene():
        r.push(it)


def _one_cube_hash(
    device: Device, mut r: ArenaRenderer, mut cap: FrameCapture, target: Texture, hud: Hud, material: Int, skinned: Bool,
) raises -> UInt64:
    """A unit cube (half 1) turned 30 degrees about y in front of the camera, on texture layer 1, alone."""
    r.probe = 0
    r.begin(r.view.copy())
    var mesh = r.skin_ident if skinned else r.cube
    r.push(DrawItem(0, _v(0, 1.2, 3), 0.0, 0.25881905, 0.0, 0.96592583, _v(1, 1, 1), _v(0.9, 0.7, 0.5), mesh, 0 if skinned else -1, material, 1))
    r.draw(device, target.handle().raw, W, H, hud)
    return _capture_hash(device, cap, target)


def scene() -> List[DrawItem]:
    var items = List[DrawItem]()
    # the floor: a textured box (triplanar, layer 1), 24 m square, top at y 0
    items.append(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(12, 0.25, 12), _v(0.8, 0.8, 0.8), material=2))
    # two pillars that cast on the floor and occlude it: one colour primitive, one uv-textured
    items.append(DrawItem(0, _v(-2.5, 1.0, -1.0), 0.0, 0.0, 0.0, 1.0, _v(0.5, 1.0, 0.5), _v(0.85, 0.3, 0.2)))
    items.append(DrawItem(0, _v(2.0, 0.75, 0.5), 0.0, 0.38268343, 0.0, 0.92387953, _v(0.75, 0.75, 0.75), _v(0.3, 0.6, 0.9), material=1))
    # spheres: a colour primitive and a textured one
    items.append(DrawItem(1, _v(2.6, 0.6, 4.0), 0.0, 0.0, 0.0, 1.0, _v(0.6, 0.6, 0.6), _v(0.9, 0.8, 0.2)))
    items.append(DrawItem(1, _v(-2.6, 0.5, 4.0), 0.0, 0.0, 0.0, 1.0, _v(0.5, 0.5, 0.5), _v(0.4, 0.8, 0.4), material=1))
    # the sky: a sphere around the camera with the sky material
    items.append(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), material=3))
    return items^


def main() raises:
    var s = Suite("arena_frame_native")
    var record = len(argv()) > 1 and String(argv()[1]) == "--record"
    var dump = String(argv()[2]) if len(argv()) > 2 and String(argv()[1]) == "--dump" else String()
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(
        W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="frame_target",
    )
    var aspect = Real(Float32(W) / Float32(H))
    var eye = _v(0, 3, 9)
    var cam = CameraPose(eye, look_rotation(_v(0, 0.8, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0)
    var view = View(cam, aspect)
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var renderer = ArenaRenderer(device, format, view)
    var shadow = ShadowPass(device, WGPUTextureFormat.Depth32Float)
    var light = sun_light_vp()

    var boxes = List[AABB[3]]()
    boxes.append(AABB[3](_v(-3.0, 0.0, -1.5), _v(-2.0, 2.0, -0.5)))
    boxes.append(AABB[3](_v(1.0, 0.0, -0.5), _v(3.0, 1.5, 1.5)))
    var ao = ao_bake(boxes, 32, -8.0, -8.0, 16.0)
    var cap = FrameCapture(device, W, H)
    var pitch = Int(padded_row_pitch(W))
    var tx = Int(W) // TILE
    var ty = Int(H) // TILE
    var sums = List[Int]()
    var hash = UInt64(0)
    var full = List[UInt8]()  # the reference frame's pixels, for the "each option changes pixels" checks
    # frame 0 has everything on (the reference); frames 1..3 turn one option off each
    var names: List[String] = ["all on", "shadow off", "AO off", "atmosphere off"]
    for k in range(4):
        renderer.set_atmosphere(device, _v(0.25, 0.45, 0.8), _v(0.75, 0.8, 0.85), 0.02, 1.0, k != 3, k != 3)
        renderer.set_shadow(device, light, k != 1)
        renderer.set_ao(device, ao, 32, 32, -8.0, -8.0, 16.0, 16.0, k != 2)
        renderer.probe = 3  # the skinned cube with its joint turned 20 degrees, at the centre of the view
        renderer.begin(view)
        for it in scene():
            renderer.push(it)
        var casters = List[DrawItem]()
        for it in renderer.items:
            if it.mesh_id >= 0 and it.material != 3:
                casters.append(it.copy())
        shadow.draw(device, casters, renderer.meshes, light, renderer.shadow_target(), renderer.skin_palette.copy())
        renderer.draw(device, target.handle().raw, W, H, hud)
        var req = cap.capture(device, target.handle().raw)
        req.wait()
        var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        if k == 0:
            hash = UInt64(0xCBF29CE484222325)
            for _ in range(tx * ty * 3):
                sums.append(0)
            for y in range(Int(H)):
                for x in range(Int(W)):
                    var o = y * pitch + x * 4
                    var t = ((y // TILE) * tx + x // TILE) * 3
                    for c in range(4):
                        hash = (hash ^ UInt64(px[unsafe_offset=o + c])) * UInt64(0x100000001B3)
                        full.append(px[unsafe_offset=o + c])
                    for c in range(3):
                        sums[t + c] += Int(px[unsafe_offset=o + c])
            if dump.byte_length() > 0:
                with open(dump, "w") as f:
                    f.write_bytes(full)
        else:
            var changed = 0
            for y in range(Int(H)):
                for x in range(Int(W)):
                    var o = y * pitch + x * 4
                    var q = (y * Int(W) + x) * 4
                    if px[unsafe_offset=o] != full[q] or px[unsafe_offset=o + 1] != full[q + 1] or px[unsafe_offset=o + 2] != full[q + 2]:
                        changed += 1
            print(names[k], "changes", changed, "of", Int(W) * Int(H), "pixels")
            s.check(changed > 500, names[k] + ": the option is visible in the reference frame (more than 500 pixels change)")
        cap.unmap()
    print("frame hash", hash, "(exact for one driver build; printed, not checked)")

    # the pass list: a shadow pass inside the renderer gives the frame of a separate shadow pass
    _options(device, renderer, light, ao)
    var casters = List[DrawItem]()
    for it in renderer.items:
        if it.mesh_id >= 0 and it.material != 3:
            casters.append(it.copy())
    shadow.draw(device, casters, renderer.meshes, light, renderer.shadow_target(), renderer.skin_palette.copy())
    renderer.draw(device, target.handle().raw, W, H, hud)
    var h_separate = _capture_hash(device, cap, target)
    var inside = ArenaRendererOf[Then[ShadowPass, DefaultPasses]](device, format, view)
    _options(device, inside, light, ao)
    inside.draw(device, target.handle().raw, W, H, hud)
    var h_inside = _capture_hash(device, cap, target)
    inside.set_shadow(device, light, False)
    inside.begin(inside.view.copy())
    for it in scene():
        inside.push(it)
    inside.draw(device, target.handle().raw, W, H, hud)
    var h_off = _capture_hash(device, cap, target)
    _keep(target)
    print("pass list: separate shadow pass", h_separate, "; shadow pass in the list", h_inside, "; in the list, shadow off", h_off)
    s.check(h_inside == h_separate, "ArenaRendererOf[Then[ShadowPass, DefaultPasses]] draws the frame of a separate ShadowPass.draw")
    s.check(h_off != h_inside, "with the renderer's shadow off, the listed shadow pass does not draw (the frame changes)")

    # materials: the skinned pass shades each built-in material as the mesh pass does
    renderer.set_shadow(device, light, False)
    renderer.set_ao(device, ao, 32, 32, -8.0, -8.0, 16.0, 16.0, False)
    var names_m: List[String] = ["MAT_COLOR", "MAT_UV", "MAT_TRIPLANAR", "MAT_SKY", "MAT_PBR"]
    var seen = List[UInt64]()
    for m in [MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY, MAT_PBR]:
        var h_static = _one_cube_hash(device, renderer, cap, target, hud, m, False)
        var h_skin = _one_cube_hash(device, renderer, cap, target, hud, m, True)
        print("material", names_m[m], "static", h_static, "skinned", h_skin)
        s.check(h_skin == h_static, "a skinned cube in " + names_m[m] + " gives the static cube's frame")
        seen.append(h_static)
    s.check(seen[0] != seen[1] and seen[1] != seen[2] and seen[2] != seen[3], "the four materials give four different frames")

    # the engine-specific view: motor skinning beside LBS on a twisted bar
    renderer.set_atmosphere(device, _v(0.25, 0.45, 0.8), _v(0.75, 0.8, 0.85), 0.0, 1.0, False, False)
    renderer.set_shadow(device, light, False)
    var bar_lbs = _twist_bar(renderer)
    var motor = ArenaRendererOf[Then[PrimitivePass, Then[MeshPass, MotorSkinnedPass]]](device, format, view)
    var bar_motor = _twist_bar(motor)
    var lbs_h = _bar_heights(device, renderer, bar_lbs, cap, target, hud, dump + ".lbs.rgba" if dump.byte_length() > 0 else String())
    var mot_h = _bar_heights(device, motor, bar_motor, cap, target, hud, dump + ".motor.rgba" if dump.byte_length() > 0 else String())
    var lbs_ratio = Float64(lbs_h[0]) / Float64(max(lbs_h[1], 1))
    var mot_ratio = Float64(mot_h[0]) / Float64(max(mot_h[1], 1))
    print("twisted bar, middle / ends height (px): LBS", lbs_h[0], "/", lbs_h[1], "=", lbs_ratio, "; motor", mot_h[0], "/", mot_h[1], "=", mot_ratio)
    s.check(lbs_h[1] > 20 and mot_h[1] > 20, "the bar is on screen in both renderers")
    s.check(lbs_ratio < 0.5, "LBS collapses the twisted middle to under half the ends' height (candy wrapper)")
    s.check(mot_ratio > 0.8, "motor skinning keeps the twisted middle at over 0.8 of the ends' height")
    renderer.set_atmosphere(device, _v(0.25, 0.45, 0.8), _v(0.75, 0.8, 0.85), 0.02, 1.0, True, True)  # back as before

    # MAT_PBR: the specular highlight follows the roughness
    var d0 = dump + ".color.rgba" if dump.byte_length() > 0 else String()
    var d1 = dump + ".pbr_smooth.rgba" if dump.byte_length() > 0 else String()
    var d2 = dump + ".pbr_rough.rgba" if dump.byte_length() > 0 else String()
    var peak_color = _sphere_peak(device, renderer, cap, target, hud, MAT_COLOR, 0.5, 0.0, d0)
    var peak_smooth = _sphere_peak(device, renderer, cap, target, hud, MAT_PBR, 0.15, 0.0, d1)
    var peak_rough = _sphere_peak(device, renderer, cap, target, hud, MAT_PBR, 0.9, 0.0, d2)
    print("sphere peak (r + g + b): colour", peak_color, "; PBR roughness 0.15", peak_smooth, "; PBR roughness 0.9", peak_rough)
    s.check(peak_smooth > peak_color + 30, "a smooth PBR sphere has a highlight brighter than the colour-only sphere")
    s.check(peak_rough < peak_smooth, "a rough PBR sphere's highlight is dimmer than a smooth one's")

    # point lights: a red one at the pillars' feet, then none again
    _options(device, renderer, light, ao)
    renderer.draw(device, target.handle().raw, W, H, hud)
    var dark = _capture_pixels(device, cap, target)
    var lamps = List[PointLight]()
    lamps.append(PointLight(_v(0, 0.6, 1.5), 4.0, _v(1, 0, 0), 2.0))
    renderer.set_lights(device, lamps)
    _options(device, renderer, light, ao)
    renderer.draw(device, target.handle().raw, W, H, hud)
    var lit = _capture_pixels(device, cap, target)
    var redder = 0
    var worst_loss = 0
    for i in range(0, len(lit), 4):
        if Int(lit[i]) > Int(dark[i]) + 8:
            redder += 1
        for c in range(3):
            worst_loss = max(worst_loss, Int(dark[i + c]) - Int(lit[i + c]))
    renderer.set_lights(device, List[PointLight]())
    _options(device, renderer, light, ao)
    renderer.draw(device, target.handle().raw, W, H, hud)
    var again = _capture_pixels(device, cap, target)
    var same = len(again) == len(dark)
    for i in range(min(len(again), len(dark))):
        if again[i] != dark[i]:
            same = False
    print("point light: redder by more than 8 / 255 on", redder, "pixels; worst channel loss", worst_loss)
    s.check(redder > 5000, "a red point light adds red to the floor and the pillars around it")
    s.check(worst_loss <= 1, "and takes no more than 1 / 255 from any channel")
    s.check(same, "with the lights cleared the frame is the no-light frame, every byte")

    var lines = List[String]()
    for t in range(tx * ty):
        var n = TILE * TILE
        lines.append(String(sums[3 * t] // n) + " " + String(sums[3 * t + 1] // n) + " " + String(sums[3 * t + 2] // n))
    if record:
        with open(TILES_FILE, "w") as f:
            for i in range(len(lines)):
                f.write(lines[i] + "\n")
        print("recorded", len(lines), "tiles to", TILES_FILE)
        return
    var want = List[String]()
    with open(TILES_FILE, "r") as f:
        for line in f.read().split("\n"):
            if line.strip().byte_length() > 0:
                want.append(String(line.strip()))
    s.eqi(len(want), tx * ty, "the reference has one line per tile (16 x 9)")
    var worst = 0
    var distinct = 0
    var first = String()
    for t in range(min(len(want), len(lines))):
        var a = lines[t].split(" ")
        var b = want[t].split(" ")
        for c in range(3):
            worst = max(worst, abs(Int(String(a[c])) - Int(String(b[c]))))
        if t == 0:
            first = lines[t]
        elif lines[t] != first:
            distinct += 1
    print("worst tile channel difference", worst, "of 255;", distinct, "of", tx * ty - 1, "tiles differ from the first")
    s.check(worst <= 2, "every tile's mean colour is within 2 / 255 of the reference")
    s.check(distinct > 100, "the frame is not one flat colour (most tiles differ from the first)")
    s.finish()
