"""The shadow depth pass (ludens-playground step 5): the mesh items drawn into a depth texture from a light, with no fragment stage.

The vertex stage places each instance with its model columns (locations 3 to 6, the mesh pass's instance layout) and the
light's view-projection, a uniform. The pass has no colour attachment; it clears the depth texture on load and stores it.
Its pipeline depth state is the mesh pass's (LessEqual, depth write), so a later sampling pass compares against the
same depths the light saw.

Moved here from ludens-playground (its app/shadow_pass.mojo): the mesh pass owns the shadow map it samples
(MeshPass.shadow_tex, set_shadow), so the pass that fills the map belongs beside it. A game supplies the light's
view-projection and the items that cast.
"""
from game.arena import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.textures import TextureArray, TRI_WGSL
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
from wgpu._ffi.structs import (
    WGPURenderPassDescriptor, WGPURenderPassColorAttachment, WGPURenderPassDepthStencilAttachment,
    WGPUPassTimestampWrites,
)
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule
from wgpu.pipeline_layout import PipelineLayout
from wgpu.render_pass import RenderPassEncoder
from wgpu.command import CommandEncoder
from wgpu.texture import TextureView
from app.mesh_pass import MeshRegistry, model_floats, FLOATS_PER_INSTANCE, RenderCaps
from app.gpu_mesh import GpuMeshCache, MeshBatches, STATIC_BUFFERS, S_POS, SKINNED_BUFFERS, K_POS, K_JNT, K_WGT
from app.skin_gpu import SKIN_FN
from app.wgsl import LIGHT_WGSL

comptime SHADOW_WGSL = LIGHT_WGSL + """

struct VsIn {
  @location(0) pos : vec3<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
}

@vertex
fn vs_main(i : VsIn) -> @builtin(position) vec4<f32> {
  let model = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
  return light.vp * model * vec4<f32>(i.pos, 1.0);
}
"""

# the skinned casters: the engine's skinning arithmetic (SKIN_FN, the source the drawn character uses), at the palette
# base the instance carries in info.x. Only positions are needed for depth.
comptime SKIN_SHADOW_WGSL = LIGHT_WGSL + """
@group(0) @binding(1) var<storage, read> palette : array<mat4x4<f32>>;
""" + SKIN_FN + """

struct SkVsIn {
  @location(0) pos : vec3<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
  @location(8) info : vec4<f32>,
  @location(9) joints : vec4<u32>,
  @location(10) weights : vec4<f32>,
}

@vertex
fn vs_skin(i : SkVsIn) -> @builtin(position) vec4<f32> {
  let base = u32(i.info.x);
  let local = skin_position(i.pos, i.joints, i.weights, base);
  let model = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
  return light.vp * model * vec4<f32>(local, 1.0);
}
"""

# the palette holds at most this many matrices (the engine's skinned limit); the storage buffer is sized for it


def _build_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, depth_format: UInt32,
) raises -> RenderPipeline:
    """Vertex buffers: 0 positions (per vertex), 1 the instance records (locations 3 to 6). No fragment stage, no
    colour targets: the pass has a depth attachment only."""
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var ai = raw_alloc[WGPUVertexAttribute](4)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    var vb = raw_alloc[WGPUVertexBufferLayout](2)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(4), ai)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv("vs_main"),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(2), vb,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var label_name = String("shadow_pipeline")
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, null_ptr[WGPUFragmentState](),
    )
    var result = device.create_render_pipeline(desc^)
    _ = label_name.byte_length()
    a0.unsafe_free()
    ai.unsafe_free()
    vb.unsafe_free()
    dp.unsafe_free()
    return result^


