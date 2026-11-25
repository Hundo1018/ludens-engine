"""Multisample anti-aliasing (MSAA) for the scene's colour pass.

    var caps = RenderCaps.default()
    caps.samples = 4
    var r = SceneRendererOf[DefaultPasses](device, format, view, caps=caps)

`RenderCaps.samples` is 1 (the default, no change to any frame) or 4, the one multisample count every WebGPU device must
support for a renderable colour format and for Depth32Float; there is no query that could fail on the web, and no
other count is offered. Every pipeline of the passes in the list (primitives, meshes, skinned meshes, particles, wire
passes) is built with that count, and the renderer draws the passes into a 4-sample colour and depth target the size of
the scene, resolving the colour into what would have been drawn into directly: the frame (no stages), or the scene
colour the stages read.

With stages, the stages read depth. WebGPU cannot resolve depth, so a small pass copies sample 0 of the multisampled
depth into the one-sample depth the stages bind (`DepthResolve`). Sample 0 is one of the four, not their combination:
at an edge pixel the depth is that of one sample, while the colour is the mix of four.

The HUD, which has a pipeline of its own, is drawn after the resolve in a one-sample pass over the finished frame
(`begin_load_pass`, app/post.mojo), as it is when stages are on. The aux target's passes (app/render_pass.mojo `Aux`) are
built with one sample and draw into their own one-sample target. Not supported: Stereo (the renderer refuses the
combination), and passes written outside this repository unless they build their pipelines from `caps.samples`.

Cost: the colour and depth targets are four times the size (4 x 4 + 4 x 4 bytes a pixel for RGBA8 and Depth32Float,
about 66 MB at 1920 x 1080 before the resolve), and every fragment shader runs once per covered pixel, not once per
sample, so shading cost is close to unchanged while the rasteriser and the resolve do four times the work. The measured
frame cost is in docs/rendering-tier1.md.
"""
from wgpu import (
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout, WGPUTextureBindingLayout,
    WGPUStorageTextureBindingLayout, WGPUBindGroupEntry, WGPUShaderStage, WGPUTextureUsage,
)
from wgpu import (
    WGPURenderPipelineDescriptor, WGPUVertexState, WGPUFragmentState, WGPUPrimitiveState, WGPUMultisampleState,
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUConstantEntry, WGPUVertexBufferLayout, WGPUColorTargetState,
)
from wgpu import (
    WGPURenderPassDescriptor, WGPURenderPassColorAttachment, WGPURenderPassDepthStencilAttachment,
    WGPUPassTimestampWrites, WGPUColor, WGPUStringView,
)
from wgpu import null_opaque, null_ptr, str_to_sv, raw_alloc
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.command import CommandEncoder
from wgpu.device import Device
from app.gpu_bytes import texture_bytes
from wgpu.pipeline import RenderPipeline
from wgpu.render_pass import FrameRenderPass
from wgpu.texture import Texture, TextureView

comptime MSAA_SAMPLES: UInt32 = 4

comptime DEPTH_RESOLVE_WGSL = """
@group(0) @binding(0) var zms : texture_depth_multisampled_2d;
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}
struct DOut { @builtin(frag_depth) d : f32 };
@fragment
fn fs_main(@builtin(position) pos : vec4<f32>) -> DOut {
  var o : DOut;
  o.d = textureLoad(zms, vec2<i32>(pos.xy), 0);
  return o;
}
"""


struct MsaaTargets(Movable):
    """The multisampled colour and depth of one frame size."""

    var color: Texture
    var color_view: TextureView
    var depth: Texture
    var depth_view: TextureView
    var bytes: Int  # both targets: width x height x MSAA_SAMPLES samples x texel size (app/gpu_bytes.mojo: from sizes)

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, width: UInt32, height: UInt32) raises:
        self.bytes = (
            texture_bytes(Int(width), Int(height), 1, 1, color_format) + texture_bytes(Int(width), Int(height), 1, 1, depth_format)
        ) * Int(MSAA_SAMPLES)
        self.color = device.create_texture(
            width, height, 1, color_format, WGPUTextureUsage.RENDER_ATTACHMENT, sample_count=MSAA_SAMPLES, label="msaa_color",
        )
        self.depth = device.create_texture(
            width, height, 1, depth_format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            sample_count=MSAA_SAMPLES, label="msaa_depth",
        )
        self.color_view = self.color.create_view_default()
        self.depth_view = self.depth.create_view_default()

    def __init__(out self, *, deinit move: Self):
        self.color = move.color^
        self.color_view = move.color_view^
        self.depth = move.depth^
        self.depth_view = move.depth_view^
        self.bytes = move.bytes


