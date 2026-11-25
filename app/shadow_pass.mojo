"""The shadow depth pass (ludens-playground step 5): the mesh items drawn into a depth texture from a light, with no fragment stage.

The vertex stage places each instance with its model columns (locations 3 to 6, the mesh pass's instance layout) and the
light's view-projection, a uniform. The pass has no colour attachment; it clears the depth texture on load and stores it.
Its pipeline depth state is the mesh pass's (LessEqual, depth write), so a later sampling pass compares against the
same depths the light saw.

Moved here from ludens-playground (its app/shadow_pass.mojo): the mesh pass owns the shadow map it samples
(MeshPass.shadow_tex, set_shadow), so the pass that fills the map belongs beside it. A game supplies the light's
view-projection and the items that cast.
"""
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.textures import TextureArray, TRI_WGSL
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
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUBlendState, WGPUConstantEntry, WGPUStringView,
)
from wgpu import str_to_sv
from wgpu import WGPUTextureFormat
from wgpu import raw_alloc
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.render_pass import FrameRenderPass
from wgpu import (
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
from app.render_res import RenderResources
from app.lights import MAX_CASCADES
from app.render_pass import RenderPass
from app.cull import MeshBounds, item_radius
from std.math import sqrt

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


def begin_depth_pass(enc: CommandEncoder, depth_view: TextureView) -> RenderPassEncoder:
    """A depth-only render pass into `depth_view`, cleared to 1.0 and stored. Cannot fail, so it may sit between an
    encoder's creation and its finish."""
    var label = String("shadow_depth")
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
        str_to_sv(label),
        UInt(0),
        null_ptr[WGPURenderPassColorAttachment](),
        depth_att_p,
        null_opaque(),
        null_ptr[WGPUPassTimestampWrites](),
    )
    var rpass = enc.begin_render_pass(rp_desc_p)
    rp_desc_p.unsafe_free()
    depth_att_p.unsafe_free()
    return rpass^


