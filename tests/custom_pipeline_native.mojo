# tier: integration
# A render pipeline written by a user of the engine: everything below is defined in this file, nothing in app/ knows
# about it. It uses each extension point once (docs/PIPELINES.md):
#   a Material    "rings": bands of the item's colour by height, drawn on the surface
#   a RenderPass  "MarkerPass": one small sphere above every item, through the engine's primitive pass
#   a WireKind    orange edges, drawn only where they are in front
#   a Style       "split": the left half of the frame is the pipeline's picture, the right half its aux target
#   an aux list   the engine's NormalPasses
# and composes them as types. Checks: the frame differs from the default renderer's; the markers, the wires and the
# material each change pixels when they are taken out of the list; the right half shows the aux target (normals).
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from wgpu.render_pass import FrameRenderPass
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import ArenaRendererOf, DefaultPasses
from app.render_pass import RenderPass, Then, AuxTarget, NoAux, Aux
from app.render_res import RenderResources, RenderCaps
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache
from app.textures import TextureArray
from app.primitive_pass import PrimitivePass
from app.mesh_pass import MeshPassOf
from app.material import Material, MatSky
from app.wire_pass import WireKind, WirePassOf
from app.post import PostEffect, NoPost, Style, Stage
from app.gbuffer import NormalPasses

comptime W: UInt32 = 480
comptime H: UInt32 = 270


struct MatRings(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "rings by height"
    comptime BODY: StaticString = """
  let band = step(0.5, fract(s.wpos.y * 4.0));
  return vec4<f32>(s.base * mix(0.55, 1.0, band) * (0.5 + 0.5 * s.lit), 1.0);"""


struct OrangeEdges(WireKind):
    comptime NAME: StaticString = "orange edges"
    comptime FRAG: StaticString = """
  return vec4<f32>(1.0, 0.55, 0.05, 1.0);"""


struct MarkerPass(RenderPass):
    """A small white sphere 0.4 m above the top of every item but the sky."""

    comptime SHADOW: Bool = False
    var inner: PrimitivePass
    var marks: List[DrawItem]

    def __init__(out self, var inner: PrimitivePass):
        self.inner = inner^
        self.marks = List[DrawItem]()

    @staticmethod
    def sig() -> String:
        return "Markers"

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(PrimitivePass.create(device, color_format, depth_format, textures, res, caps))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.marks.clear()
        for i in range(len(items)):
            if items[i].material == MAT_SKY:
                continue
            var top = items[i].pos[1] + items[i].half[1] * Real(0.5) + Real(0.4)
            self.marks.append(DrawItem(
                1, Vec3(items[i].pos[0], top, items[i].pos[2], Real(0)), 0.0, 0.0, 0.0, 1.0,
                Vec3(Real(0.12), Real(0), Real(0), Real(0)), Vec3(Real(2.5), Real(2.5), Real(2.5), Real(0)),
            ))
        self.inner.prepare(device, self.marks, meshes, gpu, palette, view, res)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.inner.record_color(rpass, meshes, gpu)


struct Split(Style):
    comptime NAME: StaticString = "split"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  if uv.x > 0.5 { return aux_at(uv).rgb * aux_at(uv).a; }
  return src_at(uv);
}
"""


comptime Rings = MeshPassOf[MatRings, MatSky]
comptime MyPasses = Then[Rings, Then[WirePassOf[OrangeEdges], MarkerPass]]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def frame[P: RenderPass, F: PostEffect, A: AuxTarget](device: Device, mut cap: FrameCapture, target: Texture, hud: Hud) raises -> List[UInt8]:
    var aspect = Real(Float32(W) / Float32(H))
    var eye = _v(0, 2.5, 7)
    var view = View(CameraPose(eye, look_rotation(_v(0, 0.8, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)
    var r = ArenaRendererOf[P, F, A](device, WGPUTextureFormat.RGBA8Unorm, view)
    r.begin(view.copy())
    r.push(DrawItem(0, _v(0, -0.25, 0), 0.0, 0.0, 0.0, 1.0, _v(16, 0.5, 16), _v(0.6, 0.65, 0.55), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(0, _v(-1.5, 1.0, 0), 0.0, 0.2, 0.0, 0.98, _v(1.2, 2.0, 1.2), _v(0.85, 0.3, 0.25), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(1, _v(1.4, 0.8, 0.5), 0.0, 0.0, 0.0, 1.0, _v(1.6, 1.6, 1.6), _v(0.25, 0.5, 0.9), r.sphere, -1, MAT_COLOR))
    r.push(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), r.sphere, -1, MAT_SKY))
    r.draw(device, target.handle().raw, W, H, hud)
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


def changed(a: List[UInt8], b: List[UInt8], x0: Int, x1: Int) -> Int:
    """Pixels in columns x0 .. x1 whose colour differs by more than 24 / 255 in total."""
    var n = 0
    for y in range(Int(H)):
        for x in range(x0, x1):
            var o = (y * Int(W) + x) * 4
            if abs(Int(a[o]) - Int(b[o])) + abs(Int(a[o + 1]) - Int(b[o + 1])) + abs(Int(a[o + 2]) - Int(b[o + 2])) > 24:
                n += 1
    return n


def main() raises:
    var s = Suite("custom_pipeline_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="custom")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var half = Int(W) // 2
    var plain = frame[DefaultPasses, NoPost, NoAux](device, cap, target, hud)
    var mine = frame[MyPasses, Stage[Split], Aux[NormalPasses]](device, cap, target, hud)
    var no_marks = frame[Then[Rings, WirePassOf[OrangeEdges]], Stage[Split], Aux[NormalPasses]](device, cap, target, hud)
    var no_wires = frame[Then[Rings, MarkerPass], Stage[Split], Aux[NormalPasses]](device, cap, target, hud)
    var no_rings = frame[Then[MeshPassOf[MatSky], Then[WirePassOf[OrangeEdges], MarkerPass]], Stage[Split], Aux[NormalPasses]](device, cap, target, hud)
    print("structure:", MyPasses.sig(), "|", Aux[NormalPasses].sig(), "|", Stage[Split].sig())
    var d_plain = changed(mine, plain, 0, half)
    var d_marks = changed(mine, no_marks, 0, half)
    var d_wires = changed(mine, no_wires, 0, half)
    var d_rings = changed(mine, no_rings, 0, half)
    var d_aux = changed(mine, no_marks, half, Int(W))
    print("left half, pixels changed against: the default renderer", d_plain, "; without the marker pass", d_marks, "; without the wire pass", d_wires, "; without the ring material", d_rings)
    print("right half (the aux target), pixels changed when the marker pass is removed from the main list:", d_aux)
    s.check(d_plain > 5000, "the custom pipeline's picture is not the default renderer's")
    s.check(d_marks > 20 and d_marks < 3000, "the user's pass draws its markers, and only them")
    s.check(d_wires > 100, "the user's wire kind draws")
    s.check(d_rings > 5000, "the user's material shades the surfaces")
    s.eqi(d_aux, 0, "the aux half comes from the aux pass list alone: changing the main list leaves it as it was")
    # the aux half holds normals: the floor's is straight up, (0.5, 1.0, 0.5) as a colour
    var o = ((Int(H) - 20) * Int(W) + Int(W) - 40) * 4
    print("aux texel on the floor (r g b):", Int(mine[o]), Int(mine[o + 1]), Int(mine[o + 2]))
    s.check(abs(Int(mine[o]) - 128) < 3 and Int(mine[o + 1]) > 252 and abs(Int(mine[o + 2]) - 128) < 3, "the floor's normal in the aux target is straight up")
    s.finish()
