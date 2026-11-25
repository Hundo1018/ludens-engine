"""Contact shadows: the sun's shadow over a short distance, by marching the depth buffer toward the sun.

The sun's shadow map (cascades or a fixed box) has a texel of several centimetres at best, so an object resting on the
floor shows a gap of light where it touches. This pass finds that shadow in screen space instead:

1. the frame's meshes (static and skinned, the shadow pass's casters) are drawn once from the camera into
   `RenderResources.scene_depth`, a single-sample Depth32Float of the scene's size (ShadowPass.record_view_depth);
2. a compute pass reconstructs each pixel's world position from that depth and marches `steps` samples toward the sun
   over `distance` metres. A sample that lies behind the stored depth by more than a bias and less than `thickness` is
   an occluder; the pixel's mask R is then `1 - strength`, faded out over the last third of the ray;
3. the mesh and skinned passes multiply the sun's shadow factor by R (`contact_shadow` in app/wgsl.mojo).

`RenderResources.screen_mask` is RGBA8Unorm: R the sun's contact shadow (1 lit), G the screen-space ambient
occlusion (1 open; app/ssao.mojo's result, 1 while that is off), B and A 1. It is the scene's size while any user needs it
(`RenderResources.screen_users`: bit 0 contact shadows, bit 1 ambient occlusion) and 1 x 1 white otherwise, so a frame
with the effect off costs no texture memory and its colour is unchanged bit for bit.

What it does not see: anything the depth buffer does not hold (a ray that leaves the screen, a caster off screen, a
primitive that is not a mesh: the sun's shadow does not include those either), and vertex hooks of a material
(wind, waves) that move a vertex in the colour pass only. Not drawn with stereo (Stereo draws two eyes).
"""
from game.camera_view import View
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUTextureFormat,
)
from wgpu import null_opaque
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu.pipeline import ComputePipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.texture import TextureView
from app.gpu_mesh import cam_floats
from app.render_res import RenderResources