def begin_msaa_pass(
    device: Device, enc: CommandEncoder, color_ms: TextureView, resolve: TextureView, depth_ms: TextureView,
    clear: WGPUColor, keep_depth: Bool,
) -> FrameRenderPass:
    """A render pass into the multisampled colour and depth, both cleared, the colour resolved into `resolve` when the
    pass ends and then discarded; the depth is kept only if `keep_depth` (a pass that reads it, DepthResolve)."""
    var label = String("scene_pass_msaa")
    var color_att_p = raw_alloc[WGPURenderPassColorAttachment](1)
    color_att_p[unsafe_offset=0] = WGPURenderPassColorAttachment(
        null_opaque(), color_ms.handle().raw, UInt32(0xFFFFFFFF), resolve.handle().raw, UInt32(2), UInt32(2), clear,
    )
    var depth_att_p = raw_alloc[WGPURenderPassDepthStencilAttachment](1)
    depth_att_p[unsafe_offset=0] = WGPURenderPassDepthStencilAttachment(
        null_opaque(), depth_ms.handle().raw, UInt32(2), UInt32(1) if keep_depth else UInt32(2), Float32(1.0), UInt32(0),
        UInt32(0), UInt32(0), UInt32(0), UInt32(0),
    )
    var rp_desc_p = raw_alloc[WGPURenderPassDescriptor](1)
    rp_desc_p[unsafe_offset=0] = WGPURenderPassDescriptor(
        null_opaque(), str_to_sv(label), UInt(1), color_att_p, depth_att_p, null_opaque(), null_ptr[WGPUPassTimestampWrites](),
    )
    var result = device.lib()[].command_encoder_begin_render_pass(enc.handle().raw, rp_desc_p)
    _ = label.byte_length()
    color_att_p.unsafe_free()
    depth_att_p.unsafe_free()
    rp_desc_p.unsafe_free()
    return FrameRenderPass(device.lib(), result, color_ms.clone())


struct DepthResolve(Movable):
    """Sample 0 of a multisampled depth texture written into a one-sample depth texture of the same size."""

    var pipeline: RenderPipeline
    var layout: BindGroupLayout
    var group: Optional[BindGroup]

    def __init__(out self, device: Device, depth_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(DEPTH_RESOLVE_WGSL, "depth_resolve")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(1)),  # depth, 2D, multisampled
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "depth_resolve_layout")
        var vs_name = String("vs_main")
        var fs_name = String("fs_main")
        var vertex_state = WGPUVertexState(
            null_opaque(), shader.handle().raw, str_to_sv(vs_name), UInt(0), null_ptr[WGPUConstantEntry](),
            UInt(0), null_ptr[WGPUVertexBufferLayout](),
        )
        var fragment_p = raw_alloc[WGPUFragmentState](1)
        fragment_p[unsafe_offset=0] = WGPUFragmentState(
            null_opaque(), shader.handle().raw, str_to_sv(fs_name), UInt(0), null_ptr[WGPUConstantEntry](),
            UInt(0), null_ptr[WGPUColorTargetState](),
        )
        var primitive = WGPUPrimitiveState(null_opaque(), UInt32(4), UInt32(0), UInt32(1), UInt32(0), UInt32(0))
        var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
        var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
        var dp = raw_alloc[WGPUDepthStencilState](1)
        dp[unsafe_offset=0] = WGPUDepthStencilState(
            null_opaque(), depth_format, UInt32(1), UInt32(8), face, face, UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF),
            Int32(0), Float32(0.0), Float32(0.0),
        )
        var desc = WGPURenderPipelineDescriptor(
            null_opaque(), str_to_sv("depth_resolve"), pl.handle().raw, vertex_state, primitive, dp, multisample, fragment_p,
        )
        self.pipeline = device.create_render_pipeline(desc^)
        _ = vs_name.byte_length() + fs_name.byte_length()
        _ = pl^
        _ = shader^
        fragment_p.unsafe_free()
        dp.unsafe_free()
        self.group = None

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.layout = move.layout^
        self.group = move.group^

    def bind(mut self, device: Device, depth_ms: TextureView) raises:
        var e: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, null_opaque(), 0, UInt64(0), null_opaque(), depth_ms.handle().raw),
        ]
        self.group = device.create_bind_group(self.layout, e, "depth_resolve_group")

    def record(self, enc: CommandEncoder, depth_view: TextureView):
        """A depth-only pass over `depth_view`, replacing its contents."""
        var label = String("depth_resolve")
        var depth_att_p = raw_alloc[WGPURenderPassDepthStencilAttachment](1)
        depth_att_p[unsafe_offset=0] = WGPURenderPassDepthStencilAttachment(
            null_opaque(), depth_view.handle().raw, UInt32(2), UInt32(1), Float32(1.0), UInt32(0),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0),
        )
        var rp_desc_p = raw_alloc[WGPURenderPassDescriptor](1)
        rp_desc_p[unsafe_offset=0] = WGPURenderPassDescriptor(
            null_opaque(), str_to_sv(label), UInt(0), null_ptr[WGPURenderPassColorAttachment](), depth_att_p, null_opaque(),
            null_ptr[WGPUPassTimestampWrites](),
        )
        var rp = enc.begin_render_pass(rp_desc_p)
        _ = label.byte_length()
        rp_desc_p.unsafe_free()
        depth_att_p.unsafe_free()
        rp.set_pipeline(self.pipeline)
        rp.set_bind_group(UInt32(0), self.group.value())
        rp.draw(UInt32(3))
        rp^.end()
