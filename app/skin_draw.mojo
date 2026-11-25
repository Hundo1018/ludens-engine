"""The skinned draw path (step 5 PR B): skinned meshes drawn with a palette that the vertex stage reads.

Six vertex buffers: positions (0), normals (1), uv (2), the instance records (3), joints as Uint16x4 (4) and weights as
Float32x4 (5). A draw item with pose_id >= 0 is skinned: pose_id is the index of the pose's first palette matrix, and
the instance record carries it in info.x, so the vertex shader reads palette[pose_id + joint].

The palette is a vertex-stage read-only storage buffer of 4096 matrices (256 KB: 64 instances x 64 joints, the step 5
capacity). The skinning arithmetic is the pass's SkinBlend (app/skin_blend.mojo); LinearBlend is SKIN_FN, the source
the compute path uses (app/skin_gpu.mojo)."""
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
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule
from wgpu.texture import TextureView
from wgpu.sampler import Sampler
from game.draw_item import DrawItem
from game.camera_view import View
from app.mesh_pass import MeshRegistry, model_floats, FLOATS_PER_INSTANCE, RenderCaps
from app.gpu_mesh import GpuMeshCache, MeshBatches, SKINNED_BUFFERS, K_POS, K_NRM, K_UV, K_JNT, K_WGT
from app.textures import TextureArray
from app.skin_blend import SkinBlend, LinearBlend, MotorBlend
from app.textures import ATMO_WGSL, TRIPLANAR_FN_WGSL
from app.material import Material, Materials, MatColor, MatUv, MatTriplanar, MatSky, MatPbr, PBR_WGSL
from app.wgsl import CAM_WGSL, SHADOW_UBO_WGSL, PCF_WGSL, POINT_LIGHTS_WGSL, LOCAL_SHADOW_WGSL, ENV_WGSL, PROBES_WGSL
from app.render_res import RenderResources, LIGHTS_BYTES, PROBE_BYTES
from app.render_pass import RenderPass, DrawCounts


comptime SKIN_DRAW_WGSL = CAM_WGSL + SHADOW_UBO_WGSL + """
@group(0) @binding(1) var<storage, read> palette : array<mat4x4<f32>>;
@group(0) @binding(2) var tex : texture_2d_array<f32>;
@group(0) @binding(3) var samp : sampler;
// the sun's shadow map and its light (the mesh pass's bindings 3 to 5): the characters receive shadows too
@group(0) @binding(4) var shadow_map : texture_depth_2d;
@group(0) @binding(5) var shadow_cmp : sampler_comparison;
@group(0) @binding(6) var<uniform> shadow : Shadow;
@group(0) @binding(7) var<uniform> lights : Lights;
@group(0) @binding(8) var atlas_map : texture_depth_2d;
@group(0) @binding(9) var env_cube : texture_cube<f32>;
@group(0) @binding(10) var<storage, read> probes : array<vec4<f32>>;
""" + ATMO_WGSL + PCF_WGSL + TRIPLANAR_FN_WGSL + POINT_LIGHTS_WGSL + LOCAL_SHADOW_WGSL + PROBES_WGSL + ENV_WGSL + PBR_WGSL + """

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
struct VOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color : vec3<f32>,
  @location(1) uv : vec2<f32>,
  @location(2) @interpolate(flat) layer : u32,
  @location(3) @interpolate(flat) mat : u32,
  @location(4) lpos : vec3<f32>,
  @location(5) wnrm : vec3<f32>,
  @location(6) wpos : vec3<f32>,
  @location(7) base : vec3<f32>,
  @location(8) lit : f32,
  @location(9) @interpolate(flat) rm : vec2<f32>,
};

@vertex
fn vs_skin(v : SVIn) -> VOut {
  let base = u32(v.info.x);
  let local = skin_position(v.pos, v.joints, v.weights, base);
  let sn = skin_normal(v.nrm, v.joints, v.weights, base);
  let m = mat4x4<f32>(v.m0, v.m1, v.m2, v.m3);
  let world = (m * vec4<f32>(local, 1.0)).xyz;
  let n = normalize((m * vec4<f32>(sn, 0.0)).xyz);
  var out : VOut;
  out.pos = cam_clip(world);
  let lit = 0.4 + 0.6 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  out.color = v.color.rgb * lit;
  out.uv = v.uv;
  out.layer = u32(v.info.z);
  out.mat = u32(v.info.y);
  let lp = shadow.vp * vec4<f32>(world, 1.0);
  out.lpos = lp.xyz / lp.w;
  out.wnrm = n;
  out.wpos = world;
  out.base = v.color.rgb;
  out.lit = lit;
  out.rm = vec2<f32>(floor(v.info.w / 256.0) / 255.0, (v.info.w - floor(v.info.w / 256.0) * 256.0) / 255.0);  // MAT_PBR: roughness, metallic
  return out;
}

@fragment
fn fs_skin(in : VOut) -> @location(0) vec4<f32> {
  // with the shadow off the factor is exactly 1.0: the colour is unchanged bit for bit
  let ndl = max(dot(normalize(in.wnrm), sun_dir()), 0.0);
  let sf = select(1.0, shadow_at(in.wpos, normalize(in.wnrm), ndl), shadow.params.x > 0.5);
  // the item's material, shaded as on the mesh pass (app/material.mojo; the same pack)
  // the point lights, per pixel, on top of the per-vertex sun; with none the vertex colour is used as it was
  var lit3 = vec3<f32>(in.lit);
  var color = in.color;
  var extra = vec3<f32>(0.0);
  if rig_on() {
    let r = rig(in.lit, in.wpos, normalize(in.wnrm));
    lit3 = r.lit;
    extra = r.extra;
    color = in.base * lit3;
  } else if has_point_lights() {
    lit3 = lit3 + point_lights(in.wpos, normalize(in.wnrm));
    color = in.base * lit3;
  }
  return shade(in.mat, Surface(in.base, color, lit3, in.uv, in.layer, in.wpos, in.wnrm, sf, in.rm.x, in.rm.y, extra));
}
"""


