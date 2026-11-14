"""The skinned draw path (step 5 PR B): skinned meshes drawn with a palette that the vertex stage reads.

Six vertex buffers: positions (0), normals (1), uv (2), the instance records (3), joints as Uint16x4 (4) and weights as
Float32x4 (5). A draw item with pose_id >= 0 is skinned: pose_id is the index of the pose's first palette matrix, and
the instance record carries it in info.x, so the vertex shader reads palette[pose_id + joint].

The palette is a vertex-stage read-only storage buffer of 4096 matrices (256 KB: 64 instances x 64 joints, the step 5
capacity). The skinning arithmetic is SKIN_FN, the same source the compute path uses (app/skin_gpu.mojo)."""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUVertexFormat, WGPUVertexStepMode, WGPUIndexFormat,
)
from wgpu._ffi.nulls import null_opaque, null_ptr
from wgpu._ffi.structs import (
    WGPURenderPipelineDescriptor, WGPUVertexState, WGPUVertexBufferLayout, WGPUVertexAttribute,
    WGPUFragmentState, WGPUColorTargetState, WGPUPrimitiveState, WGPUMultisampleState,
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUBlendState, WGPUConstantEntry, WGPUStringView,
)
from wgpu._backend.wgpu_native.structs import str_to_sv
from wgpu._ffi.types import WGPUTextureFormat
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule
from game.arena import DrawItem
from game.camera_view import View
from app.mesh_pass import MeshRegistry, model_floats, MAX_MESH_INSTANCES, FLOATS_PER_INSTANCE
from app.skin_gpu import SKIN_FN

comptime MAX_PALETTE_MATRICES = 4096  # 64 instances x 64 joints: 256 KB of mat4x4<f32>

comptime SKIN_DRAW_WGSL = """
struct Cam { eye : vec4<f32>, right : vec4<f32>, up : vec4<f32>, fwd : vec4<f32> };
@group(0) @binding(0) var<uniform> cam : Cam;
@group(0) @binding(1) var<storage, read> palette : array<mat4x4<f32>>;
""" + SKIN_FN + """

struct SVIn {
  @location(0) pos : vec3<f32>,
  @location(1) nrm : vec3<f32>,
  @location(2) uv : vec2<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
  @location(7) color : vec4<f32>,
  @location(8) info : vec4<f32>,
  @location(9) joints : vec4<u32>,
  @location(10) weights : vec4<f32>,
};
struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec3<f32> };

@vertex
fn vs_skin(v : SVIn) -> VOut {
  let base = u32(v.info.x);
  let local = skin_position(v.pos, v.joints, v.weights, base);
  let sn = skin_normal(v.nrm, v.joints, v.weights, base);
  let m = mat4x4<f32>(v.m0, v.m1, v.m2, v.m3);
  let world = (m * vec4<f32>(local, 1.0)).xyz;
  let n = normalize((m * vec4<f32>(sn, 0.0)).xyz);
  let d = world - cam.eye.xyz;
  let x = dot(d, cam.right.xyz);
  let y = dot(d, cam.up.xyz);
  let z = dot(d, cam.fwd.xyz);
  let near = cam.up.w;
  let far = cam.fwd.w;
  var out : VOut;
  out.pos = vec4<f32>(x * cam.eye.w, y * cam.right.w, far * (z - near) / (far - near), z);
  let lit = 0.4 + 0.6 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  out.color = v.color.rgb * lit;
  return out;
}

@fragment
fn fs_skin(in : VOut) -> @location(0) vec4<f32> {
  return vec4<f32>(in.color, 1.0);
}
"""


