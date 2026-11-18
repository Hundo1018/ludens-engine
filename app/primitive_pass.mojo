"""The arena's primitives (boxes and spheres by vertex pulling, lit and coloured per instance) as a RenderPass: the
items with no mesh (mesh_id < 0), up to RenderCaps.arena_instances per frame (the rest are dropped).

Buffer layout (vec4<f32> elements): [0] eye.xyz + sx, [1] right.xyz + sy, [2] up.xyz + near, [3] fwd.xyz + far, [4] (count);
instance i is four elements at 5 + 4 i: position + kind (0 box, 1 sphere), rotation xyzw, half extents, colour.
1152 vertices per instance (a 16 x 12 sphere); a box uses the first 36 and collapses the rest."""
from game.draw_item import DrawItem
from game.camera_view import View
from geometry.vec import Real
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.render_res import RenderResources, RenderCaps, LIGHTS_BYTES
from app.wgsl import POINT_LIGHTS_WGSL
from app.render_pass import RenderPass
from app.textures import TextureArray

comptime VERTS_PER_INSTANCE = 1152


comptime WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;

struct VOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color : vec3<f32>,
  @location(1) wpos : vec3<f32>,
  @location(2) wnrm : vec3<f32>,
  @location(3) base : vec3<f32>,
  @location(4) lit : f32,
};
@group(0) @binding(1) var<uniform> lights : Lights;

const NORMAL = array<vec3<f32>, 6>(
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(-1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, -1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, -1.0));
const TAN1 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0));
const TAN2 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0));
const QUAD = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
const PI = 3.14159265;

fn rotate(q : vec4<f32>, v : vec3<f32>) -> vec3<f32> {
  let t = 2.0 * cross(q.xyz, v);
  return v + q.w * t + cross(q.xyz, t);
}

@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VOut {
  let b = 5u + ii * 4u;
  let p = data[b].xyz;
  let kind = data[b].w;
  let q = data[b + 1u];
  let h = data[b + 2u].xyz;
  let base = data[b + 3u].xyz;
  var local = vec3<f32>(0.0);
  var normal = vec3<f32>(0.0, 1.0, 0.0);
  var live = true;
  if (kind < 0.5) {
    if (vi >= 36u) { live = false; }
    let face = (vi / 6u) % 6u;
    let k = QUAD[vi % 6u];
    local = (NORMAL[face] + (f32(k & 1u) * 2.0 - 1.0) * TAN1[face] + (f32(k >> 1u) * 2.0 - 1.0) * TAN2[face]) * h;
    normal = rotate(q, NORMAL[face]);
  } else {
    let quad = vi / 6u;
    let k = QUAD[vi % 6u];
    let seg = quad % 16u;
    let ring = quad / 16u;
    let a = f32(seg + (k & 1u)) / 16.0 * 2.0 * PI;
    let t = f32(ring + (k >> 1u)) / 12.0 * PI;
    let u = vec3<f32>(sin(t) * cos(a), cos(t), sin(t) * sin(a));
    local = u * h.x;
    normal = u;
  }
  let world = p + rotate(q, local);
  let eye = data[0].xyz;
  let d = world - eye;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : VOut;
  if (live) {
    out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
  } else {
    out.pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
  }
  let lit = 0.4 + 0.6 * max(dot(normal, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  out.color = base * lit;
  out.wpos = world;
  out.wnrm = normal;
  out.base = base;
  out.lit = lit;
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  // the point lights, per pixel, on top of the per-vertex sun; with none the vertex colour is used as it was
  if has_point_lights() {
    return vec4<f32>(in.base * (vec3<f32>(in.lit) + point_lights(in.wpos, normalize(in.wnrm))), 1.0);
  }
  return vec4<f32>(in.color, 1.0);
}
""" + POINT_LIGHTS_WGSL


def _put(mut staging: List[Float32], it: DrawItem):
    for v in [it.pos[0], it.pos[1], it.pos[2], Real(it.kind)]:
        staging.append(Float32(v))
    for v in [it.qx, it.qy, it.qz, it.qw]:
        staging.append(Float32(v))
    for v in [it.half[0], it.half[1], it.half[2], Real(0)]:
        staging.append(Float32(v))
    for v in [it.color[0], it.color[1], it.color[2], Real(0)]:
        staging.append(Float32(v))


struct PrimitivePass(RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Prim"

    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var max_items: Int  # RenderCaps.arena_instances
    var count: Int  # primitives this frame (prepare)

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref res: RenderResources, caps: RenderCaps) raises:
        caps.check()
        self.max_items = caps.arena_instances
        var shader = device.create_shader_module_wgsl(WGSL, "arena")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "arena_layout")
        self.pipeline = device.create_render_pipeline(
            shader, "vs_main", "fs_main", color_format, layout, depth_format=depth_format
        )
        var bytes = UInt64((5 + 4 * caps.arena_instances) * 16)
        self.buffer = device.create_buffer(bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="arena")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, res.lights.handle().raw, 0, UInt64(LIGHTS_BYTES), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "arena_group")
        self.staging = List[Float32]()
        self.count = 0

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, res, caps)

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        """The camera header, the count and one record per primitive (items with a mesh are the mesh passes')."""
        self.staging.clear()
        for f in cam_floats(view):
            self.staging.append(f)
        var count = 0
        for i in range(len(items)):
            if items[i].mesh_id >= 0 or count >= self.max_items:
                continue
            count += 1
        for _ in range(4):
            self.staging.append(0.0)
        self.staging[16] = Float32(count)
        var put = 0
        for i in range(len(items)):
            if items[i].mesh_id >= 0 or put >= count:
                continue
            _put(self.staging, items[i])
            put += 1
        device.queue_write_data(self.buffer, UInt64(0), self.staging)
        self.count = count

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.draw(UInt32(VERTS_PER_INSTANCE), UInt32(self.count), UInt32(0), UInt32(0))
