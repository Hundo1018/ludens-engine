"""Post-processing as a compile-time list of stages, beside the pass list (app/render_pass.mojo).

`ArenaRendererOf[P, F]` draws its passes P into an offscreen colour and depth target when F is not `NoPost`, then runs
F over them into the frame. A stage is `Stage[S]` for a `Style` S: one full-screen fragment shader. `ThenPost[A, B]`
runs A into a texture of its own, then B from that texture into wherever the composite is pointed:

    struct Sepia(Style):
        comptime NAME: StaticString = "sepia"
        comptime WGSL: StaticString = "fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> { ... }"
    var r = ArenaRendererOf[DefaultPasses, ThenPost[Stage[Blur], Stage[Sepia]]](device, format, view)

What a style's `style(uv, px)` can read (POST_WGSL below): `src` (the previous stage's output; the scene for the first
stage), `scene` (always the scene's colour), the scene's depth, and the camera, so view depth, world position and a
normal from depth are available to every stage. uv is 0..1 with y down, px the pixel centre.

With `NoPost` the renderer's frame is the frame from before this module: `comptime if` leaves the direct path as it was.
"""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.structs import WGPUColor
from wgpu._ffi.types import WGPUTextureUsage
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.sampler import Sampler
from wgpu.texture import Texture, TextureView

comptime FRAME_FLOATS = 28  # res (4), camera (16), t (4), user (4)
comptime FRAME_BYTES = FRAME_FLOATS * 4

