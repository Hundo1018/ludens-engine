"""Volumetric fog on a froxel grid (#141): light that the sun and the point lights scatter in the air, with the sun's
shadow cutting it into shafts.

    var r = SceneRendererOf[DefaultPasses, VolumetricFog](device, format, view)
    r.vol_density = 0.04       # extinction per metre at the base height; 0 returns the input unchanged
    r.vol_anisotropy = 0.6     # Henyey-Greenstein g: forward scattering, brighter toward the sun
    r.vol_falloff = 0.15       # per metre above vol_base: the density times exp(-falloff * height)
    r.vol_albedo = 0.9         # the scattered share of the extinction
    r.vol_far = 64.0           # the grid's far end along the view, metres
    r.vol_ambient = 0.3        # the share of the environment's light the fog scatters evenly
    comptime Look = ThenPost[VolumetricFog, Bloom]   # a stage like any other

Three steps per frame, all on the GPU:

1. inject (compute, one invocation per froxel): the grid is FROXELS_X x FROXELS_Y x FROXELS_Z cells over the view,
   sliced exponentially in view depth from FROXEL_NEAR to `vol_far`. At each cell's centre: the extinction (the density
   with its height falloff), and the light scattered toward the eye: the sun (the renderer's `Lights.sun_*`) times the
   phase function and the sun's shadow map at that point (the renderer's `Shadow.vp`; a cell outside the map is lit),
   each point light (colour times intensity, the passes' range falloff, no shadow), and `vol_ambient` times the
   environment's mean radiance (the spherical harmonics' constant term, or 0.4 grey before an environment is set).
   Stored as (scattered light per metre, extinction) in an RGBA16Float 3D texture.
2. integrate (compute, one invocation per column): front to back, each cell's light added with the energy-conserving
   form of Hillaire (Physically Based and Unified Volumetric Rendering in Frostbite, SIGGRAPH 2015):
   S += T * L * (1 - exp(-sigma * dl)) / sigma, T *= exp(-sigma * dl), with dl the length of the ray inside the slice.
   Cell k then holds what is in front of the far edge of slice k.
3. composite (fragment): at each pixel, its view depth (the scene's depth; the sky counts as `vol_far`) is turned into a
   slice coordinate and the integrated grid read there with trilinear filtering: out = colour * T + S.

The scene's colour is already tone mapped, so the fog's light adds to display colour: a sun of colour 1 seen through
fog of optical depth tau gives (1 - exp(-tau)) * albedo * phase-weighted light. Not handled: spot, directional and area
lights; the point lights' shadows; temporal reprojection (each frame is computed from scratch, so the slices show as
bands where the density changes fast along the view; FROXELS_Z = 64 keeps them below 1 % of the grid's range).
"""
from std.math import exp, log
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout,
    WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUTextureFormat, WGPUTextureUsage, WGPUColor,
)
from wgpu import null_opaque
from wgpu import BufferHandle
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu.pipeline import ComputePipeline, RenderPipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.sampler import Sampler
from wgpu.texture import Texture, TextureView
from app.post import PostEffect, PostInputs, FRAME_WGSL, FRAME_BYTES, POST_MAIN_WGSL
from app.wgsl import SHADOW_UBO_WGSL, POINT_LIGHTS_WGSL, NO_LOCAL_SHADOW_WGSL, NO_PROBES_WGSL, NO_LIGHT_TEX_WGSL
from app.lights import LIGHTS_BYTES
from app.render_res import SHADOW_UBO_BYTES
from app.gpu_bytes import texture_bytes

comptime FROXELS_X = 160
comptime FROXELS_Y = 90
comptime FROXELS_Z = 64
comptime FROXEL_NEAR = 0.5  # metres: the near end of the grid (nearer pixels read the first slice)
comptime VOLUME_FORMAT = WGPUTextureFormat.RGBA16Float

