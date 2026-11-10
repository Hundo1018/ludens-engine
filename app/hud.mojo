"""The heads-up display: a `ui.draw.DrawList` of filled rectangles (panels and `ui.font` text), drawn as 2D quads on top
of the 3D scene in the same render pass. Positions are in pixels, origin top-left. Opaque: the pipeline helper has no
blend state, so panels are solid.

Buffer (f32): 4 header floats (width, height, 0, 0), then 6 per vertex: x y r g b a. Vertices come from `ui.batch.build_batch`."""
from depth_pipeline import depth_pipeline
from ui.batch import FLOATS_PER_VERTEX, build_batch
from ui.draw import DrawList
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
from wgpu.render_pass import RenderPassEncoder

comptime MAX_VERTS = 65536

comptime WGSL = """
@group(0) @binding(0) var<storage, read> data : array<f32>;

struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec4<f32> };

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> VOut {
  let b = 4u + vi * 6u;
  var out : VOut;
  out.pos = vec4<f32>(data[b] / data[0] * 2.0 - 1.0, 1.0 - data[b + 1u] / data[1] * 2.0, 0.0, 1.0);
  out.color = vec4<f32>(data[b + 2u], data[b + 3u], data[b + 4u], data[b + 5u]);
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  return in.color;
}
"""


struct Hud(Movable):
    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var verts: Int

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(WGSL, "hud")
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
        var layout = device.create_pipeline_layout(bgl, "hud_layout")
        self.pipeline = depth_pipeline(device, shader, layout, color_format, False, UInt32(8))
        var bytes = UInt64((4 + MAX_VERTS * FLOATS_PER_VERTEX) * 4)
        self.buffer = device.create_buffer(bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="hud")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "hud_group")
        self.staging = List[Float32]()
        self.verts = 0

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.buffer = move.buffer^
        self.group = move.group^
        self.staging = move.staging^
        self.verts = move.verts

    def set(mut self, list: DrawList, width: Float32, height: Float32):
        """Take this frame's draw list; the vertices are uploaded by `upload`."""
        var b = build_batch(list)
        self.staging.clear()
        self.staging.append(width)
        self.staging.append(height)
        self.staging.append(0.0)
        self.staging.append(0.0)
        self.verts = min(b.vertex_count(), MAX_VERTS)
        for i in range(self.verts * FLOATS_PER_VERTEX):
            self.staging.append(b.verts[i])

    def upload(self, device: Device) raises:
        if len(self.staging) > 0:
            device.queue_write_data(self.buffer, UInt64(0), self.staging)

    def record(self, rpass: RenderPassEncoder):
        if self.verts > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(self.verts), UInt32(1), UInt32(0), UInt32(0))
