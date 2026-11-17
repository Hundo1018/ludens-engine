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
# `arena_frame_native --record` rewrites the tile file (a deliberate change of the picture);
# `arena_frame_native --dump out.rgba` also writes the frame (960 x 540 RGBA8, tightly packed) to look at.
# The scene and camera are written out here, not taken from the arena game, so a change to the game does not move them.
from std.math import sqrt
from std.sys import argv
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from game.arena import DrawItem
from game.camera_view import View
from geometry.aabb import AABB
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.ao_bake import ao_bake
from app.render3d import ArenaRenderer
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
        renderer.mesh.set_atmosphere(device, _v(0.25, 0.45, 0.8), _v(0.75, 0.8, 0.85), 0.02, 1.0, k != 3, k != 3)
        renderer.mesh.set_shadow(device, light, k != 1)
        renderer.mesh.set_ao(device, ao, 32, 32, -8.0, -8.0, 16.0, 16.0, k != 2)
        renderer.probe = 3  # the skinned cube with its joint turned 20 degrees, at the centre of the view
        renderer.begin(view)
        for it in scene():
            renderer.push(it)
        var casters = List[DrawItem]()
        for it in renderer.items:
            if it.mesh_id >= 0 and it.material != 3:
                casters.append(it.copy())
        shadow.draw(device, casters, renderer.meshes, light, renderer.mesh.shadow_tex.create_view_default(), renderer.skin_palette.copy())
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
    _keep(target)
    print("frame hash", hash, "(exact for one driver build; printed, not checked)")

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