# the grid's geometry, shared by the three shaders
comptime FROXEL_WGSL = """
const FX = 160u;
const FY = 90u;
const FZ = 64u;
const FNEAR = 0.5;
fn vol_far() -> f32 { return max(frame.vol2.y, FNEAR * 1.01); }
// view depth at slice coordinate s in 0 .. FZ (exponential)
fn slice_z(s : f32) -> f32 { return FNEAR * pow(vol_far() / FNEAR, s / f32(FZ)); }
// slice coordinate of a view depth
fn z_slice(z : f32) -> f32 { return f32(FZ) * log(max(z, FNEAR) / FNEAR) / log(vol_far() / FNEAR); }
// the world point at uv (0..1, y down) and view depth z, and the ray's length per metre of view depth
fn froxel_world(uv : vec2<f32>, z : f32) -> vec3<f32> {
  var nx = (uv.x * 2.0 - 1.0) * z / frame.eye.w;
  var ny = (1.0 - uv.y * 2.0) * z / frame.right.w;
  if frame.eye.w < 0.0 {
    nx = (uv.x * 2.0 - 1.0) / -frame.eye.w;
    ny = (1.0 - uv.y * 2.0) / frame.right.w;
  }
  return frame.eye.xyz + frame.right.xyz * nx + frame.up.xyz * ny + frame.fwd.xyz * z;
}
fn ray_stretch(uv : vec2<f32>) -> f32 {
  if frame.eye.w < 0.0 { return 1.0; }
  let nx = (uv.x * 2.0 - 1.0) / frame.eye.w;
  let ny = (1.0 - uv.y * 2.0) / frame.right.w;
  return sqrt(1.0 + nx * nx + ny * ny);
}
"""

comptime INJECT_WGSL = """
@group(0) @binding(0) var<uniform> frame : Frame;
@group(0) @binding(1) var<uniform> lights : Lights;
@group(0) @binding(2) var<uniform> shadow : Shadow;
@group(0) @binding(3) var shadow_map : texture_depth_2d;
@group(0) @binding(4) var cells : texture_storage_3d<rgba16float, write>;

fn hg(c : f32, g : f32) -> f32 {
  let d = 1.0 + g * g - 2.0 * g * c;
  return (1.0 - g * g) / (4.0 * L_PI * d * sqrt(d));
}
// the sun's map at a world point: the cascade its view depth z falls in (app/wgsl.mojo SHADOW_UBO_WGSL)
fn sun_visible(w : vec3<f32>, z : f32) -> f32 {
  if shadow.params.x < 0.5 { return 1.0; }
  let i = cascade_for(z);
  if i >= cascade_count() { return 1.0; }
  let q = cascade_uv(i, w);
  if q.w < 0.5 || q.z < 0.0 { return 1.0; }
  let d = vec2<i32>(textureDimensions(shadow_map));
  let t = clamp(vec2<i32>(q.xy * vec2<f32>(d)), vec2<i32>(0), d - vec2<i32>(1));
  return select(0.0, 1.0, q.z <= textureLoad(shadow_map, t, 0) + 0.002);
}
fn density(w : vec3<f32>) -> f32 {
  return frame.vol.x * exp(-frame.vol.z * max(w.y - frame.vol.w, 0.0));
}

@compute @workgroup_size(8, 8, 1)
fn inject(@builtin(global_invocation_id) id : vec3<u32>) {
  if id.x >= FX || id.y >= FY || id.z >= FZ { return; }
  let uv = (vec2<f32>(f32(id.x), f32(id.y)) + 0.5) / vec2<f32>(f32(FX), f32(FY));
  let z = slice_z(f32(id.z) + 0.5);
  let w = froxel_world(uv, z);
  let sigma = density(w);
  let view_dir = normalize(w - frame.eye.xyz);  // from the eye
  let g = clamp(frame.vol.y, -0.95, 0.95);
  var l = lights.sun_color.rgb * hg(dot(view_dir, sun_dir()), g) * sun_visible(w, z);
  let np = min(u32(lights.n.x), 16u);
  for (var i = 0u; i < np; i++) {
    let d = lights.l[i].pos_range.xyz - w;
    let dist = max(length(d), 1e-4);
    l += lights.l[i].color.rgb * lights.l[i].color.w * point_atten(i, w) * hg(dot(view_dir, d / dist), g);
  }
  var amb = vec3<f32>(0.4);
  if ambient_set() { amb = lights.sh[0].rgb * 0.2820948; }  // the mean radiance: Y00 times its coefficient
  l += amb * frame.vol2.z / (4.0 * L_PI);
  textureStore(cells, vec3<i32>(id), vec4<f32>(l * sigma * clamp(frame.vol2.x, 0.0, 1.0), sigma));
}
"""