def _build_skin_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, depth_format: UInt32,
) raises -> RenderPipeline:
    """Vertex buffers: 0 positions, 1 joints (4 x u16), 2 weights (4 x f32), per vertex; 3 the instance records (model
    columns at locations 3 to 6, the palette base at 8). Same depth state as the static pipeline."""
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var a1 = raw_alloc[WGPUVertexAttribute](1)
    a1[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Uint16x4, UInt64(0), UInt32(9))
    var a2 = raw_alloc[WGPUVertexAttribute](1)
    a2[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(10))
    var ai = raw_alloc[WGPUVertexAttribute](5)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    ai[unsafe_offset=4] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(80), UInt32(8))
    var vb = raw_alloc[WGPUVertexBufferLayout](4)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(8), UInt(1), a1)
    vb[unsafe_offset=2] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(16), UInt(1), a2)
    vb[unsafe_offset=3] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(5), ai)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv("vs_skin"),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(4), vb,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var label_name = String("shadow_skin_pipeline")
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, null_ptr[WGPUFragmentState](),
    )
    var result = device.create_render_pipeline(desc^)
    _ = label_name.byte_length()
    a0.unsafe_free()
    a1.unsafe_free()
    a2.unsafe_free()
    ai.unsafe_free()
    vb.unsafe_free()
    dp.unsafe_free()
    return result^