comptime CONTACT_FLOATS = 28  # the uniform: the camera header (16), to_sun, size, tune
comptime CONTACT_WGSL = """
struct Contact {
  cam_eye : vec4<f32>, cam_right : vec4<f32>, cam_up : vec4<f32>, cam_fwd : vec4<f32>,  // cam_floats
  to_sun : vec4<f32>,  // xyz: unit vector toward the sun
  size : vec4<f32>,    // the target's width and height in pixels, the sample count, the ray's length in metres
  tune : vec4<f32>,    // the thickness in metres, the strength 0 .. 1, 1 when contact shadows are on, the ambient occlusion's intensity (0: off)
};
@group(0) @binding(0) var<uniform> c : Contact;
@group(0) @binding(1) var zbuf : texture_depth_2d;
@group(0) @binding(2) var mask : texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(3) var ao : texture_2d<f32>;  // app/ssao.mojo's result (R); not read unless tune.w > 0

// the view depth of a stored NDC depth (the inverse of app/wgsl.mojo cam_clip's z)
fn lin_z(d : f32) -> f32 {
  let n = c.cam_up.w;
  let f = c.cam_fwd.w;
  if c.cam_eye.w < 0.0 { return n + d * (f - n); }
  return f * n / (f - d * (f - n));
}
// a world point's pixel (xy, in the target's pixels) and view depth (z)
fn to_pixel(w : vec3<f32>) -> vec3<f32> {
  let d = w - c.cam_eye.xyz;
  let x = dot(d, c.cam_right.xyz);
  let y = dot(d, c.cam_up.xyz);
  let z = dot(d, c.cam_fwd.xyz);
  var nx = x * abs(c.cam_eye.w);
  var ny = y * c.cam_right.w;
  if c.cam_eye.w >= 0.0 {
    nx = nx / max(z, 1e-4);
    ny = ny / max(z, 1e-4);
  }
  return vec3<f32>((nx * 0.5 + 0.5) * c.size.x, (0.5 - ny * 0.5) * c.size.y, z);
}
// the world point at pixel position px (the pixel's centre) and view depth z
fn to_world(px : vec2<f32>, z : f32) -> vec3<f32> {
  let nx = px.x / c.size.x * 2.0 - 1.0;
  let ny = 1.0 - px.y / c.size.y * 2.0;
  var x = nx / abs(c.cam_eye.w);
  var y = ny / c.cam_right.w;
  if c.cam_eye.w >= 0.0 {
    x = x * z;
    y = y * z;
  }
  return c.cam_eye.xyz + c.cam_right.xyz * x + c.cam_up.xyz * y + c.cam_fwd.xyz * z;
}

@compute @workgroup_size(8, 8, 1)
fn contact(@builtin(global_invocation_id) id : vec3<u32>) {
  let dims = vec2<i32>(i32(c.size.x), i32(c.size.y));
  if i32(id.x) >= dims.x || i32(id.y) >= dims.y { return; }
  let p0 = vec2<i32>(id.xy);
  let d0 = textureLoad(zbuf, p0, 0);
  var vis = 1.0;
  if d0 < 1.0 && c.tune.z > 0.5 {
    let z0 = lin_z(d0);
    let w0 = to_world(vec2<f32>(id.xy) + vec2<f32>(0.5), z0);
    let steps = max(u32(c.size.z), 1u);
    let reach = c.size.w;
    let bias = 0.01 + 0.003 * z0;
    // interleaved gradient noise: each pixel starts its ray at its own offset, so the fixed steps do not band
    let jitter = fract(52.9829189 * fract(dot(vec2<f32>(id.xy), vec2<f32>(0.06711056, 0.00583715))));
    for (var i = 0u; i < steps; i++) {
      let u = (f32(i) + 0.25 + 0.75 * jitter) / f32(steps);
      let q = to_pixel(w0 + c.to_sun.xyz * (reach * u));
      if q.z < c.cam_up.w { break; }
      let px = vec2<i32>(floor(q.xy));
      if px.x < 0 || px.y < 0 || px.x >= dims.x || px.y >= dims.y { break; }
      let ds = textureLoad(zbuf, px, 0);
      if ds >= 1.0 { continue; }
      let delta = q.z - lin_z(ds);
      if delta > bias && delta < c.tune.x {
        vis = 1.0 - c.tune.y * (1.0 - smoothstep(0.66, 1.0, u));
        break;
      }
    }
  }
  var amb = 1.0;
  if c.tune.w > 0.0 && d0 < 1.0 { amb = 1.0 - c.tune.w * (1.0 - textureLoad(ao, p0, 0).r); }
  textureStore(mask, p0, vec4<f32>(vis, amb, 1.0, 1.0));
}
"""


def camera_vp(v: View) -> List[Float32]:
    """The scene camera's view-projection as 16 floats, column-major: the linear map `cam_clip` (app/wgsl.mojo) computes,
    so the shadow pass's casters can be drawn from the camera (clip z in [0, 1] as the scene's depth buffer holds it)."""
    var ex = Float64(v.eye[0])
    var ey = Float64(v.eye[1])
    var ez = Float64(v.eye[2])
    var rows = List[Float64]()  # four rows of (a, b, c, d): clip_k = a x + b y + c z + d
    var sx = Float64(v.sx)
    var sy = Float64(v.sy)
    var n = Float64(v.near)
    var f = Float64(v.far)
    # x, y: sx * right . (p - eye), sy * up . (p - eye)
    for k in range(3):
        rows.append(sx * Float64(v.right[k]))
    rows.append(-sx * (Float64(v.right[0]) * ex + Float64(v.right[1]) * ey + Float64(v.right[2]) * ez))
    for k in range(3):
        rows.append(sy * Float64(v.up[k]))
    rows.append(-sy * (Float64(v.up[0]) * ex + Float64(v.up[1]) * ey + Float64(v.up[2]) * ez))
    var fe = Float64(v.fwd[0]) * ex + Float64(v.fwd[1]) * ey + Float64(v.fwd[2]) * ez
    if v.ortho:  # z = (depth - near) / (far - near), w = 1
        for k in range(3):
            rows.append(Float64(v.fwd[k]) / (f - n))
        rows.append((-fe - n) / (f - n))
        rows.append(0.0); rows.append(0.0); rows.append(0.0); rows.append(1.0)
    else:  # z = far (depth - near) / (far - near), w = depth
        for k in range(3):
            rows.append(f * Float64(v.fwd[k]) / (f - n))
        rows.append(f * (-fe - n) / (f - n))
        for k in range(3):
            rows.append(Float64(v.fwd[k]))
        rows.append(-fe)
    var m = List[Float32](length=16, fill=Float32(0))
    for r in range(4):
        for c in range(4):
            m[4 * c + r] = Float32(rows[4 * r + c])
    return m^