comptime INTEGRATE_WGSL = """
@group(0) @binding(0) var<uniform> frame : Frame;
@group(0) @binding(1) var cells : texture_3d<f32>;
@group(0) @binding(2) var sums : texture_storage_3d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn integrate(@builtin(global_invocation_id) id : vec3<u32>) {
  if id.x >= FX || id.y >= FY { return; }
  let uv = (vec2<f32>(f32(id.x), f32(id.y)) + 0.5) / vec2<f32>(f32(FX), f32(FY));
  let stretch = ray_stretch(uv);
  var s = vec3<f32>(0.0);
  var t = 1.0;
  for (var k = 0u; k < FZ; k++) {
    let c = textureLoad(cells, vec3<i32>(i32(id.x), i32(id.y), i32(k)), 0);
    var dl = (slice_z(f32(k) + 1.0) - slice_z(f32(k))) * stretch;
    if k == 0u { dl = slice_z(1.0) * stretch; }  // the first slice reaches back to the eye
    let sigma = max(c.a, 1e-7);
    let tr = exp(-sigma * dl);
    s += t * c.rgb * (1.0 - tr) / sigma;
    t *= tr;
    textureStore(sums, vec3<i32>(i32(id.x), i32(id.y), i32(k)), vec4<f32>(s, t));
  }
}
"""

comptime COMPOSITE_WGSL = """
@group(0) @binding(0) var<uniform> frame : Frame;
@group(0) @binding(1) var src : texture_2d<f32>;
@group(0) @binding(2) var zbuf : texture_depth_2d;
@group(0) @binding(3) var sums : texture_3d<f32>;
@group(0) @binding(4) var lin : sampler;

fn view_z(uv : vec2<f32>) -> f32 {
  let d0 = vec2<i32>(textureDimensions(zbuf));
  let d = textureLoad(zbuf, clamp(vec2<i32>(uv * vec2<f32>(d0)), vec2<i32>(0), d0 - vec2<i32>(1)), 0);
  let n = frame.up.w;
  let f = frame.fwd.w;
  if frame.eye.w < 0.0 { return n + d * (f - n); }
  return f * n / (f - d * (f - n));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let sd = vec2<i32>(textureDimensions(src));
  let c = textureLoad(src, clamp(vec2<i32>(uv * vec2<f32>(sd)), vec2<i32>(0), sd - vec2<i32>(1)), 0).rgb;
  if frame.vol.x <= 0.0 { return c; }
  let z = min(view_z(uv), vol_far());
  // cell k holds the sum up to the far edge of slice k: slice coordinate s is read at texel s - 1
  let w = clamp((z_slice(z) - 0.5) / f32(FZ), 0.5 / f32(FZ), 1.0 - 0.5 / f32(FZ));
  let v = textureSampleLevel(sums, lin, vec3<f32>(uv, w), 0.0);
  return c * v.a + v.rgb;
}
"""


def _ubo_entry(binding: UInt32, vis: UInt64) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, vis, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _tex_entry(binding: UInt32, vis: UInt64, sample_type: UInt32, dim: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, vis, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), sample_type, dim, UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _store_entry(binding: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(2), VOLUME_FORMAT, UInt32(6)),  # write-only, 3D
    )


def _buf(binding: UInt32, h: BufferHandle, size: Int) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, h.raw, 0, UInt64(size), null_opaque(), null_opaque())


def _view(binding: UInt32, v: TextureView) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, null_opaque(), 0, UInt64(0), null_opaque(), v.handle().raw)


def volume_bytes() raises -> Int:
    """Bytes of the two froxel textures."""
    return 2 * texture_bytes(FROXELS_X, FROXELS_Y, FROXELS_Z, 1, VOLUME_FORMAT)


