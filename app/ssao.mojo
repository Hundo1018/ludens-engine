"""Screen-space ambient occlusion (horizon-based, with a depth-aware blur and temporal accumulation).

    r.ao_intensity = 1.0     # 0 (the default): off, the colour is unchanged bit for bit and no texture is made
    r.ao_radius = 0.5        # metres around a point searched for occluders
    r.ao_temporal = 0.9      # the share of the previous frames kept, 0 .. 0.95; 0 computes every frame from scratch

Needs a `ShadowPass` in the pass list (it draws the frame's depth, as it does for the contact shadows) and an ambient
(`set_ambient` or `set_environment`): the occlusion darkens the ambient light only, not the sun, the point lights, the
specular reflection or the fixed 0.4 ambient of a scene with no environment. Not drawn with Stereo.

Per frame, three compute passes after the depth prepass (RenderResources.scene_depth, the scene's size):

1. `ssao_gen`: per pixel the view-space position and a normal rebuilt from depth (turned toward the camera). 6 screen
   directions, rotated per pixel by interleaved gradient noise and turned by the golden ratio each frame; along each,
   5 samples out to the radius projected to pixels (2 .. 64 px, with the sample distance growing as the square of its
   index, jittered per pixel). A sample at the point P + D adds the elevation of D over the tangent plane,
   `dot(D / |D|, N) - 0.15`, weighted `1 - |D|^2 / radius^2`; a direction keeps its largest value, and
   `ao = 1 - the mean over the directions / 0.85`. Sky pixels (depth 1) and samples on the sky occlude nothing.
2. `ssao_blur`: a 5 x 5 blur of that, each tap weighted by a Gaussian of the pixel distance and by
   `exp(-60 |z - z0| / z0)`, so it does not cross a depth edge. Then the temporal step: the pixel's world point is
   projected with the previous frame's camera, and the previous result there (kept with its view depth) is blended in by
   `ao_temporal` unless its depth differs from the point's by more than 3 %. The first frame after the size changes keeps
   none.
3. The contact-shadow compute (app/contact_shadows.mojo) writes `1 - ao_intensity * (1 - ao)` to the screen mask's G,
   which the mesh and skinned passes read (`screen_ao`, app/wgsl.mojo) and apply to the ambient term of `rig()`.

The textures are RGBA16Float at the scene's size: the raw result and two results for the temporal ping-pong, 24 bytes a
pixel on top of the 8 the depth and mask take.

Approximations: normals come from depth (a tessellated sphere shows its facets); only what the depth prepass drew
occludes (shadow casters that are meshes); a point seen only from a grazing angle is blurred over its neighbours; the
temporal step reprojects by the nearest pixel, so a moving camera keeps some ghosting at `ao_temporal` near 0.95.
"""
from game.camera_view import View
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUTextureUsage,
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
from wgpu.texture import Texture, TextureView
from app.gpu_mesh import cam_floats
from app.render_res import RenderResources

comptime SSAO_FLOATS = 40  # the uniform: the camera header (16), the previous frame's (16), size, tune
comptime SSAO_WGSL = """
struct Ao {
  cam_eye : vec4<f32>, cam_right : vec4<f32>, cam_up : vec4<f32>, cam_fwd : vec4<f32>,  // cam_floats
  prev_eye : vec4<f32>, prev_right : vec4<f32>, prev_up : vec4<f32>, prev_fwd : vec4<f32>,  // the previous frame's
  size : vec4<f32>,  // the target's width and height in pixels, the radius in metres
  tune : vec4<f32>,  // the temporal share, the frame number, 1 when the previous result is valid
};
@group(0) @binding(0) var<uniform> c : Ao;
@group(0) @binding(1) var zbuf : texture_depth_2d;

const DIRS = 6;
const STEPS = 5;
const BIAS = 0.15;
const TAU = 6.28318530718;

fn lin_z(d : f32) -> f32 {
  let n = c.cam_up.w;
  let f = c.cam_fwd.w;
  if c.cam_eye.w < 0.0 { return n + d * (f - n); }
  return f * n / (f - d * (f - n));
}
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
// the same for the previous frame's camera
fn to_prev_pixel(w : vec3<f32>) -> vec3<f32> {
  let d = w - c.prev_eye.xyz;
  let x = dot(d, c.prev_right.xyz);
  let y = dot(d, c.prev_up.xyz);
  let z = dot(d, c.prev_fwd.xyz);
  var nx = x * abs(c.prev_eye.w);
  var ny = y * c.prev_right.w;
  if c.prev_eye.w >= 0.0 {
    nx = nx / max(z, 1e-4);
    ny = ny / max(z, 1e-4);
  }
  return vec3<f32>((nx * 0.5 + 0.5) * c.size.x, (0.5 - ny * 0.5) * c.size.y, z);
}
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
fn dims() -> vec2<i32> { return vec2<i32>(i32(c.size.x), i32(c.size.y)); }
fn world_i(p : vec2<i32>) -> vec3<f32> {
  let q = clamp(p, vec2<i32>(0), dims() - vec2<i32>(1));
  return to_world(vec2<f32>(q) + vec2<f32>(0.5), lin_z(textureLoad(zbuf, q, 0)));
}
fn ign(p : vec2<f32>) -> f32 { return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715)))); }
"""

