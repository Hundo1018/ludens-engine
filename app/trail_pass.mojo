"""Trails and ribbons (#140) as a RenderPass: the segments of `game/trails.mojo`, two triangles each, built in the vertex
shader from the two end points (vertex pulling, as the particle pass does).

    comptime MyPasses = Then[DefaultPasses, TrailPass]
    var i = r.passes.second.trails.add(TrailStyle(...))
    r.passes.second.trails.trails[i].move_to(time, x, y, z)   # each step, for what the trail follows
    r.passes.second.advance(time)                             # expire old points; the time the ages are taken at

What it shares with the particle pass (#121): the camera header (gpu_mesh.cam_floats), the blend pipelines
(gpu_blend.pulled_pipeline with BLEND_ALPHA / BLEND_ADD, depth tested, not written), the split into a sorted
alpha draw followed by an unsorted additive draw, and on the CPU side `curve_at`, `color3` and `merge_order`
(game/particles.mojo). A separate pass because a particle is one point and a segment is two.

Strip edge: at each end the strip is offset by +-width/2 along normalize(cross(tangent, eye - p)) (facing the camera) or
normalize(cross(tangent, up)) for a flat style (a tyre mark). The tangent at a point is shared by the two segments that
meet there, so their edges meet. Alpha falls off over the outer 40 % of the width.

Buffer (vec4<f32>): [0..3] camera; segment i is six elements at 4 + 6 i ([pA wA] [cA] [tA flat] [pB wB] [cB] [tB flat]).
`TRAIL_SEGMENTS` fit; the surplus of a frame is counted in `dropped_render`."""
from game.camera_view import View
from game.draw_item import DrawItem
from game.trails import TrailSystem, TRAIL_SEGMENT_FLOATS
from wgpu import WGPUBufferUsage, WGPUShaderStage, WGPUBindGroupLayoutEntry, WGPUBindGroupEntry
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.gpu_blend import pulled_pipeline, BLEND_ALPHA, BLEND_ADD, CULL_NONE, DEPTH_LESS_EQUAL
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass, DrawCounts
from app.textures import TextureArray
from app.bind_entries import storage_entry, buffer_bind

comptime TRAIL_SEGMENTS = 16384  # per frame: 16384 x 96 B = 1.5 MB

comptime TRAIL_WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;
struct TOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color : vec4<f32>,
  @location(1) edge : f32,
};
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> TOut {
  var order = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
  let k = order[vi];
  let end = k & 1u;
  let side = f32(k >> 1u) * 2.0 - 1.0;
  let b = 4u + ii * 6u + end * 3u;
  let p = data[b];
  let t = data[b + 2u];
  var across = cross(t.xyz, data[0].xyz - p.xyz);
  if t.w > 0.5 { across = cross(t.xyz, vec3<f32>(0.0, 1.0, 0.0)); }
  let l = length(across);
  if l < 1e-6 { across = vec3<f32>(0.0, 1.0, 0.0); } else { across = across / l; }
  let world = p.xyz + across * (side * p.w * 0.5);
  let d = world - data[0].xyz;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : TOut;
  out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
  if data[0].w < 0.0 { out.pos = vec4<f32>(-x * data[0].w, y * data[1].w, (z - near) / (far - near), 1.0); }
  out.color = data[b + 1u];
  out.edge = side;
  return out;
}
@fragment
fn fs_main(in : TOut) -> @location(0) vec4<f32> {
  let a = in.color.a * (1.0 - smoothstep(0.6, 1.0, abs(in.edge)));
  if ADDITIVE {
    return vec4<f32>(in.color.rgb * a, a);
  }
  return vec4<f32>(in.color.rgb, a);
}
"""


struct TrailPass(RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Trails"

    var trails: TrailSystem
    var time: Float64  # seconds: the ages are taken at this time
    var alpha_pipeline: RenderPipeline
    var add_pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var n_alpha: Int
    var n_add: Int
    var dropped_render: Int

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, samples: UInt32 = 1) raises:
        var alpha_shader = device.create_shader_module_wgsl("const ADDITIVE : bool = false;\n" + String(TRAIL_WGSL), "trails_alpha")
        var add_shader = device.create_shader_module_wgsl("const ADDITIVE : bool = true;\n" + String(TRAIL_WGSL), "trails_add")
        var entries: List[WGPUBindGroupLayoutEntry] = [storage_entry(0, WGPUShaderStage.VERTEX.value)]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "trails_layout")
        self.alpha_pipeline = pulled_pipeline(
            device, alpha_shader, layout, color_format, depth_format, 4, BLEND_ALPHA, CULL_NONE, False, DEPTH_LESS_EQUAL, samples,
        )
        self.add_pipeline = pulled_pipeline(
            device, add_shader, layout, color_format, depth_format, 4, BLEND_ADD, CULL_NONE, False, DEPTH_LESS_EQUAL, samples,
        )
        self.buffer = device.create_buffer(
            UInt64((4 + 6 * TRAIL_SEGMENTS) * 16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="trails",
        )
        var bg: List[WGPUBindGroupEntry] = [buffer_bind(0, self.buffer)]
        self.group = device.create_bind_group(bgl, bg, "trails_group")
        self.trails = TrailSystem()
        self.time = 0.0
        self.staging = List[Float32]()
        self.n_alpha = 0
        self.n_add = 0
        self.dropped_render = 0

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, UInt32(caps.samples))

    def advance(mut self, time: Float64):
        """Expire the points older than their lifetime at `time`; the next frame takes ages at `time`."""
        self.time = time
        self.trails.expire(time)

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.staging.clear()
        for f in cam_floats(view):
            self.staging.append(f)
        var counts = self.trails.pack(
            self.time, Float64(view.eye[0]), Float64(view.eye[1]), Float64(view.eye[2]),
            Float64(view.fwd[0]), Float64(view.fwd[1]), Float64(view.fwd[2]), self.staging, TRAIL_SEGMENTS,
        )
        self.n_alpha = counts[0]
        self.n_add = counts[1]
        self.dropped_render = self.trails.segments() - self.n_alpha - self.n_add
        if self.n_alpha + self.n_add > 0:
            device.queue_write_data(self.buffer, UInt64(0), self.staging)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if self.n_alpha > 0:
            rpass.set_pipeline(self.alpha_pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(6), UInt32(self.n_alpha), UInt32(0), UInt32(0))
        if self.n_add > 0:
            rpass.set_pipeline(self.add_pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(6), UInt32(self.n_add), UInt32(0), UInt32(self.n_alpha))

    def counts(self, meshes: MeshRegistry) -> DrawCounts:
        var d = (1 if self.n_alpha > 0 else 0) + (1 if self.n_add > 0 else 0)
        return DrawCounts(d, 2 * (self.n_alpha + self.n_add))