struct VolumetricFog(PostEffect):
    """The froxel fog of the file's header: two compute passes and one full-screen stage."""

    comptime NAME: StaticString = "volumetric_fog"
    comptime AFTER: StaticString = "froxel volumetric fog (Wronski 2014; Hillaire 2015), written from their descriptions"
    comptime STAGES: Int = 3
    comptime ON: Bool = True

    @staticmethod
    def sig() -> String:
        return "volumetric_fog"

    var inject: ComputePipeline
    var integrate: ComputePipeline
    var composite: RenderPipeline
    var inject_layout: BindGroupLayout
    var integrate_layout: BindGroupLayout
    var composite_layout: BindGroupLayout
    var ubo: Buffer
    var spare_lights: Buffer  # bound when the renderer gave no lights (a light rig of zeros: the default sun only)
    var spare_shadow: Buffer
    var sampler: Sampler
    var cells: Texture
    var cells_view: TextureView
    var sums: Texture
    var sums_view: TextureView
    var inject_group: Optional[BindGroup]
    var integrate_group: Optional[BindGroup]
    var composite_group: Optional[BindGroup]

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var common = String(FRAME_WGSL) + String(FROXEL_WGSL)
        var lit = String(SHADOW_UBO_WGSL) + String(POINT_LIGHTS_WGSL) + String(NO_LOCAL_SHADOW_WGSL) + String(NO_PROBES_WGSL) + String(NO_LIGHT_TEX_WGSL)
        var cs = WGPUShaderStage.COMPUTE.value
        var fs = WGPUShaderStage.FRAGMENT.value
        var e1: List[WGPUBindGroupLayoutEntry] = [
            _ubo_entry(UInt32(0), cs), _ubo_entry(UInt32(1), cs), _ubo_entry(UInt32(2), cs),
            _tex_entry(UInt32(3), cs, UInt32(4), UInt32(2)),  # depth, 2D
            _store_entry(UInt32(4)),
        ]
        self.inject_layout = device.create_bind_group_layout(e1)
        var s1 = device.create_shader_module_wgsl(common + lit + String(INJECT_WGSL), "vol_inject")
        self.inject = device.create_compute_pipeline(s1, "inject", device.create_pipeline_layout(self.inject_layout, "vol_inject"), "vol_inject")
        var e2: List[WGPUBindGroupLayoutEntry] = [
            _ubo_entry(UInt32(0), cs),
            _tex_entry(UInt32(1), cs, UInt32(3), UInt32(6)),  # unfilterable float, 3D
            _store_entry(UInt32(2)),
        ]
        self.integrate_layout = device.create_bind_group_layout(e2)
        var s2 = device.create_shader_module_wgsl(common + String(INTEGRATE_WGSL), "vol_integrate")
        self.integrate = device.create_compute_pipeline(s2, "integrate", device.create_pipeline_layout(self.integrate_layout, "vol_integrate"), "vol_integrate")
        var e3: List[WGPUBindGroupLayoutEntry] = [
            _ubo_entry(UInt32(0), fs),
            _tex_entry(UInt32(1), fs, UInt32(2), UInt32(2)),
            _tex_entry(UInt32(2), fs, UInt32(4), UInt32(2)),
            _tex_entry(UInt32(3), fs, UInt32(2), UInt32(6)),  # filterable float, 3D
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(4), fs, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        self.composite_layout = device.create_bind_group_layout(e3)
        var s3 = device.create_shader_module_wgsl(common + String(COMPOSITE_WGSL) + String(POST_MAIN_WGSL), "vol_composite")
        self.composite = device.create_render_pipeline(s3, "vs_main", "fs_main", color_format, device.create_pipeline_layout(self.composite_layout, "vol_composite"))
        self.ubo = device.create_buffer(UInt64(FRAME_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="vol_frame")
        self.spare_lights = device.create_buffer(UInt64(LIGHTS_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="vol_lights")
        self.spare_shadow = device.create_buffer(UInt64(SHADOW_UBO_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="vol_shadow")
        device.queue_write_data(self.spare_lights, UInt64(0), List[Float32](length=LIGHTS_BYTES // 4, fill=Float32(0)))
        device.queue_write_data(self.spare_shadow, UInt64(0), List[Float32](length=SHADOW_UBO_BYTES // 4, fill=Float32(0)))
        self.sampler = device.create_sampler(mag_filter=2, min_filter=2, label="vol_linear")
        var usage = WGPUTextureUsage.STORAGE_BINDING | WGPUTextureUsage.TEXTURE_BINDING
        self.cells = device.create_texture(UInt32(FROXELS_X), UInt32(FROXELS_Y), UInt32(FROXELS_Z), VOLUME_FORMAT, usage, dimension=3, label="vol_cells")
        self.cells_view = self.cells.create_view_default()
        self.sums = device.create_texture(UInt32(FROXELS_X), UInt32(FROXELS_Y), UInt32(FROXELS_Z), VOLUME_FORMAT, usage, dimension=3, label="vol_sums")
        self.sums_view = self.sums.create_view_default()
        self.inject_group = None
        self.integrate_group = None
        self.composite_group = None

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(device, color_format)

    def target_bytes(self) raises -> Int:
        return volume_bytes()

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        var lights = inp.lights if Int(inp.lights.raw) != 0 else self.spare_lights.handle()
        var shadow = inp.shadow_ubo if Int(inp.shadow_ubo.raw) != 0 else self.spare_shadow.handle()
        var g1: List[WGPUBindGroupEntry] = [
            _buf(UInt32(0), self.ubo.handle(), FRAME_BYTES),
            _buf(UInt32(1), lights, LIGHTS_BYTES),
            _buf(UInt32(2), shadow, SHADOW_UBO_BYTES),
            _view(UInt32(3), inp.shadow),
            _view(UInt32(4), self.cells_view),
        ]
        self.inject_group = device.create_bind_group(self.inject_layout, g1, "vol_inject")
        var g2: List[WGPUBindGroupEntry] = [
            _buf(UInt32(0), self.ubo.handle(), FRAME_BYTES),
            _view(UInt32(1), self.cells_view),
            _view(UInt32(2), self.sums_view),
        ]
        self.integrate_group = device.create_bind_group(self.integrate_layout, g2, "vol_integrate")
        var g3: List[WGPUBindGroupEntry] = [
            _buf(UInt32(0), self.ubo.handle(), FRAME_BYTES),
            _view(UInt32(1), inp.src),
            _view(UInt32(2), inp.depth),
            _view(UInt32(3), self.sums_view),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), self.sampler.handle().raw, null_opaque()),
        ]
        self.composite_group = device.create_bind_group(self.composite_layout, g3, "vol_composite")

    def update(self, device: Device, frame: List[Float32]) raises:
        device.queue_write_data(self.ubo, UInt64(0), frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        var cp = enc.begin_compute_pass("vol_inject")
        cp.set_pipeline(self.inject)
        cp.set_bind_group(UInt32(0), self.inject_group.value())
        cp.dispatch_workgroups(UInt32((FROXELS_X + 7) // 8), UInt32((FROXELS_Y + 7) // 8), UInt32(FROXELS_Z))
        cp^.end()
        var ip = enc.begin_compute_pass("vol_integrate")
        ip.set_pipeline(self.integrate)
        ip.set_bind_group(UInt32(0), self.integrate_group.value())
        ip.dispatch_workgroups(UInt32((FROXELS_X + 7) // 8), UInt32((FROXELS_Y + 7) // 8), UInt32(1))
        ip^.end()
        var rp = enc.begin_render_pass_clear(dst^, WGPUColor(0.0, 0.0, 0.0, 1.0), "vol_composite")
        rp.set_pipeline(self.composite)
        rp.set_bind_group(UInt32(0), self.composite_group.value())
        rp.draw(UInt32(3))
        rp^.end()


# ---------------------------------------------------------------------------------------------------------------------
# the same arithmetic on the CPU, for the tests


def hg_phase(c: Float64, g: Float64) -> Float64:
    var d = 1.0 + g * g - 2.0 * g * c
    return (1.0 - g * g) / (4.0 * 3.14159265 * d * d ** 0.5)


def uniform_fog(colour: Float64, sigma: Float64, scatter: Float64, dist: Float64) -> Float64:
    """A pixel of colour `colour` seen through uniform fog of extinction `sigma` that scatters `scatter` per metre over
    `dist` metres: colour * exp(-sigma d) + scatter / sigma * (1 - exp(-sigma d)). The integration's closed form."""
    var t = exp(-sigma * dist)
    return colour * t + scatter / sigma * (1.0 - t)


def froxel_slice_z(s: Float64, far: Float64) -> Float64:
    return FROXEL_NEAR * (far / FROXEL_NEAR) ** (s / Float64(FROXELS_Z))


def froxel_z_slice(z: Float64, far: Float64) -> Float64:
    return Float64(FROXELS_Z) * log(max(z, FROXEL_NEAR) / FROXEL_NEAR) / log(far / FROXEL_NEAR)