comptime POST_WGSL = """
struct Frame {
  res : vec4<f32>,    // width, height, 1 / width, 1 / height
  eye : vec4<f32>,    // xyz, w = sx
  right : vec4<f32>,  // xyz, w = sy
  up : vec4<f32>,     // xyz, w = near
  fwd : vec4<f32>,    // xyz, w = far
  t : vec4<f32>,      // time (s), frame number, seed, unused
  user : vec4<f32>,   // the host's four numbers (ArenaRendererOf.post_user)
};
@group(0) @binding(0) var<uniform> frame : Frame;
@group(0) @binding(1) var src : texture_2d<f32>;
@group(0) @binding(2) var scene : texture_2d<f32>;
@group(0) @binding(3) var zbuf : texture_depth_2d;
@group(0) @binding(4) var lin : sampler;

const SUN = vec3<f32>(0.3244, 0.8111, 0.4867);  // the passes' light direction, normalize(0.4, 1.0, 0.6)
const TAU = 6.2831853;

struct PostV { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32> };

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> PostV {
  var o : PostV;
  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = vec2<f32>(p.x, 1.0 - p.y);
  return o;
}

fn src_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(src, lin, uv, 0.0).rgb; }
fn scene_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(scene, lin, uv, 0.0).rgb; }
fn texel(uv : vec2<f32>) -> vec2<i32> {
  return clamp(vec2<i32>(uv * frame.res.xy), vec2<i32>(0), vec2<i32>(frame.res.xy) - vec2<i32>(1));
}
fn src_px(uv : vec2<f32>) -> vec3<f32> { return textureLoad(src, texel(uv), 0).rgb; }
// the uv of the centre of the `cell`-pixel block that holds px: a lower-resolution grid over the frame
fn cell_uv(px : vec2<f32>, cell : vec2<f32>) -> vec2<f32> { return (floor(px / cell) + 0.5) * cell * frame.res.zw; }
fn luma(c : vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.299, 0.587, 0.114)); }

// view depth in metres (distance along the camera's forward axis)
fn view_z(uv : vec2<f32>) -> f32 {
  let d = textureLoad(zbuf, texel(uv), 0);
  let n = frame.up.w;
  let f = frame.fwd.w;
  return f * n / (f - d * (f - n));
}
// 1 where nothing nearer than `far` metres was drawn (the sky sphere, the clear colour)
fn is_far(uv : vec2<f32>, far : f32) -> f32 { return step(far, view_z(uv)); }
fn world_at(uv : vec2<f32>) -> vec3<f32> {
  let z = view_z(uv);
  let nx = (uv.x * 2.0 - 1.0) * z / frame.eye.w;
  let ny = (1.0 - uv.y * 2.0) * z / frame.right.w;
  return frame.eye.xyz + frame.right.xyz * nx + frame.up.xyz * ny + frame.fwd.xyz * z;
}
// the surface normal from depth: the cross product of the nearer of the two one-pixel steps along each axis
fn normal_at(uv : vec2<f32>) -> vec3<f32> {
  let e = frame.res.zw;
  let c = world_at(uv);
  let l = world_at(uv - vec2<f32>(e.x, 0.0));
  let r = world_at(uv + vec2<f32>(e.x, 0.0));
  let u = world_at(uv - vec2<f32>(0.0, e.y));
  let d = world_at(uv + vec2<f32>(0.0, e.y));
  let dx = select(r - c, c - l, abs(dot(c - l, frame.fwd.xyz)) < abs(dot(r - c, frame.fwd.xyz)));
  let dy = select(d - c, c - u, abs(dot(c - u, frame.fwd.xyz)) < abs(dot(d - c, frame.fwd.xyz)));
  return normalize(cross(dx, dy));
}

fn hash21(p : vec2<f32>) -> f32 {
  var q = fract(vec3<f32>(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}
fn hash22(p : vec2<f32>) -> vec2<f32> {
  var q = fract(vec3<f32>(p.xyx) * vec3<f32>(0.1031, 0.1030, 0.0973));
  q += dot(q, q.yzx + 33.33);
  return fract((q.xx + q.yz) * q.zy);
}
fn vnoise(p : vec2<f32>) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
             mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}
fn fbm(p : vec2<f32>) -> f32 {
  var a = 0.5;
  var s = 0.0;
  var q = p;
  for (var i = 0; i < 4; i++) { s += a * vnoise(q); q = q * 2.03 + vec2<f32>(17.0, 9.0); a *= 0.5; }
  return s;
}
// the 4 x 4 ordered-dither threshold of a pixel, in (0, 1)
fn bayer4(px : vec2<f32>) -> f32 {
  let x = u32(px.x) & 3u;
  let y = u32(px.y) & 3u;
  let m = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
  return (m[y * 4u + x] + 0.5) / 16.0;
}
fn bayer8(px : vec2<f32>) -> f32 {
  return (bayer4(floor(px * 0.5)) * 16.0 - 0.5 + 4.0 * (bayer4(px) * 16.0 - 0.5) ) / 64.0 + 1.0 / 128.0;
}

// 0..1 where depth or the normal breaks within `w` pixels: the silhouettes and creases of the scene
fn edge(uv : vec2<f32>, w : f32) -> f32 {
  let e = frame.res.zw * w;
  let z = view_z(uv);
  let za = view_z(uv + vec2<f32>(e.x, e.y));
  let zb = view_z(uv - vec2<f32>(e.x, e.y));
  let zc = view_z(uv + vec2<f32>(e.x, -e.y));
  let zd = view_z(uv - vec2<f32>(e.x, -e.y));
  let dz = (abs(za + zb - 2.0 * z) + abs(zc + zd - 2.0 * z)) / z;
  let n = normal_at(uv);
  let dn = 2.0 - dot(n, normal_at(uv + vec2<f32>(e.x, 0.0))) - dot(n, normal_at(uv + vec2<f32>(0.0, e.y)));
  return clamp(max(smoothstep(0.02, 0.06, dz), smoothstep(0.25, 0.6, dn)), 0.0, 1.0);
}
// the Sobel gradient of the source's luminance, `w` pixels wide: xy the direction, z the magnitude
fn sobel(uv : vec2<f32>, w : f32) -> vec3<f32> {
  let e = frame.res.zw * w;
  let a = luma(src_at(uv + vec2<f32>(-e.x, -e.y)));
  let b = luma(src_at(uv + vec2<f32>(0.0, -e.y)));
  let c = luma(src_at(uv + vec2<f32>(e.x, -e.y)));
  let d = luma(src_at(uv + vec2<f32>(-e.x, 0.0)));
  let f = luma(src_at(uv + vec2<f32>(e.x, 0.0)));
  let g = luma(src_at(uv + vec2<f32>(-e.x, e.y)));
  let h = luma(src_at(uv + vec2<f32>(0.0, e.y)));
  let i = luma(src_at(uv + vec2<f32>(e.x, e.y)));
  let gx = (c + 2.0 * f + i) - (a + 2.0 * d + g);
  let gy = (g + 2.0 * h + i) - (a + 2.0 * b + c);
  return vec3<f32>(gx, gy, length(vec2<f32>(gx, gy)));
}
fn rgb2hsv(c : vec3<f32>) -> vec3<f32> {
  let p = mix(vec4<f32>(c.bg, -1.0, 2.0 / 3.0), vec4<f32>(c.gb, 0.0, -1.0 / 3.0), step(c.b, c.g));
  let q = mix(vec4<f32>(p.xyw, c.r), vec4<f32>(c.r, p.yzx), step(p.x, c.r));
  let d = q.x - min(q.w, q.y);
  return vec3<f32>(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}
fn hsv2rgb(c : vec3<f32>) -> vec3<f32> {
  let p = abs(fract(c.xxx + vec3<f32>(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
  return c.z * mix(vec3<f32>(1.0), clamp(p - 1.0, vec3<f32>(0.0), vec3<f32>(1.0)), c.y);
}
// the 3 x 3 box mean of the source, `w` pixels apart
fn blur9(uv : vec2<f32>, w : f32) -> vec3<f32> {
  let e = frame.res.zw * w;
  var s = vec3<f32>(0.0);
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) { s += src_at(uv + vec2<f32>(f32(i), f32(j)) * e); } }
  return s / 9.0;
}
fn vignette(uv : vec2<f32>, k : f32) -> f32 {
  let d = uv - 0.5;
  return clamp(1.0 - k * dot(d, d), 0.0, 1.0);
}

@fragment
fn fs_main(in : PostV) -> @location(0) vec4<f32> {
  return vec4<f32>(style(in.uv, in.pos.xy), 1.0);
}
"""


