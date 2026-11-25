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
#   post pipelines  one stage adds the scene's colour target (W x H x 4); ThenPost adds the texture between its two parts, Join the two
#                   between its three, Scaled[_, 2] makes its neighbour's target a quarter of that
from harness.runner import Suite
from wgpu import Instance, WGPUTextureFormat, WGPUTextureUsage
from wgpu.device import Device
from wgpu.texture import Texture
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import Color, DrawList
from ui.geom import Rect
from app.render3d import SceneRendererOf, DefaultPasses
from app.primitive_pass import VERTS_PER_INSTANCE
from app.post import Stage, Copy, ThenPost, Join, Scaled, PostEffect
from app.post_fx import Bloom
from app.render_res import RenderCaps
from app.render_pass import RenderPass

comptime W: UInt32 = 640
comptime H: UInt32 = 360


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def mip_texels(side: Int, levels: Int) -> Int:
    var n = 0
    for l in range(levels):
        n += max(1, side >> l) * max(1, side >> l)
    return n


def post_bytes[F: PostEffect](
    device: Device, format: UInt32, view: View, target: Texture, hud: Hud, samples: Int = 1, lut_size: Int = 0,
) raises -> Int:
    """The texture bytes of a renderer with the post effect F (and `samples`, and a LUT of `lut_size` if not 0), after one
    draw at W x H."""
    var caps = RenderCaps.default()
    caps.samples = samples
    var r = SceneRendererOf[DefaultPasses, F](device, format, view.copy(), caps=caps)
    if lut_size > 0:
        r.set_lut(device, lut_size, List[UInt8](length=lut_size * lut_size * lut_size * 4, fill=128))
    r.begin(view.copy())
    r.draw(device, target.handle().raw, W, H, hud)
    return r.tex_bytes


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
    # post pipelines: the targets the stages draw into are counted
    var fixed = mip_texels(256, 9) * 2 * 4 + 1024 * 1024 * 4 + 2048 * 2048 * 4 + mip_texels(128, 8) * 6 * 4
    var px = Int(W) * Int(H) * 4  # one full-size RGBA8 or depth target
    var lut16 = 16 * 16 * 16 * 4  # a pipeline with stages holds the neutral colour-grading LUT, 16 x 16 x 16 RGBA8
    var one = post_bytes[Stage[Copy]](device, format, view, target, hud)
    s.eqi(one, fixed + 2 * px + lut16, "one stage: the fixed textures + the scene's depth and colour")
    var two = post_bytes[ThenPost[Stage[Copy], Stage[Copy]]](device, format, view, target, hud)
    s.eqi(two, fixed + 3 * px + lut16, "ThenPost of two stages adds the texture between them")
    var three = post_bytes[Join[Stage[Copy], Stage[Copy], Stage[Copy]]](device, format, view, target, hud)
    s.eqi(three, fixed + 4 * px + lut16, "Join of three stages adds the two textures its first two make")
    var small = post_bytes[ThenPost[Scaled[Stage[Copy], 2], Stage[Copy]]](device, format, view, target, hud)
    s.eqi(small, fixed + 2 * px + lut16 + Int(W // 2) * Int(H // 2) * 4, "a Scaled[_, 2] first part makes a half-size texture between the parts")
    # the picture effects: the colour-grading LUT, the multisampled targets, the bloom chain
    var lut32 = post_bytes[Stage[Copy]](device, format, view, target, hud, 1, 32)
    s.eqi(lut32, one - lut16 + 32 * 32 * 32 * 4, "set_lut with 32 ^ 3 entries replaces the 16 ^ 3 table: 4 * 32768 bytes")
    var plain_ms = post_bytes[Stage[Copy]](device, format, view, target, hud, 4)
    s.eqi(plain_ms, one + 2 * px * 4, "MSAA 4x adds the multisampled colour and depth: 2 targets x 4 samples x W x H x 4 bytes")
    var bloom = post_bytes[Bloom](device, format, view, target, hud)
    var chain = 0
    for d in [2, 4, 8, 16, 32, 16, 8, 4, 2]:
        chain += Int(W // UInt32(d)) * Int(H // UInt32(d)) * 4
    s.eqi(bloom, one + chain, "Bloom adds its nine targets, 1 / 2 down to 1 / 32 and back up to 1 / 2: " + String(chain) + " bytes")
    s.check(target.handle().raw == target.handle().raw and t2.handle().raw == t2.handle().raw, "the targets are alive until here")  # their last use: not before the draws
    s.finish()