def _build_skin_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, color_format: UInt32, depth_format: UInt32,
) raises -> RenderPipeline:
    """Six vertex buffers (see the module comment) and the arena's depth state."""
    var vs_name = String("vs_skin")
    var fs_name = String("fs_skin")
    var label_name = String("skin_pipeline")
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var a1 = raw_alloc[WGPUVertexAttribute](1)
    a1[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(1))
    var a2 = raw_alloc[WGPUVertexAttribute](1)
    a2[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x2, UInt64(0), UInt32(2))
    var ai = raw_alloc[WGPUVertexAttribute](6)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    ai[unsafe_offset=4] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(64), UInt32(7))
    ai[unsafe_offset=5] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(80), UInt32(8))
    var aj = raw_alloc[WGPUVertexAttribute](1)
    aj[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Uint16x4, UInt64(0), UInt32(9))
    var aw = raw_alloc[WGPUVertexAttribute](1)
    aw[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(10))
    var vb = raw_alloc[WGPUVertexBufferLayout](6)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a1)
    vb[unsafe_offset=2] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(8), UInt(1), a2)
    vb[unsafe_offset=3] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(6), ai)
    vb[unsafe_offset=4] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(8), UInt(1), aj)
    vb[unsafe_offset=5] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(16), UInt(1), aw)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv(vs_name),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(6), vb,
    )
    var target_p = raw_alloc[WGPUColorTargetState](1)
    target_p[unsafe_offset=0] = WGPUColorTargetState(null_opaque(), color_format, null_ptr[WGPUBlendState](), UInt64(0xF))
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, str_to_sv(fs_name),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(1), target_p,
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
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, fragment_p,
    )
    var result = device.create_render_pipeline(desc^)
    # the names are read by create_render_pipeline; keep them alive past that call
    _ = vs_name.byte_length() + fs_name.byte_length() + label_name.byte_length()
    a0.unsafe_free()
    a1.unsafe_free()
    a2.unsafe_free()
    ai.unsafe_free()
    aj.unsafe_free()
    aw.unsafe_free()
    vb.unsafe_free()
    target_p.unsafe_free()
    fragment_p.unsafe_free()
    dp.unsafe_free()
    return result^