struct ShadowPass(Movable):
    """The depth-only pipeline, the light's uniform, and the GPU copies of a MeshRegistry's meshes (its own
    GpuMeshCache until the pass shares the renderer's, plan 2.4)."""

    var pipeline: RenderPipeline
    var group: BindGroup
    var light: Buffer
    var instances: Buffer
    var gpu: GpuMeshCache
    var depth_format: UInt32
    var skin_pipeline: RenderPipeline
    var skin_group: BindGroup
    var palette_buf: Buffer  # the skinned casters' palette, uploaded per draw (the skin pass's buffer is written later)
    var skin_instances: Buffer
    var max_instances: Int  # RenderCaps.mesh_instances
    var max_palette: Int  # RenderCaps.palette_matrices

    def __init__(out self, device: Device, depth_format: UInt32, caps: RenderCaps = RenderCaps.default()) raises:
        caps.check()
        self.max_instances = caps.mesh_instances
        self.max_palette = caps.palette_matrices
        var shader = device.create_shader_module_wgsl(SHADOW_WGSL, "shadow_vs")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(bgl, "shadow_layout")
        self.pipeline = _build_pipeline(device, shader, pl, depth_format)
        self.light = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="shadow_light")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), self.light.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "shadow_group")
        self.instances = device.create_buffer(
            UInt64(caps.mesh_instances * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="shadow_instances",
        )
        self.gpu = GpuMeshCache()
        self.depth_format = depth_format
        var skin_shader = device.create_shader_module_wgsl(SKIN_SHADOW_WGSL, "shadow_skin_vs")
        var skin_entries: List[WGPUBindGroupLayoutEntry] = [
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
        var skin_bgl = device.create_bind_group_layout(skin_entries)
        var skin_pl = device.create_pipeline_layout(skin_bgl, "shadow_skin_layout")
        self.skin_pipeline = _build_skin_pipeline(device, skin_shader, skin_pl, depth_format)
        self.palette_buf = device.create_buffer(
            UInt64(caps.palette_matrices * 64), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="shadow_palette",
        )
        var skin_bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), self.light.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), UInt32(1), self.palette_buf.handle().raw, UInt64(0), UInt64(caps.palette_matrices * 64), null_opaque(), null_opaque()),
        ]
        self.skin_group = device.create_bind_group(skin_bgl, skin_bg_entries, "shadow_skin_group")
        self.skin_instances = device.create_buffer(
            UInt64(caps.mesh_instances * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="shadow_skin_instances",
        )

    def draw(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry,
        light_vp: List[Float32], depth_view: TextureView, palette: List[Float32],
    ) raises:
        """Write the light's view-projection (16 floats, column-major), upload the meshes, group the mesh items by mesh,
        and draw them into the depth view, cleared to 1.0 on load."""
        if len(light_vp) != 16:
            raise Error("shadow pass: the light's view-projection is 16 floats")
        self.gpu.sync(device, registry)
        device.queue_write_data(self.light, UInt64(0), light_vp)
        # the skinned casters: their palette goes to this pass's own buffer, so the shadow reads this frame's pose
        var skin = MeshBatches[True](items)
        if skin.total > self.max_instances:
            raise Error("shadow pass: more skinned instances than its capacity " + String(self.max_instances))
        if skin.total > 0:
            if len(palette) == 0 or len(palette) % 16 != 0 or len(palette) // 16 > self.max_palette:
                raise Error("shadow pass: the skinned palette is 16 floats per matrix, at most " + String(self.max_palette) + " matrices")
            device.queue_write_data(self.palette_buf, UInt64(0), palette)
        var stat = MeshBatches[False](items)
        if stat.total > self.max_instances:
            raise Error("shadow pass: more instances than its capacity " + String(self.max_instances))
        var floats = List[Float32]()
        for i in stat.members:
            model_floats(items[i], floats)
        if stat.total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)
        # skinned instance records: the mesh pass's layout, with the palette base in info.x (record float 20)
        var skin_floats = List[Float32]()
        for i in skin.members:
            var rec = len(skin_floats)
            model_floats(items[i], skin_floats)
            skin_floats[rec + 20] = Float32(items[i].pose_id)
        if skin.total > 0:
            device.queue_write_data(self.skin_instances, UInt64(0), skin_floats)

        var depth_att_p = raw_alloc[WGPURenderPassDepthStencilAttachment](1)
        depth_att_p[unsafe_offset=0] = WGPURenderPassDepthStencilAttachment(
            null_opaque(),
            depth_view.handle().raw,
            UInt32(2),  # depth load: Clear
            UInt32(1),  # depth store: Store
            Float32(1.0),
            UInt32(0),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0),  # stencil: unused
        )
        var rp_desc_p = raw_alloc[WGPURenderPassDescriptor](1)
        rp_desc_p[unsafe_offset=0] = WGPURenderPassDescriptor(
            null_opaque(),
            str_to_sv("shadow_depth"),
            UInt(0),
            null_ptr[WGPURenderPassColorAttachment](),
            depth_att_p,
            null_opaque(),
            null_ptr[WGPUPassTimestampWrites](),
        )
        # The encoder is created last, after every call that can raise: an encoder abandoned on an error path is a
        # compile error (linear types), so nothing that can raise may sit between its creation and its finish.
        var enc = device.create_command_encoder("shadow_enc")
        var rpass = enc.begin_render_pass(rp_desc_p)
        rp_desc_p.unsafe_free()
        depth_att_p.unsafe_free()
        if len(stat.order) > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.set_vertex_buffer(UInt32(1), self.instances, UInt64(0), UInt64(stat.total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(stat.order)):
                var mid = stat.order[k]
                var n_idx = len(registry.meshes[mid].indices)
                rpass.set_vertex_buffer(UInt32(0), self.gpu.vbufs[STATIC_BUFFERS * mid + S_POS], UInt64(0), UInt64(len(registry.meshes[mid].positions) * 4))
                rpass.set_index_buffer(self.gpu.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
                rpass.draw_indexed(UInt32(n_idx), UInt32(stat.counts[k]), UInt32(0), Int32(0), UInt32(stat.base[k]))
        if len(skin.order) > 0:
            rpass.set_pipeline(self.skin_pipeline)
            rpass.set_bind_group(UInt32(0), self.skin_group)
            rpass.set_vertex_buffer(UInt32(3), self.skin_instances, UInt64(0), UInt64(skin.total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(skin.order)):
                var smid = skin.order[k]
                var vb = SKINNED_BUFFERS * smid
                var n_idx = len(registry.skinned[smid].indices)
                rpass.set_vertex_buffer(UInt32(0), self.gpu.skin_vbufs[vb + K_POS], UInt64(0), UInt64(len(registry.skinned[smid].positions) * 4))
                rpass.set_vertex_buffer(UInt32(1), self.gpu.skin_vbufs[vb + K_JNT], UInt64(0), UInt64(len(registry.skinned[smid].joints) * 2))
                rpass.set_vertex_buffer(UInt32(2), self.gpu.skin_vbufs[vb + K_WGT], UInt64(0), UInt64(len(registry.skinned[smid].weights) * 4))
                rpass.set_index_buffer(self.gpu.skin_ibufs[smid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
                rpass.draw_indexed(UInt32(n_idx), UInt32(skin.counts[k]), UInt32(0), Int32(0), UInt32(skin.base[k]))
        rpass^.end()
        var cmd = enc^.finish("shadow_cmd")
        device.queue_submit(cmd)
