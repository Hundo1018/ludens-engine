"""Blend and cull modes for the passes that build their own pipeline descriptor (mesh, wire, strokes)."""
from wgpu import null_opaque, null_ptr
from wgpu import (
    WGPUBlendState, WGPUBlendComponent, WGPURenderPipelineDescriptor, WGPUVertexState, WGPUVertexBufferLayout,
    WGPUFragmentState, WGPUColorTargetState, WGPUPrimitiveState, WGPUMultisampleState, WGPUDepthStencilState,
    WGPUStencilFaceState, WGPUConstantEntry,
)
from wgpu import str_to_sv
from wgpu import raw_alloc
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule

comptime TOPOLOGY_LINES = 2  # WGPUPrimitiveTopology.LineList
comptime TOPOLOGY_TRIANGLES = 4
comptime DEPTH_LESS_EQUAL = 4  # WGPUCompareFunction
comptime DEPTH_GREATER = 5
comptime DEPTH_ALWAYS = 8

comptime BLEND_NONE = 0  # replace
comptime BLEND_ALPHA = 1  # src * a + dst * (1 - a)
comptime BLEND_ADD = 2  # src + dst: light adding up, order-independent
comptime BLEND_MULTIPLY = 3  # src * dst: ink over ink, a filter in front of a light

comptime CULL_NONE = 0
comptime CULL_FRONT = 1
comptime CULL_BACK = 2


def blend_state(mode: Int) -> WGPUBlendState:
    """The colour and alpha blend of a mode (WGPUBlendFactor: Zero 1, One 2, SrcAlpha 5, OneMinusSrcAlpha 6, Dst 7;
    operation Add 1)."""
    if mode == BLEND_ADD:
        return WGPUBlendState(WGPUBlendComponent(1, 2, 2), WGPUBlendComponent(1, 2, 2))
    if mode == BLEND_MULTIPLY:
        return WGPUBlendState(WGPUBlendComponent(1, 7, 1), WGPUBlendComponent(1, 7, 1))
    return WGPUBlendState(WGPUBlendComponent(1, 5, 6), WGPUBlendComponent(1, 2, 6))


def cull_mode(cull: Int) -> UInt32:
    """WGPUCullMode: None 1, Front 2, Back 3."""
    return UInt32(cull + 1)


def pulled_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, color_format: UInt32, depth_format: UInt32 = 0,
    topology: Int = TOPOLOGY_TRIANGLES, blend: Int = BLEND_NONE, cull: Int = CULL_NONE, depth_write: Bool = True,
    depth_compare: Int = DEPTH_LESS_EQUAL,
) raises -> RenderPipeline:
    """A pipeline with no vertex buffers (the vertex stage builds its geometry from the vertex and instance index),
    entry points vs_main and fs_main, one colour target. depth_format 0 is a pass without a depth attachment."""
    var vs_name = String("vs_main")
    var fs_name = String("fs_main")
    var label_name = String("pulled_pipeline")
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv(vs_name), UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(0), null_ptr[WGPUVertexBufferLayout](),
    )
    var blend_p = raw_alloc[WGPUBlendState](1)
    blend_p[unsafe_offset=0] = blend_state(blend)
    var target_p = raw_alloc[WGPUColorTargetState](1)
    target_p[unsafe_offset=0] = WGPUColorTargetState(
        null_opaque(), color_format, blend_p if blend != BLEND_NONE else null_ptr[WGPUBlendState](), UInt64(0xF),
    )
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, str_to_sv(fs_name), UInt(0), null_ptr[WGPUConstantEntry](), UInt(1), target_p,
    )
    var primitive = WGPUPrimitiveState(
        null_opaque(), UInt32(topology), UInt32(0), UInt32(1), cull_mode(cull) if cull != CULL_NONE else UInt32(0), UInt32(0),
    )
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1) if depth_write else UInt32(0), UInt32(depth_compare), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw, vertex_state, primitive,
        dp if depth_format != 0 else null_ptr[WGPUDepthStencilState](), multisample, fragment_p,
    )
    var result = device.create_render_pipeline(desc^)
    _ = vs_name.byte_length() + fs_name.byte_length() + label_name.byte_length()
    blend_p.unsafe_free()
    target_p.unsafe_free()
    fragment_p.unsafe_free()
    dp.unsafe_free()
    return result^
