"""A render pipeline with a Depth32Float depth state, which `Device.create_render_pipeline` cannot make.

Copied from that helper (one colour target, triangle list, no blending) with the depth-stencil state filled in. Every pipeline
drawn in a pass that has a depth attachment needs one, the HUD's included (compare Always, no writes)."""
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.nulls import null_opaque, null_ptr
from wgpu._ffi.structs import (
    WGPUStringView, str_to_sv, WGPUVertexState, WGPUColorTargetState, WGPUFragmentState, WGPUPrimitiveState,
    WGPUMultisampleState, WGPURenderPipelineDescriptor, WGPUDepthStencilState, WGPUStencilFaceState,
    WGPUConstantEntry, WGPUBlendState, WGPUVertexBufferLayout,
)
from wgpu._ffi.types import WGPUTextureFormat
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule

comptime DEPTH_FORMAT = WGPUTextureFormat.Depth32Float


def depth_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, color_format: UInt32, write: Bool, compare: UInt32
) raises -> RenderPipeline:
    """`Device.create_render_pipeline`'s pipeline plus a depth state (compare function, writes on or off)."""
    var vs_sv = str_to_sv("vs_main")
    var fs_sv = str_to_sv("fs_main")
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, vs_sv, UInt(0), null_ptr[WGPUConstantEntry](), UInt(0), null_ptr[WGPUVertexBufferLayout](),
    )
    var target_p = raw_alloc[WGPUColorTargetState](1)
    target_p[unsafe_offset=0] = WGPUColorTargetState(null_opaque(), color_format, null_ptr[WGPUBlendState](), UInt64(0xF))
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, fs_sv, UInt(0), null_ptr[WGPUConstantEntry](), UInt(1), target_p,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), UInt32(4), UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))  # Always, Keep, Keep, Keep
    var depth_p = raw_alloc[WGPUDepthStencilState](1)
    depth_p[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), DEPTH_FORMAT, UInt32(1 if write else 0), compare, face, face, UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF),
        Int32(0), Float32(0.0), Float32(0.0),
    )
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), WGPUStringView.null_view(), layout.handle().raw, vertex_state, primitive, depth_p, multisample, fragment_p,
    )
    var result = device.create_render_pipeline(desc^)
    target_p.unsafe_free()
    fragment_p.unsafe_free()
    depth_p.unsafe_free()
    return result^
