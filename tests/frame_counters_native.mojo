# tier: integration
# The renderer's frame counters (SceneRendererOf.counts, .tex_bytes) against what the scene and the texture sizes say, on
# native wgpu (lavapipe). The expected values come from the scene and from constants, not from the pass code:
#   a frame of 3 primitives, 5 unit cubes and 2 unit spheres, an empty HUD
#       draw calls   1 (the primitive pass: one instanced draw) + 2 (the mesh pass: one per mesh used) = 3
#       triangles    3 * 384 (a primitive is 1152 vertices) + 5 * 12 + 2 * (sphere indices / 3)
#   the same scene with 4 rectangles in the HUD
#       draw calls   +1, triangles + 4 * 2 (a filled rectangle is two triangles)
#   an empty scene: 1 draw call (the primitive draw runs with zero instances), 0 triangles
#   texture bytes    the texture array (256 x 256 x 2 layers, 9 levels), the shadow map (1024^2 depth), the atlas
#                    (2048^2 depth), the environment cube (128^2, 6 faces, 8 levels) and the frame's depth (W x H), 4 bytes a texel
#   a resize changes the depth part by the new W x H and nothing else
from harness.runner import Suite
from wgpu import Instance, WGPUTextureFormat, WGPUTextureUsage
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import Color, DrawList
from ui.geom import Rect
from app.render3d import SceneRendererOf, DefaultPasses
from app.primitive_pass import VERTS_PER_INSTANCE

comptime W: UInt32 = 640
comptime H: UInt32 = 360


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def mip_texels(side: Int, levels: Int) -> Int:
    var n = 0
    for l in range(levels):
        n += max(1, side >> l) * max(1, side >> l)
    return n


def main() raises:
    var s = Suite("frame_counters_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="t")
    var hud = Hud(device, format)
    var empty = DrawList()
    hud.set(empty, Float32(W), Float32(H))
    var view = View(CameraPose(_v(0, 2, 8), look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, Real(Float64(W) / Float64(H)), 0.1, 200.0), Real(Float64(W) / Float64(H)))
    var r = SceneRendererOf[DefaultPasses](device, format, view.copy())

    # the empty scene
    r.begin(view.copy())
    r.draw(device, target.handle().raw, W, H, hud)
    s.eqi(r.counts.draws, 1, "an empty scene: the primitive pass still issues its one draw")
    s.eqi(r.counts.triangles, 0, "an empty scene: no triangles")

    # 3 primitives, 5 cubes, 2 spheres
    var cube_tris = len(r.meshes.meshes[r.cube].indices) // 3
    var sphere_tris = len(r.meshes.meshes[r.sphere].indices) // 3
    s.eqi(cube_tris, 12, "the unit cube has 12 triangles")
    r.begin(view.copy())
    for i in range(3):
        r.push(DrawItem(0, _v(Float64(i), 0, 0), 0.0, 0.0, 0.0, 1.0, _v(0.5, 0.5, 0.5), _v(0.8, 0.2, 0.2), -1, -1, MAT_COLOR))
    for i in range(5):
        r.push(DrawItem(0, _v(Float64(i), 2, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(0.2, 0.8, 0.2), r.cube, -1, MAT_COLOR))
    for i in range(2):
        r.push(DrawItem(0, _v(Float64(i), 4, 0), 0.0, 0.0, 0.0, 1.0, _v(1, 1, 1), _v(0.2, 0.2, 0.8), r.sphere, -1, MAT_COLOR))
    r.draw(device, target.handle().raw, W, H, hud)
    s.eqi(r.counts.draws, 3, "3 primitives + 5 cubes + 2 spheres: 1 primitive draw + 2 mesh draws")
    s.eqi(r.counts.triangles, 3 * (VERTS_PER_INSTANCE // 3) + 5 * cube_tris + 2 * sphere_tris, "triangles: 3 * 384 + 5 * 12 + 2 * sphere")
    s.eqi(VERTS_PER_INSTANCE // 3, 384, "a primitive is 384 triangles")
    var base_draws = r.counts.draws
    var base_tris = r.counts.triangles

    # the HUD adds its own draw and triangles
    var dl = DrawList()
    for i in range(4):
        dl.fill(Rect(Float32(10 + 20 * i), 10.0, 16.0, 16.0), Color(1, 1, 1, 1))
    hud.set(dl, Float32(W), Float32(H))
    r.begin(view.copy())
    r.draw(device, target.handle().raw, W, H, hud)
    s.eqi(r.counts.draws, 2, "an empty scene with a HUD: the primitive draw + the HUD draw")
    s.eqi(r.counts.triangles, 4 * 2, "4 filled rectangles: 8 triangles")
    s.eqi(hud.draws(), 1, "the HUD reports its one draw")
    hud.set(empty, Float32(W), Float32(H))

    # texture bytes
    var expect = mip_texels(256, 9) * 2 * 4 + 1024 * 1024 * 4 + 2048 * 2048 * 4 + mip_texels(128, 8) * 6 * 4 + Int(W) * Int(H) * 4
    s.eqi(r.tex_bytes, expect, "texture bytes: array + shadow + atlas + environment + depth = " + String(expect))
    var t2 = device.create_texture(1280, 720, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="t2")
    r.begin(view.copy())
    r.draw(device, t2.handle().raw, 1280, 720, hud)
    s.eqi(r.tex_bytes, expect - Int(W) * Int(H) * 4 + 1280 * 720 * 4, "after a resize to 1280 x 720 only the depth part changed")
    s.eqi(base_draws, 3, "(the first scene's draw calls were 3)")
    s.eqi(base_tris, 3 * 384 + 5 * 12 + 2 * sphere_tris, "(and its triangles as computed)")
    s.check(target.handle().raw == target.handle().raw and t2.handle().raw == t2.handle().raw, "the targets are alive until here")  # their last use: not before the draws
    s.finish()