struct SkinnedPass(Movable):
    """The skinned pass. Built once per device; upload() makes the skinned meshes' GPU copies; prepare() writes the
    camera, the palette and the instance records; record() draws, in the arena's render pass."""

    var pipeline: RenderPipeline
    var camera: Buffer
    var palette: Buffer
    var instances: Buffer
    var group: BindGroup
    var vbufs: List[Buffer]  # five per skinned mesh: positions, normals, uv, joints, weights
    var ibufs: List[Buffer]  # one per skinned mesh
    var uploaded: Int
    var order: List[Int]
    var counts: List[Int]
    var base: List[Int]

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(SKIN_DRAW_WGSL, "skin_draw")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "skin_layout")
        self.pipeline = _build_skin_pipeline(device, shader, layout, color_format, depth_format)
        self.camera = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="skin_cam")
        self.palette = device.create_buffer(
            UInt64(MAX_PALETTE_MATRICES * 64), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_palette_vs",
        )
        self.instances = device.create_buffer(
            UInt64(MAX_MESH_INSTANCES * FLOATS_PER_INSTANCE * 4),
            WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="skin_instances",
        )
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.camera.handle().raw, 0, UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(
                null_opaque(), 1, self.palette.handle().raw, 0, UInt64(MAX_PALETTE_MATRICES * 64), null_opaque(), null_opaque(),
            ),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "skin_group")
        self.vbufs = List[Buffer]()
        self.ibufs = List[Buffer]()
        self.uploaded = 0
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()

    def upload(mut self, device: Device, registry: MeshRegistry) raises:
        """Make the GPU copies of every skinned mesh not yet uploaded. Meshes are never freed here."""
        while self.uploaded < len(registry.skinned):
            var idx = self.uploaded
            var pos = device.create_buffer(UInt64(len(registry.skinned[idx].positions) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="skin_pos")
            device.queue_write_data(pos, UInt64(0), registry.skinned[idx].positions)
            var nrm = device.create_buffer(UInt64(len(registry.skinned[idx].normals) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="skin_nrm")
            device.queue_write_data(nrm, UInt64(0), registry.skinned[idx].normals)
            var uv = device.create_buffer(UInt64(len(registry.skinned[idx].uv) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="skin_uv")
            device.queue_write_data(uv, UInt64(0), registry.skinned[idx].uv)
            var jnt = device.create_buffer(UInt64(len(registry.skinned[idx].joints) * 2), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="skin_joints")
            device.queue_write_data(jnt, UInt64(0), registry.skinned[idx].joints)
            var wgt = device.create_buffer(UInt64(len(registry.skinned[idx].weights) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="skin_weights")
            device.queue_write_data(wgt, UInt64(0), registry.skinned[idx].weights)
            var ib = device.create_buffer(UInt64(len(registry.skinned[idx].indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="skin_idx")
            device.queue_write_data(ib, UInt64(0), registry.skinned[idx].indices)
            self.vbufs.append(pos^)
            self.vbufs.append(nrm^)
            self.vbufs.append(uv^)
            self.vbufs.append(jnt^)
            self.vbufs.append(wgt^)
            self.ibufs.append(ib^)
            self.uploaded += 1

    def prepare(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, palette: List[Float32], v: View,
    ) raises:
        """Everything that can fail: upload, group the skinned items by mesh, check the palette and instance limits,
        write the camera, the palette and the instance records. record() then only draws."""
        self.upload(device, registry)
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()
        for it in items:
            if it.pose_id < 0:
                continue
            if it.mesh_id < 0 or it.mesh_id >= len(registry.skinned):
                raise Error("skinned draw: an item names a skinned mesh that is not registered")
            var found = -1
            for k in range(len(self.order)):
                if self.order[k] == it.mesh_id:
                    found = k
            if found < 0:
                self.order.append(it.mesh_id)
                self.counts.append(0)
                found = len(self.order) - 1
            self.counts[found] += 1
        var total = 0
        for c in self.counts:
            total += c
        if total > MAX_MESH_INSTANCES:
            raise Error("skinned draw: more instances than MAX_MESH_INSTANCES")
        if len(palette) > MAX_PALETTE_MATRICES * 16:
            raise Error("skinned draw: the palette is larger than 4096 matrices")
        if len(palette) % 16 != 0:
            raise Error("skinned draw: a palette is 16 floats per joint")
        var cam = List[Float32]()
        for e in [v.eye, v.right, v.up, v.fwd]:
            for c in range(3):
                cam.append(Float32(e[c]))
            cam.append(0.0)
        cam[3] = Float32(v.sx)
        cam[7] = Float32(v.sy)
        cam[11] = Float32(v.near)
        cam[15] = Float32(v.far)
        device.queue_write_data(self.camera, UInt64(0), cam)
        if len(palette) > 0:
            device.queue_write_data(self.palette, UInt64(0), palette)
        var floats = List[Float32]()
        var running = 0
        for k in range(len(self.order)):
            self.base.append(running)
            for it in items:
                if it.pose_id >= 0 and it.mesh_id == self.order[k]:
                    var rec = len(floats)
                    model_floats(it, floats)
                    floats[rec + 20] = Float32(it.pose_id)  # info.x: the palette base of this instance
                    running += 1
        if total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)

    def record(self, mut rpass: FrameRenderPass, registry: MeshRegistry):
        """Draw the groups prepared by prepare(). Nothing here can fail. Each bind passes its exact byte size."""
        if len(self.order) == 0:
            return
        var total = 0
        for c in self.counts:
            total += c
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.set_vertex_buffer(UInt32(3), self.instances, UInt64(0), UInt64(total * FLOATS_PER_INSTANCE * 4))
        for k in range(len(self.order)):
            var mid = self.order[k]
            debug_assert(mid < self.uploaded, "skinned draw: a mesh is drawn before upload()")
            var pos_bytes = UInt64(len(registry.skinned[mid].positions) * 4)
            var nrm_bytes = UInt64(len(registry.skinned[mid].normals) * 4)
            var uv_bytes = UInt64(len(registry.skinned[mid].uv) * 4)
            var jnt_bytes = UInt64(len(registry.skinned[mid].joints) * 2)
            var wgt_bytes = UInt64(len(registry.skinned[mid].weights) * 4)
            var idx_bytes = UInt64(len(registry.skinned[mid].indices) * 4)
            rpass.set_vertex_buffer(UInt32(0), self.vbufs[5 * mid], UInt64(0), pos_bytes)
            rpass.set_vertex_buffer(UInt32(1), self.vbufs[5 * mid + 1], UInt64(0), nrm_bytes)
            rpass.set_vertex_buffer(UInt32(2), self.vbufs[5 * mid + 2], UInt64(0), uv_bytes)
            rpass.set_vertex_buffer(UInt32(4), self.vbufs[5 * mid + 3], UInt64(0), jnt_bytes)
            rpass.set_vertex_buffer(UInt32(5), self.vbufs[5 * mid + 4], UInt64(0), wgt_bytes)
            rpass.set_index_buffer(self.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), idx_bytes)
            rpass.draw_indexed(
                UInt32(len(registry.skinned[mid].indices)), UInt32(self.counts[k]), UInt32(0), Int32(0), UInt32(self.base[k]),
            )
