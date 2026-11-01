"""Draws the physics bodies as boxes by vertex pulling from one storage buffer.

Buffer layout (vec4<f32> elements): [0] = (aspect, count, 0, 0); body i is three elements at 1 + 3 i:
position, rotation quaternion (xyzw), half extents. 36 vertices per instance, no vertex buffer."""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.structs import WGPUColor
from wgpu._ffi.types import WGPUTextureHandle
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup

comptime CLEAR = WGPUColor(0.05, 0.06, 0.09, 1.0)
comptime MAX_BODIES = 4096

comptime WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;

struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec3<f32> };

const NORMAL = array<vec3<f32>, 6>(
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(-1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, -1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, -1.0));
const TAN1 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0));
const TAN2 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0));
const QUAD = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);

fn rotate(q : vec4<f32>, v : vec3<f32>) -> vec3<f32> {
  let t = 2.0 * cross(q.xyz, v);
  return v + q.w * t + cross(q.xyz, t);
}

@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VOut {
  let aspect = data[0].x;
  let b = 1u + ii * 3u;
  let p = data[b].xyz;
  let q = data[b + 1u];
  let h = data[b + 2u].xyz;
  let face = vi / 6u;
  let k = QUAD[vi % 6u];
  let local = NORMAL[face] + (f32(k & 1u) * 2.0 - 1.0) * TAN1[face] + (f32(k >> 1u) * 2.0 - 1.0) * TAN2[face];
  let world = p + rotate(q, local * h);
  // Fixed camera: eye (0, 6, 20), pitched down 0.2 rad.
  let s = sin(0.2);
  let c = cos(0.2);
  let v = world - vec3<f32>(0.0, 6.0, 20.0);
  let cam = vec3<f32>(v.x, v.y * c - v.z * s, -v.y * s - v.z * c);
  let near = 0.1;
  let far = 200.0;
  var out : VOut;
  out.pos = vec4<f32>(cam.x * 1.6 / aspect, cam.y * 1.6, far * (cam.z - near) / (far - near), cam.z);
  let lit = 0.35 + 0.65 * max(dot(rotate(q, NORMAL[face]), normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  let hue = f32(ii % 7u) / 7.0;
  var base = vec3<f32>(0.55 + 0.4 * hue, 0.75 - 0.35 * hue, 0.95 - 0.5 * hue);
  if (ii == 0u) { base = vec3<f32>(0.32, 0.34, 0.4); }
  out.color = base * lit;
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  return vec4<f32>(in.color, 1.0);
}
"""


struct Renderer(Movable):
    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(WGSL, "bodies")
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
        var layout = device.create_pipeline_layout(bgl, "bodies_layout")
        self.pipeline = device.create_render_pipeline(
            shader, "vs_main", "fs_main", color_format, layout, primitive_topology=UInt32(4)
        )
        var bytes = UInt64((1 + 3 * MAX_BODIES) * 16)
        self.buffer = device.create_buffer(bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="bodies")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "bodies_group")
        self.staging = List[Float32]()

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.buffer = move.buffer^
        self.group = move.group^
        self.staging = move.staging^

    def begin(mut self, aspect: Float32):
        self.staging.clear()
        self.staging.append(aspect)
        self.staging.append(0.0)
        self.staging.append(0.0)
        self.staging.append(0.0)

    def push(
        mut self, px: Float64, py: Float64, pz: Float64,
        qx: Float64, qy: Float64, qz: Float64, qw: Float64,
        hx: Float64, hy: Float64, hz: Float64,
    ):
        """One body: position, quaternion xyzw, half extents."""
        if (len(self.staging) - 4) // 12 >= MAX_BODIES:
            return
        for v in [px, py, pz, 0.0, qx, qy, qz, qw, hx, hy, hz, 0.0]:
            self.staging.append(Float32(v))

    def draw(mut self, device: Device, target: WGPUTextureHandle) raises:
        var count = (len(self.staging) - 4) // 12
        self.staging[1] = Float32(count)
        device.queue_write_data(self.buffer, UInt64(0), self.staging)
        var enc = device.create_command_encoder("frame")
        var rpass = enc.begin_surface_clear_pass(target, CLEAR, "frame_pass")
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.draw(UInt32(36), UInt32(count), UInt32(0), UInt32(0))
        rpass^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