def _build_skin_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, color_format: UInt32, depth_format: UInt32,
    samples: UInt32 = 1,
) raises -> RenderPipeline:
    """Six vertex buffers (see the module comment) and the scene's depth state."""
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
    var multisample = WGPUMultisampleState(null_opaque(), samples, UInt32(0xFFFFFFFF), UInt32(0))
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


struct SkinnedPassOf[B: SkinBlend, *Ms: Material](RenderPass):
    """The skinned pass. Built once per device; prepare() syncs the shared GpuMeshCache and writes the palette and the
    instance records; record() draws, in the scene's render pass. The camera, shadow and atmosphere uniforms are the
    renderer's RenderResources."""

    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Skin"

    var pipeline: RenderPipeline
    var palette: Buffer
    var instances: Buffer
    var group: BindGroup
    var batches: MeshBatches[True]  # this frame's skinned items by mesh (prepare)
    var max_instances: Int  # RenderCaps.mesh_instances
    var max_palette: Int  # RenderCaps.palette_matrices

    def __init__(
        out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources,
        caps: RenderCaps = RenderCaps.default(),
    ) raises:
        caps.check()
        self.max_instances = caps.mesh_instances
        self.max_palette = caps.palette_matrices
        var shader = device.create_shader_module_wgsl(SKIN_DRAW_WGSL + Self.B.WGSL + Materials[*Self.Ms].wgsl(), "skin_draw")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),  # the fragment reads the eye (fog)
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
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(2), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(3), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(3), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(4), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),  # depth, 2D
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(5), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(4)),  # comparison
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(6), WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(7), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(8), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),  # depth, 2D: the shadow atlas
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(9), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(4), UInt32(0)),  # float, cube: the environment
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(10), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "skin_layout")
        self.pipeline = _build_skin_pipeline(device, shader, layout, color_format, depth_format, UInt32(caps.samples))
        self.palette = device.create_buffer(
            UInt64(caps.palette_matrices * 64), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_palette_vs",
        )
        self.instances = device.create_buffer(
            UInt64(caps.mesh_instances * FLOATS_PER_INSTANCE * 4),
            WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="skin_instances",
        )
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, res.camera.handle().raw, 0, UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(
                null_opaque(), 1, self.palette.handle().raw, 0, UInt64(caps.palette_matrices * 64), null_opaque(), null_opaque(),
            ),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), textures.view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), textures.main_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), null_opaque(), res.shadow_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 5, null_opaque(), 0, UInt64(0), res.shadow_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 6, res.shadow_ubo.handle().raw, 0, UInt64(128), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 7, res.lights.handle().raw, 0, UInt64(LIGHTS_BYTES), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 8, null_opaque(), 0, UInt64(0), null_opaque(), res.atlas_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 9, null_opaque(), 0, UInt64(0), null_opaque(), res.env_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 10, res.probes.handle().raw, 0, UInt64(PROBE_BYTES), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "skin_group")
        self.batches = MeshBatches[True]()

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, textures, res, caps)

    def prepare(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        """Everything that can fail: sync the meshes' GPU copies, group the skinned items by mesh, check the palette
        and instance limits, write the palette and the instance records. record() then only draws."""
        gpu.sync(device, registry)
        for it in items:
            if it.pose_id >= 0 and (it.mesh_id < 0 or it.mesh_id >= len(registry.skinned)):
                raise Error("skinned draw: an item names a skinned mesh that is not registered")
        self.batches = MeshBatches[True](items)
        if self.batches.total > self.max_instances:
            raise Error("skinned draw: " + String(self.batches.total) + " instances, more than its capacity " + String(self.max_instances))
        if len(palette) > self.max_palette * 16:
            raise Error("skinned draw: the palette is larger than its capacity of " + String(self.max_palette) + " matrices")
        if len(palette) % 16 != 0:
            raise Error("skinned draw: a palette is 16 floats per joint")
        if len(palette) > 0:
            device.queue_write_data(self.palette, UInt64(0), palette)
        var floats = List[Float32]()
        for i in self.batches.members:
            var rec = len(floats)
            model_floats(items[i], floats)
            floats[rec + 20] = Float32(items[i].pose_id)  # info.x: the palette base of this instance
            floats[rec + 21] = Float32(items[i].material)  # info.y: material (0 colour, 1 uv)
            floats[rec + 22] = Float32(items[i].layer) if items[i].material > 0 else 0.0  # info.z: the texture layer
        if self.batches.total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)

    def record_color(self, mut rpass: FrameRenderPass, registry: MeshRegistry, gpu: GpuMeshCache):
        """Draw the groups prepared by prepare(). Nothing here can fail. Each bind passes its exact byte size."""
        if len(self.batches.order) == 0:
            return
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.set_vertex_buffer(UInt32(3), self.instances, UInt64(0), UInt64(self.batches.total * FLOATS_PER_INSTANCE * 4))
        for k in range(len(self.batches.order)):
            var mid = self.batches.order[k]
            debug_assert(mid < gpu.skinned_uploaded(), "skinned draw: a mesh is drawn before its GPU copy exists")
            var vb = SKINNED_BUFFERS * mid
            rpass.set_vertex_buffer(UInt32(0), gpu.skin_vbufs[vb + K_POS], UInt64(0), UInt64(len(registry.skinned[mid].positions) * 4))
            rpass.set_vertex_buffer(UInt32(1), gpu.skin_vbufs[vb + K_NRM], UInt64(0), UInt64(len(registry.skinned[mid].normals) * 4))
            rpass.set_vertex_buffer(UInt32(2), gpu.skin_vbufs[vb + K_UV], UInt64(0), UInt64(len(registry.skinned[mid].uv) * 4))
            rpass.set_vertex_buffer(UInt32(4), gpu.skin_vbufs[vb + K_JNT], UInt64(0), UInt64(len(registry.skinned[mid].joints) * 2))
            rpass.set_vertex_buffer(UInt32(5), gpu.skin_vbufs[vb + K_WGT], UInt64(0), UInt64(len(registry.skinned[mid].weights) * 4))
            var n_idx = len(registry.skinned[mid].indices)
            rpass.set_index_buffer(gpu.skin_ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
            rpass.draw_indexed(
                UInt32(n_idx), UInt32(self.batches.counts[k]), UInt32(0), Int32(0), UInt32(self.batches.base[k]),
            )

    def counts(self, registry: MeshRegistry) -> DrawCounts:
        var out = DrawCounts()
        for k in range(len(self.batches.order)):
            var n_idx = len(registry.skinned[self.batches.order[k]].indices)
            out.draws += 1
            out.triangles += n_idx // 3 * self.batches.counts[k]
        return out


comptime SkinnedPass = SkinnedPassOf[LinearBlend, MatColor, MatUv, MatTriplanar, MatSky, MatPbr]
"""The skinned pass with linear blend skinning and the built-in materials (the mesh pass's set)."""

comptime MotorSkinnedPass = SkinnedPassOf[MotorBlend, MatColor, MatUv, MatTriplanar, MatSky, MatPbr]
"""The skinned pass with motor blending (app/skin_blend.mojo): no candy-wrapper collapse under twist."""