comptime SSAO_GEN_WGSL = """
@group(0) @binding(2) var raw : texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn ssao_gen(@builtin(global_invocation_id) id : vec3<u32>) {
  let d = dims();
  if i32(id.x) >= d.x || i32(id.y) >= d.y { return; }
  let p0 = vec2<i32>(id.xy);
  let d0 = textureLoad(zbuf, p0, 0);
  var ao = 1.0;
  if d0 < 1.0 {
    let P = world_i(p0);
    // the normal: the cross product of the nearer of the two one-pixel steps along each axis, turned toward the camera
    let l = world_i(p0 - vec2<i32>(1, 0));
    let r = world_i(p0 + vec2<i32>(1, 0));
    let u = world_i(p0 - vec2<i32>(0, 1));
    let b = world_i(p0 + vec2<i32>(0, 1));
    let dx = select(r - P, P - l, abs(dot(P - l, c.cam_fwd.xyz)) < abs(dot(r - P, c.cam_fwd.xyz)));
    let dy = select(b - P, P - u, abs(dot(P - u, c.cam_fwd.xyz)) < abs(dot(b - P, c.cam_fwd.xyz)));
    var N = normalize(cross(dx, dy));
    var V = c.cam_eye.xyz - P;
    if c.cam_eye.w < 0.0 { V = -c.cam_fwd.xyz; }
    if dot(N, V) < 0.0 { N = -N; }
    let centre = to_pixel(P).xy;
    let radius = c.size.z;
    let r_px = min(length(to_pixel(P + c.cam_right.xyz * radius).xy - centre), 64.0);
    if r_px >= 2.0 {
      let n1 = ign(vec2<f32>(id.xy));
      let n2 = ign(vec2<f32>(id.xy) + vec2<f32>(17.0, 59.0));
      let turn = (n1 + c.tune.y * 0.38196601) * TAU;
      var sum = 0.0;
      for (var k = 0; k < DIRS; k++) {
        let a = turn + f32(k) * TAU / f32(DIRS);
        let dir = vec2<f32>(cos(a), sin(a));
        var h = 0.0;
        for (var i = 0; i < STEPS; i++) {
          let t = (f32(i) + n2) / f32(STEPS);
          let q = vec2<i32>(floor(centre + dir * (r_px * t * t)));
          if q.x < 0 || q.y < 0 || q.x >= d.x || q.y >= d.y { continue; }
          let ds = textureLoad(zbuf, q, 0);
          if ds >= 1.0 { continue; }
          let D = to_world(vec2<f32>(q) + vec2<f32>(0.5), lin_z(ds)) - P;
          let len = length(D);
          if len < 1e-4 { continue; }
          let fall = clamp(1.0 - len * len / (radius * radius), 0.0, 1.0);
          h = max(h, (dot(D / len, N) - BIAS) * fall);
        }
        sum += h;
      }
      ao = clamp(1.0 - sum / f32(DIRS) / (1.0 - BIAS), 0.0, 1.0);
    }
  }
  textureStore(raw, p0, vec4<f32>(ao, 0.0, 0.0, 1.0));
}
"""

comptime SSAO_BLUR_WGSL = """
@group(0) @binding(2) var raw : texture_2d<f32>;
@group(0) @binding(3) var hist : texture_2d<f32>;
@group(0) @binding(4) var out : texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn ssao_blur(@builtin(global_invocation_id) id : vec3<u32>) {
  let d = dims();
  if i32(id.x) >= d.x || i32(id.y) >= d.y { return; }
  let p0 = vec2<i32>(id.xy);
  let d0 = textureLoad(zbuf, p0, 0);
  var ao = 1.0;
  var z0 = c.cam_fwd.w;
  if d0 < 1.0 {
    z0 = lin_z(d0);
    var acc = 0.0;
    var wsum = 0.0;
    for (var j = -2; j <= 2; j++) {
      for (var i = -2; i <= 2; i++) {
        let q = p0 + vec2<i32>(i, j);
        if q.x < 0 || q.y < 0 || q.x >= d.x || q.y >= d.y { continue; }
        let dq = textureLoad(zbuf, q, 0);
        if dq >= 1.0 { continue; }
        let w = exp(-f32(i * i + j * j) / 4.5) * exp(-60.0 * abs(lin_z(dq) - z0) / z0);
        acc += w * textureLoad(raw, q, 0).r;
        wsum += w;
      }
    }
    ao = acc / max(wsum, 1e-6);
    if c.tune.z > 0.5 && c.tune.x > 0.0 {
      let q = to_prev_pixel(to_world(vec2<f32>(id.xy) + vec2<f32>(0.5), z0));
      let hp = vec2<i32>(floor(q.xy));
      if q.z > 0.0 && hp.x >= 0 && hp.y >= 0 && hp.x < d.x && hp.y < d.y {
        let h = textureLoad(hist, hp, 0);
        if abs(h.g - q.z) < 0.03 * q.z { ao = mix(ao, h.r, c.tune.x); }
      }
    }
  }
  textureStore(out, p0, vec4<f32>(ao, z0, 0.0, 1.0));
}
"""


