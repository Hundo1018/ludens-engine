"""The GPU skinning path (step 5 PR B): a compute shader that skins every vertex, and its readback.

SKIN_FN is the one WGSL source of the skinning arithmetic. The compute shader includes it here; the skinned vertex
shader includes the same string when the skinned draw path lands. The arithmetic matches cpu_skin: normalised
weights, all-zero weights leave the rest position, and the palette is column-major mat4x4."""
from wgpu import (
    Instance, WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry,
    WGPUBufferBindingLayout, WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout,
    WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu.bind_group import BindGroupLayout
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import ComputePipeline
from geometry.vec import Real, Vec3
from app.skin_pass import Skinning

comptime SKIN_FN = """
fn skin_position(p: vec3<f32>, j: vec4<u32>, w: vec4<f32>) -> vec3<f32> {
  let sw = w.x + w.y + w.z + w.w;
  if sw == 0.0 {
    return p;
  }
  var acc = mat4x4<f32>(vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0));
  for (var k = 0u; k < 4u; k = k + 1u) {
    acc = acc + palette[j[k]] * (w[k] / sw);
  }
  return (acc * vec4<f32>(p, 1.0)).xyz;
}
"""

comptime SKIN_CS = """
@group(0) @binding(0) var<storage, read> palette : array<mat4x4<f32>>;
@group(0) @binding(1) var<storage, read> rest : array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> joints : array<vec4<u32>>;
@group(0) @binding(3) var<storage, read> weights : array<vec4<f32>>;
@group(0) @binding(4) var<storage, read_write> skinned : array<vec4<f32>>;
""" + SKIN_FN + """

@compute @workgroup_size(64)
fn skin_cs(@builtin(global_invocation_id) gid : vec3<u32>) {
  let i = gid.x;
  if i >= arrayLength(&rest) {
    return;
  }
  skinned[i] = vec4<f32>(skin_position(rest[i].xyz, joints[i], weights[i]), 1.0);
}
"""


def _storage(binding: UInt32, readonly: Bool) -> WGPUBindGroupLayoutEntry:
    var kind = WGPUBufferBindingType.ReadOnlyStorage if readonly else WGPUBufferBindingType.Storage
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), kind, UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _entry(binding: UInt32, buffer: Buffer, bytes: UInt64) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, buffer.handle().raw, UInt64(0), bytes, null_opaque(), null_opaque())


struct GpuSkinning(Movable, Skinning):
    """The compute pipeline, built once per device. Buffers are made per call: the palette and vertex data change
    every frame in the game, and the pipeline is what is worth keeping."""

    var layout: BindGroupLayout
    var pipeline: ComputePipeline

    def __init__(out self, device: Device) raises:
        var shader = device.create_shader_module_wgsl(SKIN_CS, "skin")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            _storage(UInt32(0), True),
            _storage(UInt32(1), True),
            _storage(UInt32(2), True),
            _storage(UInt32(3), True),
            _storage(UInt32(4), False),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "skin_layout")
        self.pipeline = device.create_compute_pipeline(shader, "skin_cs", pl, "skin_cs")

    def skin(
        mut self, device: Device, palette: List[Float32], rest: List[Vec3], joints: List[Int], weights: List[Real]
    ) raises -> List[Vec3]:
        var n = len(rest)
        if n == 0:
            return List[Vec3]()
        if len(joints) != 4 * n or len(weights) != 4 * n:
            raise Error("gpu skinning: joints and weights take 4 entries per vertex")
        if len(palette) == 0 or len(palette) % 16 != 0:
            raise Error("gpu skinning: a palette is 16 floats per joint")
        var rest4 = List[Float32]()
        for v in rest:
            rest4.append(Float32(Float64(v[0])))
            rest4.append(Float32(Float64(v[1])))
            rest4.append(Float32(Float64(v[2])))
            rest4.append(0.0)
        var j4 = List[UInt32]()
        for j in joints:
            j4.append(UInt32(j))
        var w4 = List[Float32]()
        for w in weights:
            w4.append(Float32(Float64(w)))

        var palette_bytes = UInt64(len(palette) * 4)
        var vertex_bytes = UInt64(n * 16)
        var joint_bytes = UInt64(n * 16)
        var pal = device.create_buffer(palette_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_palette")
        var rst = device.create_buffer(vertex_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_rest")
        var jnt = device.create_buffer(joint_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_joints")
        var wgt = device.create_buffer(joint_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="skin_weights")
        var out = device.create_buffer(vertex_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="skin_out")
        var readback = device.create_buffer(vertex_bytes, WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="skin_read")
        device.queue_write_data(pal, UInt64(0), palette)
        device.queue_write_data(rst, UInt64(0), rest4)
        device.queue_write_data(jnt, UInt64(0), j4)
        device.queue_write_data(wgt, UInt64(0), w4)

        var bg_entries: List[WGPUBindGroupEntry] = [
            _entry(UInt32(0), pal, palette_bytes),
            _entry(UInt32(1), rst, vertex_bytes),
            _entry(UInt32(2), jnt, joint_bytes),
            _entry(UInt32(3), wgt, joint_bytes),
            _entry(UInt32(4), out, vertex_bytes),
        ]
        var bg = device.create_bind_group(self.layout, bg_entries, "skin_group")
        var enc = device.create_command_encoder("skin_enc")
        var cpass = enc.begin_compute_pass("skin_pass")
        cpass.set_pipeline(self.pipeline)
        cpass.set_bind_group(UInt32(0), bg)
        cpass.dispatch_workgroups(UInt32((n + 63) // 64))
        cpass^.end()
        enc.copy_buffer_to_buffer(out, UInt64(0), readback, UInt64(0), vertex_bytes)
        var cmd = enc^.finish("skin_cmd")
        device.queue_submit(cmd)

        var raw = readback.map_read()
        var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
        var result = List[Vec3]()
        for v in range(n):
            result.append(Vec3(
                Real(Float64(f[4 * v])),
                Real(Float64(f[4 * v + 1])),
                Real(Float64(f[4 * v + 2])),
                Real(0),
            ))
        readback.unmap()
        _ = bg^
        _ = pal^
        _ = rst^
        _ = jnt^
        _ = wgt^
        _ = out^
        return result^
