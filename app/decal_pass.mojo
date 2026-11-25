"""Projected decals (#140) as a RenderPass: the clipped triangles of `game/decals.mojo`, alpha-blended over what the
earlier passes drew, depth-tested against it and not written. Put the pass after the opaque passes (meshes, terrain).

    comptime MyPasses = Then[DefaultPasses, Then[TerrainPass, DecalPass]]
    var m = DecalMesh(Decal(...))
    _ = m.project_terrain(r.passes.second.first.field)
    _ = r.passes.second.second.decals.add(m^)

`prepare` packs the decals within the frame's budget (`DecalSet.pack`: newest first up to `max_triangles`, within
`max_distance`) and uploads them; `record_color` is one non-indexed draw. A decal on layer 0 (the white layer) is a soft
disc filling the box; another layer is the texture at the decal's uv, times the colour. Grazing hits fade out: alpha is
multiplied by smoothstep(0.15, 0.4, fade), fade being cos of the angle between the surface normal and the projection.

Buffer (vec4<f32>): [0..3] camera (gpu_mesh.cam_floats); vertex i is three elements at 4 + 3 i: [x y z fade]
[u v layer 0] [r g b a]. `DECAL_TRIANGLES` triangles fit; DecalSet's budget defaults to the same number."""
from game.camera_view import View
from game.draw_item import DrawItem
from game.decals import DecalSet
from wgpu import WGPUBufferUsage, WGPUShaderStage, WGPUBindGroupLayoutEntry, WGPUBindGroupEntry
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.gpu_blend import pulled_pipeline, BLEND_ALPHA, CULL_NONE, DEPTH_LESS_EQUAL
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass, DrawCounts
from app.textures import TextureArray
from app.bind_entries import storage_entry, texture_array_entry, sampler_entry, buffer_bind, view_bind, sampler_bind

comptime DECAL_TRIANGLES = 16384  # per frame: 16384 x 3 x 48 B = 2.4 MB

comptime DECAL_WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;
@group(0) @binding(1) var tex : texture_2d_array<f32>;
@group(0) @binding(2) var samp : sampler;
struct DOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) uv : vec2<f32>,
  @location(1) color : vec4<f32>,
  @location(2) @interpolate(flat) layer : f32,
  @location(3) fade : f32,
};
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> DOut {
  let b = 4u + vi * 3u;
  let p = data[b];
  let d = p.xyz - data[0].xyz;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : DOut;
  out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
  if data[0].w < 0.0 { out.pos = vec4<f32>(-x * data[0].w, y * data[1].w, (z - near) / (far - near), 1.0); }
  out.uv = data[b + 1u].xy;
  out.layer = data[b + 1u].z;
  out.color = data[b + 2u];
  out.fade = p.w;
  return out;
}
@fragment
fn fs_main(in : DOut) -> @location(0) vec4<f32> {
  let layer = i32(in.layer + 0.5);
  let t = textureSampleLevel(tex, samp, vec2<f32>(in.uv.x, 1.0 - in.uv.y), layer, 0.0);
  var a = in.color.a * t.a * smoothstep(0.15, 0.4, in.fade);
  if layer == 0 {
    a = a * (1.0 - smoothstep(0.8, 1.0, length(in.uv * 2.0 - vec2<f32>(1.0))));
  }
  return vec4<f32>(in.color.rgb * t.rgb, a);
}
"""


struct DecalPass(RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Decals"

    var decals: DecalSet
    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var triangles: Int  # this frame

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray, samples: UInt32 = 1) raises:
        var shader = device.create_shader_module_wgsl(String(DECAL_WGSL), "decals")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            storage_entry(0, WGPUShaderStage.VERTEX.value), texture_array_entry(1, WGPUShaderStage.FRAGMENT.value),
            sampler_entry(2, WGPUShaderStage.FRAGMENT.value),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "decals_layout")
        self.pipeline = pulled_pipeline(
            device, shader, layout, color_format, depth_format, 4, BLEND_ALPHA, CULL_NONE, False, DEPTH_LESS_EQUAL, samples,
        )
        self.buffer = device.create_buffer(
            UInt64((4 + 9 * DECAL_TRIANGLES) * 16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="decals",
        )
        var bg: List[WGPUBindGroupEntry] = [
            buffer_bind(0, self.buffer), view_bind(1, textures.view), sampler_bind(2, textures.main_sampler),
        ]
        self.group = device.create_bind_group(bgl, bg, "decals_group")
        self.decals = DecalSet(256, DECAL_TRIANGLES)
        self.staging = List[Float32]()
        self.triangles = 0

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, textures, UInt32(caps.samples))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.staging.clear()
        for f in cam_floats(view):
            self.staging.append(f)
        self.decals.max_triangles = min(self.decals.max_triangles, DECAL_TRIANGLES)
        self.triangles = self.decals.pack(Float64(view.eye[0]), Float64(view.eye[1]), Float64(view.eye[2]), self.staging)
        if self.triangles > 0:
            device.queue_write_data(self.buffer, UInt64(0), self.staging)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if self.triangles > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(self.triangles * 3), UInt32(1), UInt32(0), UInt32(0))

    def counts(self, meshes: MeshRegistry) -> DrawCounts:
        return DrawCounts(1 if self.triangles > 0 else 0, self.triangles)
