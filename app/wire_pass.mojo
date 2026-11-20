"""The frame's items as line segments: a box by its 12 edges, a sphere by three great circles of 48 segments. A
RenderPass with line-list topology, built by vertex pulling like the primitive pass. `WirePassOf[K]` takes its blend,
depth test and fragment colour from a WireKind:

    Then[SolidPasses, Then[WirePassOf[VisibleEdges], WirePassOf[HiddenEdges]]]

A line pass with the depth test reversed (DEPTH_GREATER) draws exactly the edges that are behind something, which is
how a drawing shows hidden lines; with BLEND_ADD and no solids at all it is a vector display, where every line shows
and crossings are brighter.

An item on the unit cube or sphere mesh keeps its size (half extents halved, as ArenaRendererOf.push doubled them);
the sky is skipped. Buffer layout: the primitive pass's (5 header vec4, then 4 per instance)."""
from game.draw_item import DrawItem, MAT_SKY
from game.camera_view import View
from geometry.vec import Real
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu import null_opaque
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass
from app.textures import TextureArray
from app.gpu_blend import pulled_pipeline, TOPOLOGY_LINES, BLEND_NONE, DEPTH_LESS_EQUAL

comptime WIRE_VERTS = 288  # 3 rings x 48 segments x 2 ends; a box uses the first 24

comptime WIRE_WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;
struct WOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color : vec3<f32>,
  @location(1) t : f32,       // metres along the segment's line, for dashes
  @location(2) wpos : vec3<f32>,
};
fn rotate(q : vec4<f32>, v : vec3<f32>) -> vec3<f32> {
  let t = 2.0 * cross(q.xyz, v);
  return v + q.w * t + cross(q.xyz, t);
}
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> WOut {
  let b = 5u + ii * 4u;
  let p = data[b].xyz;
  let kind = data[b].w;
  let q = data[b + 1u];
  let h = data[b + 2u].xyz;
  var local = vec3<f32>(0.0);
  var along = 0.0;
  var live = true;
  let seg = vi / 2u;
  let end = f32(vi % 2u);
  if kind < 0.5 {
    if vi >= 24u { live = false; }
    let axis = (seg / 4u) % 3u;
    let s1 = f32(seg & 1u) * 2.0 - 1.0;
    let s2 = f32((seg >> 1u) & 1u) * 2.0 - 1.0;
    let e = end * 2.0 - 1.0;
    if axis == 0u { local = vec3<f32>(e, s1, s2) * h; along = e * h.x; }
    if axis == 1u { local = vec3<f32>(s1, e, s2) * h; along = e * h.y; }
    if axis == 2u { local = vec3<f32>(s1, s2, e) * h; along = e * h.z; }
  } else {
    let ring = seg / 48u;
    let a = (f32(seg % 48u) + end) / 48.0 * 6.2831853;
    let c = cos(a) * h.x;
    let s = sin(a) * h.x;
    if ring == 0u { local = vec3<f32>(c, s, 0.0); }
    if ring == 1u { local = vec3<f32>(0.0, c, s); }
    if ring == 2u { local = vec3<f32>(s, 0.0, c); }
    along = a * h.x;
  }
  let world = p + rotate(q, local);
  let d = world - data[0].xyz;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : WOut;
  if live {
    out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
    if data[0].w < 0.0 { out.pos = vec4<f32>(-x * data[0].w, y * data[1].w, (z - near) / (far - near), 1.0); }
  } else {
    out.pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
  }
  out.color = data[b + 3u].xyz;
  out.t = along;
  out.wpos = world;
  return out;
}
"""


trait WireKind:
    comptime NAME: StaticString
    comptime FRAG: StaticString
    """The statements of `fn fs_main(in : WOut) -> @location(0) vec4<f32>`: in.color is the item's colour, in.t the
    distance along the line in metres."""
    comptime BLEND: Int = BLEND_NONE
    comptime DEPTH_COMPARE: Int = DEPTH_LESS_EQUAL
    comptime DEPTH_WRITE: Bool = False


struct WirePassOf[K: WireKind](RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Wire[" + String(Self.K.NAME) + "]"

    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var max_items: Int
    var count: Int

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, caps: RenderCaps) raises:
        self.max_items = caps.arena_instances
        var shader = device.create_shader_module_wgsl(
            String(WIRE_WGSL) + "@fragment\nfn fs_main(in : WOut) -> @location(0) vec4<f32> {" + String(Self.K.FRAG) + "\n}\n", "wire",
        )
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "wire_layout")
        self.pipeline = pulled_pipeline(
            device, shader, layout, color_format, depth_format, TOPOLOGY_LINES, Self.K.BLEND, 0, Self.K.DEPTH_WRITE,
            Self.K.DEPTH_COMPARE,
        )
        self.buffer = device.create_buffer(
            UInt64((5 + 4 * caps.arena_instances) * 16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="wire",
        )
        var bg: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg, "wire_group")
        self.staging = List[Float32]()
        self.count = 0

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, caps)

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.staging.clear()
        for f in cam_floats(view):
            self.staging.append(f)
        for _ in range(4):
            self.staging.append(0.0)
        var count = 0
        for i in range(len(items)):
            if items[i].material == MAT_SKY or count >= self.max_items:
                continue
            var k = Real(0.5) if items[i].mesh_id >= 0 else Real(1.0)
            for x in [items[i].pos[0], items[i].pos[1], items[i].pos[2], Real(items[i].kind)]:
                self.staging.append(Float32(x))
            for x in [items[i].qx, items[i].qy, items[i].qz, items[i].qw]:
                self.staging.append(Float32(x))
            for x in [items[i].half[0] * k, items[i].half[1] * k, items[i].half[2] * k, Real(0)]:
                self.staging.append(Float32(x))
            for x in [items[i].color[0], items[i].color[1], items[i].color[2], Real(0)]:
                self.staging.append(Float32(x))
            count += 1
        self.staging[16] = Float32(count)
        device.queue_write_data(self.buffer, UInt64(0), self.staging)
        self.count = count

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if self.count == 0:
            return
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.draw(UInt32(WIRE_VERTS), UInt32(self.count), UInt32(0), UInt32(0))