def _uniform_entry(binding: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _texture_entry(binding: UInt32, sample_type: UInt32) -> WGPUBindGroupLayoutEntry:
    """A sampled 2D texture: sample_type 4 is depth, 3 unfilterable float."""
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), sample_type, UInt32(2), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _store_entry(binding: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(2), WGPUTextureFormat.RGBA16Float, UInt32(2)),
    )


def _target(device: Device, w: Int, h: Int, label: String) raises -> Texture:
    return device.create_texture(
        UInt32(w), UInt32(h), UInt32(1), WGPUTextureFormat.RGBA16Float,
        WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.STORAGE_BINDING,
        dimension=2, mip_level_count=1, label=label,
    )


struct Ssao(Movable):
    """The compute passes of the file's header: scene depth in, the occlusion out (`current()`), read by the contact-shadow
    compute that writes the screen mask's G."""

    var gen_pipeline: ComputePipeline
    var gen_layout: BindGroupLayout
    var blur_pipeline: ComputePipeline
    var blur_layout: BindGroupLayout
    var ubo: Buffer
    var raw: Texture
    var raw_view: TextureView
    var hist_a: Texture
    var hist_a_view: TextureView
    var hist_b: Texture
    var hist_b_view: TextureView
    var gen_group: Optional[BindGroup]
    var blur_group_a: Optional[BindGroup]  # reads hist_a, writes hist_b
    var blur_group_b: Optional[BindGroup]  # reads hist_b, writes hist_a
    var w: Int  # the targets' size; 1 x 1 while the effect is off
    var h: Int
    var gen_key: Int  # the RenderResources.gen the groups were made for; -1 none
    var flip: Bool  # this frame writes hist_a (and reads hist_b)
    var valid: Bool  # the previous frame's result is in the history
    var frame: Int
    var prev_cam: List[Float32]

    def __init__(out self, device: Device) raises:
        self.gen_layout = device.create_bind_group_layout([_uniform_entry(UInt32(0)), _texture_entry(UInt32(1), UInt32(4)), _store_entry(UInt32(2))])
        self.blur_layout = device.create_bind_group_layout([
            _uniform_entry(UInt32(0)), _texture_entry(UInt32(1), UInt32(4)), _texture_entry(UInt32(2), UInt32(3)),
            _texture_entry(UInt32(3), UInt32(3)), _store_entry(UInt32(4)),
        ])
        var gen_shader = device.create_shader_module_wgsl(SSAO_WGSL + SSAO_GEN_WGSL, "ssao_gen")
        self.gen_pipeline = device.create_compute_pipeline(
            gen_shader, "ssao_gen", device.create_pipeline_layout(self.gen_layout, "ssao_gen"), "ssao_gen",
        )
        var blur_shader = device.create_shader_module_wgsl(SSAO_WGSL + SSAO_BLUR_WGSL, "ssao_blur")
        self.blur_pipeline = device.create_compute_pipeline(
            blur_shader, "ssao_blur", device.create_pipeline_layout(self.blur_layout, "ssao_blur"), "ssao_blur",
        )
        self.ubo = device.create_buffer(
            UInt64(SSAO_FLOATS * 4), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="ssao_ubo",
        )
        self.raw = _target(device, 1, 1, "ssao_raw")
        self.raw_view = self.raw.create_view_default()
        self.hist_a = _target(device, 1, 1, "ssao_a")
        self.hist_a_view = self.hist_a.create_view_default()
        self.hist_b = _target(device, 1, 1, "ssao_b")
        self.hist_b_view = self.hist_b.create_view_default()
        self.gen_group = None
        self.blur_group_a = None
        self.blur_group_b = None
        self.w = 1
        self.h = 1
        self.gen_key = -1
        self.flip = False
        self.valid = False
        self.frame = 0
        self.prev_cam = List[Float32]()

    def __init__(out self, *, deinit move: Self):
        self.gen_pipeline = move.gen_pipeline^
        self.gen_layout = move.gen_layout^
        self.blur_pipeline = move.blur_pipeline^
        self.blur_layout = move.blur_layout^
        self.ubo = move.ubo^
        self.raw = move.raw^
        self.raw_view = move.raw_view^
        self.hist_a = move.hist_a^
        self.hist_a_view = move.hist_a_view^
        self.hist_b = move.hist_b^
        self.hist_b_view = move.hist_b_view^
        self.gen_group = move.gen_group^
        self.blur_group_a = move.blur_group_a^
        self.blur_group_b = move.blur_group_b^
        self.w = move.w
        self.h = move.h
        self.gen_key = move.gen_key
        self.flip = move.flip
        self.valid = move.valid
        self.frame = move.frame
        self.prev_cam = move.prev_cam^

    def current(self) -> TextureView:
        """The occlusion the frame just computed (R; G its view depth): what the contact-shadow compute reads."""
        return (self.hist_a_view if self.flip else self.hist_b_view).clone()

    def bytes(self) -> Int:
        """Texture bytes held: three RGBA16Float targets."""
        return 3 * self.w * self.h * 8

    def prepare(mut self, device: Device, res: RenderResources, on: Bool) raises:
        """Make the targets the scene's size while the effect is on, 1 x 1 otherwise; the groups follow `res.gen`."""
        var want_w = res.screen_w if on else 1
        var want_h = res.screen_h if on else 1
        if want_w < 1 or want_h < 1:
            want_w = 1
            want_h = 1
        if want_w != self.w or want_h != self.h:
            self.w = want_w
            self.h = want_h
            self.raw = _target(device, want_w, want_h, "ssao_raw")
            self.raw_view = self.raw.create_view_default()
            self.hist_a = _target(device, want_w, want_h, "ssao_a")
            self.hist_a_view = self.hist_a.create_view_default()
            self.hist_b = _target(device, want_w, want_h, "ssao_b")
            self.hist_b_view = self.hist_b.create_view_default()
            self.gen_key = -1
            self.valid = False
        if not on or not res.scene_depth_view:
            return
        if self.gen_key != res.gen:
            var zv = res.scene_depth_view.value().handle().raw
            var u = WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(SSAO_FLOATS * 4), null_opaque(), null_opaque())
            self.gen_group = device.create_bind_group(self.gen_layout, [
                u, WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), zv),
                WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), self.raw_view.handle().raw),
            ], "ssao_gen")
            self.blur_group_a = device.create_bind_group(self.blur_layout, [
                u, WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), zv),
                WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), self.raw_view.handle().raw),
                WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), self.hist_a_view.handle().raw),
                WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), null_opaque(), self.hist_b_view.handle().raw),
            ], "ssao_blur_a")
            self.blur_group_b = device.create_bind_group(self.blur_layout, [
                u, WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), zv),
                WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), self.raw_view.handle().raw),
                WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), self.hist_b_view.handle().raw),
                WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), null_opaque(), self.hist_a_view.handle().raw),
            ], "ssao_blur_b")
            self.gen_key = res.gen
            self.valid = False

    def update(mut self, device: Device, v: View, res: RenderResources, radius: Float32, temporal: Float32) raises:
        """This frame's camera and tuning. Call once per frame, before `record`."""
        var cur = cam_floats(v)
        var u = cur.copy()
        if len(self.prev_cam) == 16:
            u.extend(self.prev_cam.copy())
        else:
            u.extend(cur.copy())
        u.append(Float32(res.screen_w)); u.append(Float32(res.screen_h)); u.append(radius); u.append(0.0)
        u.append(temporal); u.append(Float32(self.frame)); u.append(Float32(1.0) if self.valid else Float32(0.0)); u.append(0.0)
        device.queue_write_data(self.ubo, UInt64(0), u)
        self.prev_cam = cur^
        self.flip = not self.flip
        self.frame += 1

    def record(mut self, enc: CommandEncoder, res: RenderResources):
        """Generate, then blur and accumulate. After the depth prepass, before the contact-shadow compute."""
        if not self.gen_group:
            return
        var gx = UInt32((res.screen_w + 7) // 8)
        var gy = UInt32((res.screen_h + 7) // 8)
        var gp = enc.begin_compute_pass("ssao_gen")
        gp.set_pipeline(self.gen_pipeline)
        gp.set_bind_group(UInt32(0), self.gen_group.value())
        gp.dispatch_workgroups(gx, gy, UInt32(1))
        gp^.end()
        var bp = enc.begin_compute_pass("ssao_blur")
        bp.set_pipeline(self.blur_pipeline)
        # this frame reads the other history and writes the one `current()` names
        bp.set_bind_group(UInt32(0), (self.blur_group_b if self.flip else self.blur_group_a).value())
        bp.dispatch_workgroups(gx, gy, UInt32(1))
        bp^.end()
        self.valid = True