trait Style:
    comptime NAME: StaticString
    """A short name, for labels and file names."""
    comptime AFTER: StaticString
    """What the style imitates or pays homage to; "" for a style of this engine's own or a helper stage."""
    comptime WGSL: StaticString
    """WGSL declaring `fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32>` (and any helpers), after POST_WGSL."""


trait PostEffect(Movable, Deinitable):
    comptime NAME: StaticString
    """The name of the look: the last stage's."""
    comptime AFTER: StaticString
    comptime STAGES: Int
    comptime ON: Bool
    """False only for NoPost: the renderer then draws straight into the frame."""

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        ...

    def bind(
        mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32,
        src: TextureView, scene: TextureView, depth: TextureView,
    ) raises:
        """(Re)build what depends on the targets: called when they are created or resized."""
        ...

    def update(self, device: Device, frame: List[Float32]) raises:
        """Write this frame's uniform (FRAME_FLOATS floats) to every stage."""
        ...

    def record(self, enc: CommandEncoder, var dst: TextureView):
        """Run the stages; the last one draws into `dst`."""
        ...


struct NoPost(PostEffect):
    comptime NAME: StaticString = "plain"
    comptime AFTER: StaticString = ""
    comptime STAGES: Int = 0
    comptime ON: Bool = False

    def __init__(out self):
        pass

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self()

    def bind(
        mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32,
        src: TextureView, scene: TextureView, depth: TextureView,
    ) raises:
        pass

    def update(self, device: Device, frame: List[Float32]) raises:
        pass

    def record(self, enc: CommandEncoder, var dst: TextureView):
        pass


def _tex_entry(binding: UInt32, sample_type: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.FRAGMENT.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), sample_type, UInt32(2), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


struct Stage[S: Style](PostEffect):
    """One full-screen fragment shader, the Style S."""

    comptime NAME: StaticString = Self.S.NAME
    comptime AFTER: StaticString = Self.S.AFTER
    comptime STAGES: Int = 1
    comptime ON: Bool = True
    var pipeline: RenderPipeline
    var layout: BindGroupLayout
    var ubo: Buffer
    var sampler: Sampler
    var group: Optional[BindGroup]

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(POST_WGSL + String(Self.S.WGSL), String(Self.S.NAME))
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            _tex_entry(UInt32(1), UInt32(2)),  # float, filterable
            _tex_entry(UInt32(2), UInt32(2)),
            _tex_entry(UInt32(3), UInt32(4)),  # depth
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(4), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),  # filtering
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "post_layout")
        self.pipeline = device.create_render_pipeline(shader, "vs_main", "fs_main", color_format, pl)
        self.ubo = device.create_buffer(UInt64(FRAME_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="post_frame")
        self.sampler = device.create_sampler(mag_filter=2, min_filter=2, label="post_linear")
        self.group = None

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(device, color_format)

    def bind(
        mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32,
        src: TextureView, scene: TextureView, depth: TextureView,
    ) raises:
        var e: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(FRAME_BYTES), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), src.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), null_opaque(), scene.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), depth.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), self.sampler.handle().raw, null_opaque()),
        ]
        self.group = device.create_bind_group(self.layout, e, "post_group")

    def update(self, device: Device, frame: List[Float32]) raises:
        device.queue_write_data(self.ubo, UInt64(0), frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        var rp = enc.begin_render_pass_clear(dst^, WGPUColor(0.0, 0.0, 0.0, 1.0), "post")
        rp.set_pipeline(self.pipeline)
        rp.set_bind_group(UInt32(0), self.group.value())
        rp.draw(UInt32(3))
        rp^.end()


struct ThenPost[A: PostEffect, B: PostEffect](PostEffect):
    """A into a texture of this composite's own, then B reading that texture as `src`."""

    comptime NAME: StaticString = Self.B.NAME
    comptime AFTER: StaticString = Self.B.AFTER
    comptime STAGES: Int = Self.A.STAGES + Self.B.STAGES
    comptime ON: Bool = True
    var first: Self.A
    var second: Self.B
    var mid: Optional[Texture]
    var mid_view: Optional[TextureView]

    def __init__(out self, var first: Self.A, var second: Self.B):
        self.first = first^
        self.second = second^
        self.mid = None
        self.mid_view = None

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        var a = Self.A.create(device, color_format)
        var b = Self.B.create(device, color_format)
        return Self(a^, b^)

    def bind(
        mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32,
        src: TextureView, scene: TextureView, depth: TextureView,
    ) raises:
        self.mid_view = None
        self.mid = device.create_texture(
            width, height, 1, color_format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING, label="post_mid",
        )
        self.mid_view = self.mid.value().create_view_default()
        self.first.bind(device, color_format, width, height, src, scene, depth)
        self.second.bind(device, color_format, width, height, self.mid_view.value(), scene, depth)

    def update(self, device: Device, frame: List[Float32]) raises:
        self.first.update(device, frame)
        self.second.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.first.record(enc, self.mid_view.value().clone())
        self.second.record(enc, dst^)