struct ShadowCaster(Movable):
    """The depth-only pipelines (static and skinned casters), the light's uniform, the casters' palette and instance
    buffers. prepare() and record() take the GpuMeshCache to bind from: ShadowPass.draw passes its own, the renderer's
    pipeline passes the renderer's."""

    var pipeline: RenderPipeline
    var group: BindGroup
    var light: Buffer
    var instances: Buffer
    var depth_format: UInt32
    var stat: MeshBatches[False]  # this frame's static casters by mesh (prepare)
    var skin: MeshBatches[True]  # this frame's skinned casters by mesh
    var skin_pipeline: RenderPipeline
    var skin_group: BindGroup
    var palette_buf: Buffer  # the skinned casters' palette, uploaded per draw (the skin pass's buffer is written later)
    var skin_instances: Buffer
    var max_instances: Int  # RenderCaps.mesh_instances
    var max_palette: Int  # RenderCaps.palette_matrices
    # the shadow atlas (app/lights.mojo): one light uniform and one pair of bind groups per tile; the casters' buffers
    # are the sun's
    var tile_lights: List[Buffer]
    var tile_groups: List[BindGroup]
    var tile_skin_groups: List[BindGroup]
    var bgl: BindGroupLayout  # kept to make tile groups as more tiles are used
    var skin_bgl: BindGroupLayout
    var palette_bytes: Int
    # the sun's cascades 1 .. 3 (cascade 0 is `light` / `group`)
    var casc_lights: List[Buffer]
    var casc_groups: List[BindGroup]
    var casc_skin_groups: List[BindGroup]
    # the static casters per view (prepare_views): each cascade and atlas tile draws only the casters inside its view
    var culled: Bool  # prepare_views ran this frame; record_cascade / record_tile then draw per view
    var ncasc: Int  # views 0 .. ncasc - 1 are the sun's cascades, then the atlas tiles
    var vdraw: List[Int]  # per view, its mesh groups as (mesh, instances, first instance) triples
    var vstart: List[Int]  # view v's triples are vstart[v] .. vstart[v + 1] - 1
    var vinst: Buffer  # every view's instance records
    var vcap: Int  # vinst's capacity, instances
    var vtotal: Int

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
        self.depth_format = depth_format
        self.stat = MeshBatches[False]()
        self.skin = MeshBatches[True]()
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
        self.tile_lights = List[Buffer]()
        self.tile_groups = List[BindGroup]()
        self.tile_skin_groups = List[BindGroup]()
        self.casc_lights = List[Buffer]()
        self.casc_groups = List[BindGroup]()
        self.casc_skin_groups = List[BindGroup]()
        self.palette_bytes = caps.palette_matrices * 64
        self.culled = False
        self.ncasc = 0
        self.vdraw = List[Int]()
        self.vstart = List[Int]()
        self.vcap = 1024
        self.vtotal = 0
        self.vinst = device.create_buffer(
            UInt64(1024 * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_view_instances",
        )
        self.bgl = bgl^
        self.skin_bgl = skin_bgl^
        for _ in range(MAX_CASCADES - 1):
            var lb = self._light_buffer(device, "shadow_cascade_light")
            self.casc_groups.append(self._group(device, lb, "shadow_cascade_group"))
            self.casc_skin_groups.append(self._skin_group(device, lb, "shadow_cascade_skin_group"))
            self.casc_lights.append(lb^)

    def _light_buffer(self, device: Device, label: String) raises -> Buffer:
        return device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label=label)

    def _group(self, device: Device, lb: Buffer, label: String) raises -> BindGroup:
        var te: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), lb.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
        ]
        return device.create_bind_group(self.bgl, te, label)

    def _skin_group(self, device: Device, lb: Buffer, label: String) raises -> BindGroup:
        var tse: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), lb.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), UInt32(1), self.palette_buf.handle().raw, UInt64(0), UInt64(self.palette_bytes), null_opaque(), null_opaque()),
        ]
        return device.create_bind_group(self.skin_bgl, tse, label)

    def prepare_tiles(mut self, device: Device, res: RenderResources) raises:
        """Write the view-projection of every atlas tile in use (after prepare, which writes the casters); a tile's
        uniform and groups are made the first time it is used."""
        while len(self.tile_lights) < res.tiles:
            var lb = self._light_buffer(device, "shadow_tile_light")
            self.tile_groups.append(self._group(device, lb, "shadow_tile_group"))
            self.tile_skin_groups.append(self._skin_group(device, lb, "shadow_tile_skin_group"))
            self.tile_lights.append(lb^)
        for k in range(res.tiles):
            device.queue_write_data(self.tile_lights[k], UInt64(0), res.tile_vp(k))

    def prepare_cascades(self, device: Device, res: RenderResources) raises:
        """Write cascades 1 .. sun_count - 1's view-projections (cascade 0 is prepare's light_vp)."""
        for i in range(1, res.sun_count):
            device.queue_write_data(self.casc_lights[i - 1], UInt64(0), res.sun_vp(i))

    def prepare_views(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, mut bounds: MeshBounds,
        views: List[Float32], ncasc: Int,
    ) raises:
        """Sort the static casters into views (16 floats each: the cascades, then the atlas tiles): a caster goes to a
        view when its bounding sphere is inside all six planes of the view's clip volume, so a point light's six faces
        draw only what is in range, and a cascade only what reaches its square. The records of every view go into one
        buffer, made larger when they outgrow it. Skinned casters have no bound and go to every view (record's path)."""
        var n = len(views) // 16
        self.ncasc = ncasc
        self.vdraw = List[Int]()
        self.vstart = [0]
        var radius = List[Float64]()
        for it in items:
            radius.append(item_radius(it, registry, bounds) if MeshBatches[False].member(it) else -1.0)
        var floats = List[Float32]()
        var total = 0
        for v in range(n):
            # the planes of the clip volume (Gribb and Hartmann): w + x, w - x, w + y, w - y, z, w - z, from the rows
            var planes = List[Float64]()
            for k in range(6):
                for c in range(4):
                    var r0 = Float64(views[16 * v + 4 * c + 0])
                    var r1 = Float64(views[16 * v + 4 * c + 1])
                    var r2 = Float64(views[16 * v + 4 * c + 2])
                    var r3 = Float64(views[16 * v + 4 * c + 3])
                    var e = r3 + r0 if k == 0 else (r3 - r0 if k == 1 else (r3 + r1 if k == 2 else (r3 - r1 if k == 3 else (r2 if k == 4 else r3 - r2))))
                    planes.append(e)
            var subset = List[DrawItem]()
            for i in range(len(items)):
                if radius[i] < 0.0:
                    continue
                var inside = True
                for k in range(6):
                    var a = planes[4 * k]
                    var b = planes[4 * k + 1]
                    var c = planes[4 * k + 2]
                    var d = a * Float64(items[i].pos[0]) + b * Float64(items[i].pos[1]) + c * Float64(items[i].pos[2]) + planes[4 * k + 3]
                    if d < -radius[i] * sqrt(a * a + b * b + c * c):
                        inside = False
                        break
                if inside:
                    subset.append(items[i].copy())
            var b = MeshBatches[False](subset)
            for i in b.members:
                model_floats(subset[i], floats)
            for k in range(len(b.order)):
                self.vdraw.append(b.order[k])
                self.vdraw.append(b.counts[k])
                self.vdraw.append(total + b.base[k])
            total += b.total
            self.vstart.append(len(self.vdraw) // 3)
        if total > self.vcap:
            while self.vcap < total:
                self.vcap *= 2
            self.vinst = device.create_buffer(
                UInt64(self.vcap * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_view_instances",
            )
        self.vtotal = total
        if total > 0:
            device.queue_write_data(self.vinst, UInt64(0), floats)
        self.culled = True

    def _record_view(self, mut rpass: RenderPassEncoder, v: Int, group: BindGroup, skin_group: BindGroup, registry: MeshRegistry, gpu: GpuMeshCache):
        """View v's static casters (prepare_views), then every skinned caster."""
        var a = self.vstart[v]
        var e = self.vstart[v + 1]
        if e > a:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), group)
            rpass.set_vertex_buffer(UInt32(1), self.vinst, UInt64(0), UInt64(self.vtotal * FLOATS_PER_INSTANCE * 4))
            for k in range(a, e):
                var mid = self.vdraw[3 * k]
                var n_idx = len(registry.meshes[mid].indices)
                rpass.set_vertex_buffer(UInt32(0), gpu.vbufs[STATIC_BUFFERS * mid + S_POS], UInt64(0), UInt64(len(registry.meshes[mid].positions) * 4))
                rpass.set_index_buffer(gpu.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
                rpass.draw_indexed(UInt32(n_idx), UInt32(self.vdraw[3 * k + 1]), UInt32(0), Int32(0), UInt32(self.vdraw[3 * k + 2]))
        self._record_skinned(rpass, skin_group, registry, gpu)

    def record_cascade(self, mut rpass: RenderPassEncoder, i: Int, registry: MeshRegistry, gpu: GpuMeshCache):
        """The casters from cascade i's view; the caller has set the cascade's viewport."""
        if i == 0:
            self._record_either(rpass, 0, self.group, self.skin_group, registry, gpu)
        else:
            self._record_either(rpass, i, self.casc_groups[i - 1], self.casc_skin_groups[i - 1], registry, gpu)

    def _record_either(self, mut rpass: RenderPassEncoder, v: Int, group: BindGroup, skin_group: BindGroup, registry: MeshRegistry, gpu: GpuMeshCache):
        if self.culled:
            self._record_view(rpass, v, group, skin_group, registry, gpu)
        else:
            self._record(rpass, group, skin_group, registry, gpu)

    def prepare(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, mut gpu: GpuMeshCache,
        light_vp: List[Float32], palette: List[Float32],
    ) raises:
        """Write the light's view-projection (16 floats, column-major), sync the meshes' GPU copies, group the mesh
        items by mesh and write the casters' instance records and palette. Every item with a mesh casts."""
        if len(light_vp) != 16:
            raise Error("shadow pass: the light's view-projection is 16 floats")
        self.culled = False
        gpu.sync(device, registry)
        device.queue_write_data(self.light, UInt64(0), light_vp)
        # the skinned casters: their palette goes to this pass's own buffer, so the shadow reads this frame's pose
        self.skin = MeshBatches[True](items)
        if self.skin.total > self.max_instances:
            raise Error("shadow pass: more skinned instances than its capacity " + String(self.max_instances))
        if self.skin.total > 0:
            if len(palette) == 0 or len(palette) % 16 != 0 or len(palette) // 16 > self.max_palette:
                raise Error("shadow pass: the skinned palette is 16 floats per matrix, at most " + String(self.max_palette) + " matrices")
            device.queue_write_data(self.palette_buf, UInt64(0), palette)
        self.stat = MeshBatches[False](items)
        if self.stat.total > self.max_instances:
            raise Error("shadow pass: more instances than its capacity " + String(self.max_instances))
        var floats = List[Float32]()
        for i in self.stat.members:
            model_floats(items[i], floats)
        if self.stat.total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)
        # skinned instance records: the mesh pass's layout, with the palette base in info.x (record float 20)
        var skin_floats = List[Float32]()
        for i in self.skin.members:
            var rec = len(skin_floats)
            model_floats(items[i], skin_floats)
            skin_floats[rec + 20] = Float32(items[i].pose_id)
        if self.skin.total > 0:
            device.queue_write_data(self.skin_instances, UInt64(0), skin_floats)

    def record(self, mut rpass: RenderPassEncoder, registry: MeshRegistry, gpu: GpuMeshCache):
        """Draw the casters prepared by prepare() into a depth pass. Nothing here can fail."""
        self._record(rpass, self.group, self.skin_group, registry, gpu)

    def record_tile(self, mut rpass: RenderPassEncoder, tile: Int, registry: MeshRegistry, gpu: GpuMeshCache):
        """The casters from atlas tile `tile`'s view; the caller has set the tile's viewport."""
        if self.culled:
            self._record_view(rpass, self.ncasc + tile, self.tile_groups[tile], self.tile_skin_groups[tile], registry, gpu)
        else:
            self._record(rpass, self.tile_groups[tile], self.tile_skin_groups[tile], registry, gpu)

    def _record(self, mut rpass: RenderPassEncoder, group: BindGroup, skin_group: BindGroup, registry: MeshRegistry, gpu: GpuMeshCache):
        if len(self.stat.order) > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), group)
            rpass.set_vertex_buffer(UInt32(1), self.instances, UInt64(0), UInt64(self.stat.total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(self.stat.order)):
                var mid = self.stat.order[k]
                var n_idx = len(registry.meshes[mid].indices)
                rpass.set_vertex_buffer(UInt32(0), gpu.vbufs[STATIC_BUFFERS * mid + S_POS], UInt64(0), UInt64(len(registry.meshes[mid].positions) * 4))
                rpass.set_index_buffer(gpu.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
                rpass.draw_indexed(UInt32(n_idx), UInt32(self.stat.counts[k]), UInt32(0), Int32(0), UInt32(self.stat.base[k]))
        self._record_skinned(rpass, skin_group, registry, gpu)

    def _record_skinned(self, mut rpass: RenderPassEncoder, skin_group: BindGroup, registry: MeshRegistry, gpu: GpuMeshCache):
        if len(self.skin.order) > 0:
            rpass.set_pipeline(self.skin_pipeline)
            rpass.set_bind_group(UInt32(0), skin_group)
            rpass.set_vertex_buffer(UInt32(3), self.skin_instances, UInt64(0), UInt64(self.skin.total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(self.skin.order)):
                var smid = self.skin.order[k]
                var vb = SKINNED_BUFFERS * smid
                var n_idx = len(registry.skinned[smid].indices)
                rpass.set_vertex_buffer(UInt32(0), gpu.skin_vbufs[vb + K_POS], UInt64(0), UInt64(len(registry.skinned[smid].positions) * 4))
                rpass.set_vertex_buffer(UInt32(1), gpu.skin_vbufs[vb + K_JNT], UInt64(0), UInt64(len(registry.skinned[smid].joints) * 2))
                rpass.set_vertex_buffer(UInt32(2), gpu.skin_vbufs[vb + K_WGT], UInt64(0), UInt64(len(registry.skinned[smid].weights) * 4))
                rpass.set_index_buffer(gpu.skin_ibufs[smid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
                rpass.draw_indexed(UInt32(n_idx), UInt32(self.skin.counts[k]), UInt32(0), Int32(0), UInt32(self.skin.base[k]))


def record_atlas[P: RenderPass](passes: P, enc: CommandEncoder, res: RenderResources, meshes: MeshRegistry, gpu: GpuMeshCache):
    """The spot and point lights' shadow views (res.tiles of them), each into its tile of the atlas. Cannot fail."""
    var rp = begin_depth_pass(enc, res.atlas_view)
    for k in range(res.tiles):
        var q = res.tile_place(k)
        rp.set_viewport(Float32(q[0]), Float32(q[1]), Float32(q[2]), Float32(q[2]))
        rp.set_scissor_rect(UInt32(q[0]), UInt32(q[1]), UInt32(q[2]), UInt32(q[2]))
        passes.record_local_shadow(rp, k, meshes, gpu)
    rp^.end()


def casts_shadow(it: DrawItem) -> Bool:
    """The pipeline's caster rule: every item with a mesh except the sky (material 3), a sphere around the camera that
    would shadow the whole frame."""
    return it.mesh_id >= 0 and it.material != MAT_SKY


struct ShadowPass(RenderPass):
    """The sun's depth pass. Two ways to use it:

      - on its own: `draw(device, casters, registry, light_vp, depth_view, palette)` renders the given casters into
        `depth_view` (its own command buffer, its own copies of the meshes);
      - in a renderer's pass list, e.g. `SceneRendererOf[Then[ShadowPass, DefaultPasses]]`: while the renderer's
        shadow is on (set_shadow), it renders every item that casts_shadow() into the renderer's shadow map, in the
        frame's command buffer before the colour pass, from the renderer's mesh copies."""

    comptime SHADOW: Bool = True
    @staticmethod
    def sig() -> String:
        return "Shadow"

    var caster: ShadowCaster
    var gpu: GpuMeshCache  # draw()'s mesh copies; unused in a renderer's pass list
    var active: Bool  # prepared this frame in a pass list (the renderer's shadow is on)
    var places: List[Int]  # this frame's cascades: x, y, size in the sun's map
    var bounds: MeshBounds  # the meshes' bounding radii, for sorting the casters into views

    def __init__(out self, device: Device, depth_format: UInt32, caps: RenderCaps = RenderCaps.default()) raises:
        self.caster = ShadowCaster(device, depth_format, caps)
        self.gpu = GpuMeshCache()
        self.active = False
        self.places = List[Int]()
        self.bounds = MeshBounds()

    def draw(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry,
        light_vp: List[Float32], depth_view: TextureView, palette: List[Float32],
    ) raises:
        """Write the light's view-projection (16 floats, column-major), upload the meshes, group the mesh items by mesh,
        and draw them into the depth view, cleared to 1.0 on load."""
        self.caster.prepare(device, items, registry, self.gpu, light_vp, palette)
        # The encoder is created last, after every call that can raise: an encoder abandoned on an error path is a
        # compile error (linear types), so nothing that can raise may sit between its creation and its finish.
        var enc = device.create_command_encoder("shadow_enc")
        var rpass = begin_depth_pass(enc, depth_view)
        self.caster.record(rpass, registry, self.gpu)
        rpass^.end()
        var cmd = enc^.finish("shadow_cmd")
        device.queue_submit(cmd)

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, WGPUTextureFormat.Depth32Float, caps)  # the shadow map's format, not the colour pass's depth

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.active = res.shadow_on
        if not self.active and res.tiles == 0:
            return
        var casters = List[DrawItem]()
        for it in items:
            if casts_shadow(it):
                casters.append(it.copy())
        var vp = res.sun_vp(0)
        self.caster.prepare(device, casters, meshes, gpu, vp, palette)
        self.caster.prepare_cascades(device, res)
        self.caster.prepare_tiles(device, res)
        var views = List[Float32]()
        var ncasc = res.sun_count if self.active else 0
        for i in range(ncasc):
            views.extend(res.sun_vp(i))
        for k in range(res.tiles):
            views.extend(res.tile_vp(k))
        self.caster.prepare_views(device, casters, meshes, self.bounds, views, ncasc)
        self.places = List[Int]()
        for i in range(res.sun_count):
            var q = res.sun_place(i)
            self.places.append(q[0]); self.places.append(q[1]); self.places.append(q[2])

    def record_shadow(self, mut rpass: RenderPassEncoder, meshes: MeshRegistry, gpu: GpuMeshCache):
        if self.active:
            for i in range(len(self.places) // 3):
                var x = self.places[3 * i]
                var y = self.places[3 * i + 1]
                var t = self.places[3 * i + 2]
                rpass.set_viewport(Float32(x), Float32(y), Float32(t), Float32(t))
                rpass.set_scissor_rect(UInt32(x), UInt32(y), UInt32(t), UInt32(t))
                self.caster.record_cascade(rpass, i, meshes, gpu)

    def record_local_shadow(self, mut rpass: RenderPassEncoder, tile: Int, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.caster.record_tile(rpass, tile, meshes, gpu)
