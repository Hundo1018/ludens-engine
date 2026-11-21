"""Per-pixel screen velocity of the frame's bodies, for motion blur of things that move (app/lens.mojo
ObjectMotionBlur).

    comptime Blur = Stage[ObjectMotionBlur]
    var r = SceneRendererOf[MyPasses, Blur, Aux[VelocityPass]](device, format, view)
    r.shutter = 0.5

VelocityPass draws every rigid item (meshes, and boxes and spheres as the unit cube and sphere) into the aux target with
two transforms each: this frame's and the previous frame's, under this frame's and the previous frame's camera. A
fragment's colour is how far its surface point moved on screen between the two: rg = 128 / 255 + the move in uv
(x right, y down) over 0.125, in steps of 1 / 127; a = 1. The aux target is cleared with a = 0: where nothing was drawn
the stage falls back to the camera's motion.

Which item was which on the previous frame: a DrawItem has no identity, so each item is matched to the nearest item
of the previous frame with the same mesh and size within 64 places in the list (the same place first). A new item, or
one whose match is taken, has no velocity of its own for one frame. Skinned items are not drawn: their pixels blur by
what is behind them in the aux target.
"""
from std.math import sqrt
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUVertexFormat, WGPUVertexStepMode, WGPUIndexFormat,
)
from wgpu import null_opaque, null_ptr
from wgpu import (
    WGPURenderPipelineDescriptor, WGPUVertexState, WGPUVertexBufferLayout, WGPUVertexAttribute,
    WGPUFragmentState, WGPUColorTargetState, WGPUPrimitiveState, WGPUMultisampleState,
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUBlendState, WGPUConstantEntry,
)
from wgpu import str_to_sv
from wgpu import raw_alloc
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from game.draw_item import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.mesh_data import MeshRegistry
from app.mesh_pass import model_floats
from app.gpu_mesh import GpuMeshCache, MeshBatches, cam_floats, STATIC_BUFFERS, S_POS
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass
from app.textures import TextureArray

comptime VELOCITY_RANGE = 0.125  # the largest move stored, in uv (an eighth of the frame)

comptime VELOCITY_WGSL = """
// rows: 0-3 this frame's camera, 4-7 the previous one's (app/gpu_mesh.mojo cam_floats); then per instance 8 rows:
// this frame's model columns, the previous frame's
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;
struct VOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) now : vec4<f32>,
  @location(1) was : vec4<f32>,
};
fn clip(base : u32, world : vec3<f32>) -> vec4<f32> {
  let d = world - data[base].xyz;
  let x = dot(d, data[base + 1u].xyz);
  let y = dot(d, data[base + 2u].xyz);
  let z = dot(d, data[base + 3u].xyz);
  let near = data[base + 2u].w;
  let far = data[base + 3u].w;
  if data[base].w < 0.0 { return vec4<f32>(-x * data[base].w, y * data[base + 1u].w, (z - near) / (far - near), 1.0); }
  return vec4<f32>(x * data[base].w, y * data[base + 1u].w, far * (z - near) / (far - near), z);
}
@vertex
fn vs_main(@location(0) pos : vec3<f32>, @builtin(instance_index) ii : u32) -> VOut {
  let b = 8u + ii * 8u;
  let m_now = mat4x4<f32>(data[b], data[b + 1u], data[b + 2u], data[b + 3u]);
  let m_was = mat4x4<f32>(data[b + 4u], data[b + 5u], data[b + 6u], data[b + 7u]);
  var out : VOut;
  out.now = clip(0u, (m_now * vec4<f32>(pos, 1.0)).xyz);
  out.was = clip(4u, (m_was * vec4<f32>(pos, 1.0)).xyz);
  out.pos = out.now;
  return out;
}
@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  var d = vec2<f32>(0.0);
  if in.was.w > 1e-4 {   // behind the previous camera: no velocity
    let a = in.now.xy / in.now.w;
    let b = in.was.xy / in.was.w;
    d = vec2<f32>(a.x - b.x, b.y - a.y) * 0.5;   // in uv: x right, y down
  }
  let q = floor(clamp(d / VRANGE, vec2<f32>(-1.0), vec2<f32>(1.0)) * 127.0 + 0.5) + 128.0;
  return vec4<f32>(q / 255.0, 0.0, 1.0);
}
"""


def velocity_uv(r: UInt8, g: UInt8) -> Tuple[Float64, Float64]:
    """The move in uv a pixel of the velocity target stores (the stage's decoding, for tests)."""
    return ((Float64(Int(r)) - 128.0) / 127.0 * VELOCITY_RANGE, (Float64(Int(g)) - 128.0) / 127.0 * VELOCITY_RANGE)