def _store_entry(binding: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(2), WGPUTextureFormat.RGBA8Unorm, UInt32(2)),  # write-only, 2D
    )


struct ContactShadows(Movable):
    """The compute pass of the file's header: scene depth in, RenderResources.screen_mask out."""

    var pipeline: ComputePipeline
    var layout: BindGroupLayout
    var ubo: Buffer
    var group: Optional[BindGroup]
    var gen: Int  # the RenderResources.gen the group was made for; -1 none
    var ao_key: Int

    def __init__(out self, device: Device) raises:
        var cs = WGPUShaderStage.COMPUTE.value
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), cs, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), cs, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),  # depth, 2D
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            _store_entry(UInt32(2)),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(3), cs, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(3), UInt32(2), UInt32(0)),  # unfilterable float, 2D
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var shader = device.create_shader_module_wgsl(CONTACT_WGSL, "contact_shadows")
        self.pipeline = device.create_compute_pipeline(
            shader, "contact", device.create_pipeline_layout(self.layout, "contact_shadows"), "contact_shadows",
        )
        self.ubo = device.create_buffer(
            UInt64(CONTACT_FLOATS * 4), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="contact_ubo",
        )
        self.group = None
        self.gen = -1
        self.ao_key = -1

    def bind(mut self, device: Device, res: RenderResources, ao: TextureView, ao_key: Int) raises:
        """The group over the renderer's scene depth and mask and the occlusion `ao` (app/ssao.mojo), made again when
        either is (RenderResources.gen) or `ao_key` changes (the occlusion's ping-pong)."""
        if not res.scene_depth_view or (self.gen == res.gen and self.ao_key == ao_key):
            return
        var g: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(CONTACT_FLOATS * 4), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), res.scene_depth_view.value().handle().raw),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), res.screen_mask_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), ao.handle().raw),
        ]
        self.group = device.create_bind_group(self.layout, g, "contact_shadows")
        self.gen = res.gen
        self.ao_key = ao_key

    def update(self, device: Device, v: View, to_sun: List[Float32], res: RenderResources, ao: Float32 = 0.0) raises:
        """This frame's camera, sun direction and tuning; `ao` is the ambient occlusion's intensity (0: off)."""
        var u = cam_floats(v)
        var l = Float32(0.0)
        for k in range(3):
            l += to_sun[k] * to_sun[k]
        l = l ** Float32(0.5)
        for k in range(3):
            u.append(to_sun[k] / l if l > Float32(1e-9) else Float32(0.0))
        u.append(0.0)
        u.append(Float32(res.screen_w)); u.append(Float32(res.screen_h))
        u.append(Float32(res.contact_steps)); u.append(Float32(res.contact_distance))
        u.append(Float32(res.contact_thickness)); u.append(Float32(res.contact_strength))
        u.append(Float32(1.0) if res.contact_on else Float32(0.0)); u.append(ao)
        device.queue_write_data(self.ubo, UInt64(0), u)

    def record(self, enc: CommandEncoder, res: RenderResources):
        """Fill the mask. After the depth prepass, before the colour pass."""
        if not self.group:
            return
        var cp = enc.begin_compute_pass("contact_shadows")
        cp.set_pipeline(self.pipeline)
        cp.set_bind_group(UInt32(0), self.group.value())
        cp.dispatch_workgroups(UInt32((res.screen_w + 7) // 8), UInt32((res.screen_h + 7) // 8), UInt32(1))
        cp^.end()
