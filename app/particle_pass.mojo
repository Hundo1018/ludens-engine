"""Particles (#121) as a RenderPass: camera-facing quads, one instance per particle, vertex pulling from a storage buffer.

The pass owns a `ParticleSystem` (game/particles.mojo, the CPU simulation). The host adds emitters to `pass.system` and
calls `pass.advance(dt, view)` once per simulation step; `prepare` packs the live particles for the frame's camera and
uploads them, `record_color` draws them:

    comptime MyPasses = Then[DefaultPasses, ParticlePass]
    var r = SceneRendererOf[MyPasses](device, format, view)
    _ = r.passes.second.system.add(particles_row(table, "spark"), 0.0, 1.0, 0.0, 7)

Draw order inside the pass: alpha-blended particles of all emitters, sorted far to near along the camera's forward axis
(one instanced draw), then the additive ones (a second instanced draw with the additive pipeline; addition does not depend
on order). Both test depth against the scene's depth buffer and do not write it. Place the pass after the opaque passes.

Particles are drawn unlit: no fog, no tone mapping, no shadow. The quad is the full `size` wide. A particle on layer 0 (the
engine's white layer) is a soft disc; a particle on another layer samples that texture array layer, and with a flipbook
(columns x rows > 1) the cell `frame`, which advances from the first to the last cell over the particle's life.

Buffer layout (vec4<f32> elements), as the primitive pass: [0] eye + sx, [1] right + sy, [2] up + near, [3] fwd + far,
[4] (count); particle i is three elements at 5 + 3 i: [x y z size], [r g b a], [layer frame cols rows].
`PARTICLE_RECORDS` records fit; a frame with more drops the surplus (`dropped_render`)."""
from game.camera_view import View
from game.draw_item import DrawItem
from game.particles import ParticleSystem
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu import null_opaque
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.gpu_blend import pulled_pipeline, BLEND_ALPHA, BLEND_ADD, DEPTH_LESS_EQUAL
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass
from app.textures import TextureArray

comptime PARTICLE_RECORDS = 131072  # per frame: 131072 x 48 B = 6 MB
comptime PARTICLE_CAP = 131072  # default global cap of live particles

comptime PARTICLE_WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;
@group(0) @binding(1) var tex : texture_2d_array<f32>;
@group(0) @binding(2) var samp : sampler;
struct POut {
  @builtin(position) pos : vec4<f32>,
  @location(0) corner : vec2<f32>,
  @location(1) color : vec4<f32>,
  @location(2) @interpolate(flat) info : vec4<f32>,
};
fn corner_of(i : u32) -> vec2<f32> {
  // two triangles: (-1,-1) (1,-1) (-1,1) (-1,1) (1,-1) (1,1)
  var order = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
  let k = order[i];
  return vec2<f32>(f32(k & 1u) * 2.0 - 1.0, f32(k >> 1u) * 2.0 - 1.0);
}
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> POut {
  let b = 5u + ii * 3u;
  let p = data[b];
  let c = corner_of(vi);
  let world = p.xyz + (data[1].xyz * c.x + data[2].xyz * c.y) * (p.w * 0.5);
  let d = world - data[0].xyz;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : POut;
  out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
  if data[0].w < 0.0 { out.pos = vec4<f32>(-x * data[0].w, y * data[1].w, (z - near) / (far - near), 1.0); }
  out.corner = c;
  out.color = data[b + 1u];
  out.info = data[b + 2u];
  return out;
}
@fragment
fn fs_main(in : POut) -> @location(0) vec4<f32> {
  let layer = i32(in.info.x + 0.5);
  let frame = u32(in.info.y + 0.5);
  let cols = max(u32(in.info.z + 0.5), 1u);
  let rows = max(u32(in.info.w + 0.5), 1u);
  let uv = vec2<f32>(in.corner.x * 0.5 + 0.5, 0.5 - in.corner.y * 0.5);
  let cell = vec2<f32>(f32(frame % cols), f32((frame / cols) % rows));
  let t = textureSampleLevel(tex, samp, (cell + uv) / vec2<f32>(f32(cols), f32(rows)), layer, 0.0);
  var a = in.color.a * t.a;
  if layer == 0 {
    a = a * (1.0 - smoothstep(0.0, 1.0, length(in.corner)));
  }
  let rgb = in.color.rgb * t.rgb;
  if ADDITIVE {
    return vec4<f32>(rgb * a, a);
  }
  return vec4<f32>(rgb, a);
}
"""


struct ParticlePass(RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Particles"

    var system: ParticleSystem
    var alpha_pipeline: RenderPipeline
    var add_pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var n_alpha: Int
    var n_add: Int
    var dropped_render: Int  # live particles this frame past PARTICLE_RECORDS, not drawn

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray, samples: UInt32 = 1) raises:
        var alpha_shader = device.create_shader_module_wgsl("const ADDITIVE : bool = false;\n" + String(PARTICLE_WGSL), "particles_alpha")
        var add_shader = device.create_shader_module_wgsl("const ADDITIVE : bool = true;\n" + String(PARTICLE_WGSL), "particles_add")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(3), UInt32(0)),  # float, 2D array
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(2), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),  # filtering
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "particles_layout")
        self.alpha_pipeline = pulled_pipeline(
            device, alpha_shader, layout, color_format, depth_format, 4, BLEND_ALPHA, 0, False, DEPTH_LESS_EQUAL, samples,
        )
        self.add_pipeline = pulled_pipeline(
            device, add_shader, layout, color_format, depth_format, 4, BLEND_ADD, 0, False, DEPTH_LESS_EQUAL, samples,
        )
        self.buffer = device.create_buffer(
            UInt64((5 + 3 * PARTICLE_RECORDS) * 16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="particles",
        )
        var bg: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), textures.view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), textures.main_sampler.handle().raw, null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg, "particles_group")
        self.system = ParticleSystem(PARTICLE_CAP)
        self.staging = List[Float32]()
        self.n_alpha = 0
        self.n_add = 0
        self.dropped_render = 0

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, textures, UInt32(caps.samples))

    def advance(mut self, dt: Float64, view: View):
        """One simulation step, with the camera at `view` for the emission LOD."""
        self.system.step(dt, Float64(view.eye[0]), Float64(view.eye[1]), Float64(view.eye[2]))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.staging.clear()
        for f in cam_floats(view):
            self.staging.append(f)
        for _ in range(4):
            self.staging.append(0.0)
        var counts = self.system.pack(
            Float64(view.eye[0]), Float64(view.eye[1]), Float64(view.eye[2]),
            Float64(view.fwd[0]), Float64(view.fwd[1]), Float64(view.fwd[2]), self.staging, PARTICLE_RECORDS,
        )
        self.n_alpha = counts[0]
        self.n_add = counts[1]
        self.dropped_render = self.system.live_total - self.n_alpha - self.n_add
        self.staging[16] = Float32(self.n_alpha + self.n_add)
        device.queue_write_data(self.buffer, UInt64(0), self.staging)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if self.n_alpha > 0:
            rpass.set_pipeline(self.alpha_pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(6), UInt32(self.n_alpha), UInt32(0), UInt32(0))
        if self.n_add > 0:
            rpass.set_pipeline(self.add_pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(6), UInt32(self.n_add), UInt32(0), UInt32(self.n_alpha))