def _build(device: Device, shader: ShaderModule, layout: PipelineLayout, color_format: UInt32, depth_format: UInt32) raises -> RenderPipeline:
    var vs_name = String("vs_main")
    var fs_name = String("fs_main")
    var label_name = String("velocity_pipeline")
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var vb = raw_alloc[WGPUVertexBufferLayout](1)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv(vs_name), UInt(0), null_ptr[WGPUConstantEntry](), UInt(1), vb,
    )
    var target_p = raw_alloc[WGPUColorTargetState](1)
    target_p[unsafe_offset=0] = WGPUColorTargetState(null_opaque(), color_format, null_ptr[WGPUBlendState](), UInt64(0xF))
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, str_to_sv(fs_name), UInt(0), null_ptr[WGPUConstantEntry](), UInt(1), target_p,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw, vertex_state, primitive, dp, multisample, fragment_p,
    )
    var result = device.create_render_pipeline(desc^)
    _ = vs_name.byte_length() + fs_name.byte_length() + label_name.byte_length()
    a0.unsafe_free()
    vb.unsafe_free()
    target_p.unsafe_free()
    fragment_p.unsafe_free()
    dp.unsafe_free()
    return result^


def as_mesh(it: DrawItem, res: RenderResources) -> DrawItem:
    """A box or sphere primitive as the unit cube or sphere mesh (as SceneRendererOf.push does for textured ones)."""
    var o = it.copy()
    if o.mesh_id < 0 and o.pose_id < 0:
        if o.kind == 1:
            o.half = Vec3(o.half[0], o.half[0], o.half[0], Real(0.0))
            o.mesh_id = res.unit_sphere
        else:
            o.mesh_id = res.unit_cube
        o.half = o.half * Real(2.0)
    return o^


def match_previous(now: List[DrawItem], was: List[DrawItem], window: Int = 64) -> List[Int]:
    """For each item of `now`, the index in `was` of the item it was (see the module note), or -1."""
    var out = List[Int]()
    var taken = List[Bool](length=len(was), fill=False)
    for i in range(len(now)):
        var best = -1
        var best_d = 1e30
        for j in range(max(0, i - window), min(len(was), i + window + 1)):
            if taken[j] or was[j].mesh_id != now[i].mesh_id:
                continue
            var same = True
            for c in range(3):
                if was[j].half[c] != now[i].half[c]:
                    same = False
            if not same:
                continue
            var d = now[i].pos - was[j].pos
            var dist = Float64(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
            if j == i:
                dist -= 1e-9  # the same place wins a tie
            if dist < best_d:
                best_d = dist
                best = j
        if best >= 0:
            taken[best] = True
        out.append(best)
    return out^


struct VelocityPass(RenderPass):
    comptime SHADOW: Bool = False

    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var max_items: Int
    var batches: MeshBatches[False]
    var was: List[DrawItem]  # the previous frame's rigid items, as meshes
    var was_cam: List[Float32]

    @staticmethod
    def sig() -> String:
        return "Velocity"

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, caps: RenderCaps) raises:
        caps.check()
        self.max_items = caps.mesh_instances
        var shader = device.create_shader_module_wgsl("const VRANGE = " + String(VELOCITY_RANGE) + ";\n" + String(VELOCITY_WGSL), "velocity")
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
        var layout = device.create_pipeline_layout(bgl, "velocity_layout")
        self.pipeline = _build(device, shader, layout, color_format, depth_format)
        self.buffer = device.create_buffer(
            UInt64((8 + 8 * caps.mesh_instances) * 16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="velocity",
        )
        var ge: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, ge, "velocity_group")
        self.batches = MeshBatches[False]()
        self.was = List[DrawItem]()
        self.was_cam = List[Float32]()

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
        gpu.sync(device, meshes)
        var now = List[DrawItem]()
        for it in items:
            if it.pose_id < 0:
                now.append(as_mesh(it, res))
        self.batches = MeshBatches[False](now)
        if self.batches.total > self.max_items:
            raise Error("velocity pass: more instances than its capacity " + String(self.max_items))
        var prev = match_previous(now, self.was)
        var cam = cam_floats(view)
        var staging = List[Float32]()
        for f in cam:
            staging.append(f)
        for i in range(16):
            staging.append(self.was_cam[i] if len(self.was_cam) == 16 else cam[i])
        for i in self.batches.members:
            var rec = List[Float32]()
            model_floats(now[i], rec)
            for k in range(16):
                staging.append(rec[k])
            var old = List[Float32]()
            if prev[i] >= 0:
                model_floats(self.was[prev[i]], old)
            for k in range(16):
                staging.append(old[k] if prev[i] >= 0 else rec[k])
        device.queue_write_data(self.buffer, UInt64(0), staging)
        self.was = now^
        self.was_cam = cam^

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if len(self.batches.order) == 0:
            return
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        for k in range(len(self.batches.order)):
            var mid = self.batches.order[k]
            var n_idx = len(meshes.meshes[mid].indices)
            rpass.set_vertex_buffer(UInt32(0), gpu.vbufs[STATIC_BUFFERS * mid + S_POS], UInt64(0), UInt64(len(meshes.meshes[mid].positions) * 4))
            rpass.set_index_buffer(gpu.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
            rpass.draw_indexed(UInt32(n_idx), UInt32(self.batches.counts[k]), UInt32(0), Int32(0), UInt32(self.batches.base[k]))
