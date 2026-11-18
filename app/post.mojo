"""Post-processing as a compile-time graph of stages, beside the pass list (app/render_pass.mojo).

`ArenaRendererOf[P, F, A]` draws its passes P into an offscreen colour and depth target when F is not `NoPost`, then
runs F over them into the frame. The pieces of F:

    Stage[S]          one full-screen fragment shader, the `Style` S
    ThenPost[A, B]    A into a texture of the composite's own, then B reading it as `src`
    Join[A, B, C]     A and B side by side from the same input, then C reading A's output as `src` and B's as `src2`
    Scaled[A, D]      A at 1 / D of the size (a wide blur for the price of a small one; the next stage filters it up)
    History[A]        A, with the renderer keeping the finished frame for the next one to read as `prev`
    Sized[A, W, H]    A into a target of exactly W x H
    SceneSize[A, W, H]  the scene itself rasterised at W x H
    Stereo[A]         the scene drawn from two eyes; the second is `src2`
    Strokes[K]        instanced quads, one per cell of a grid, each placed, sized, turned and coloured from the
                      source in the vertex stage and blended over a canvas (app/strokes.mojo)

    struct Sepia(Style):
        comptime NAME: StaticString = "sepia"
        comptime AFTER: StaticString = "..."
        comptime WGSL: StaticString = "fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> { ... }"
    var r = ArenaRendererOf[DefaultPasses, Join[Stage[Sepia], Scaled[Stage[Blur], 4], Stage[Add]]](device, format, view)

What a style's `style(uv, px)` can read (POST_WGSL below): `src` and `src2`, `scene` (always the scene's colour),
`prev` (History), the scene's depth, `aux` (what the renderer's A drew: by convention the surface normals, see
`Aux` in app/render_pass.mojo), and the camera, so view depth and world position are available to every stage. uv is
0..1 with y down, px the pixel centre in the stage's own target. An input that the pipeline does not provide reads
the scene's colour.

With `NoPost` the renderer's frame is the frame from before this module: `comptime if` leaves the direct path as it was.
"""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.nulls import null_ptr
from wgpu._ffi.structs import (
    WGPUColor, WGPURenderPassColorAttachment, WGPURenderPassDepthStencilAttachment, WGPURenderPassDescriptor,
    WGPUPassTimestampWrites,
)
from wgpu._backend.wgpu_native.structs import WGPUStringView
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu.render_pass import FrameRenderPass
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
@group(0) @binding(5) var src2 : texture_2d<f32>;
@group(0) @binding(6) var aux : texture_2d<f32>;
@group(0) @binding(7) var prev : texture_2d<f32>;

const SUN = vec3<f32>(0.3244, 0.8111, 0.4867);  // the passes' light direction, normalize(0.4, 1.0, 0.6)
const TAU = 6.2831853;

fn src_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(src, lin, uv, 0.0).rgb; }
// the source's own texel under uv, unfiltered: the pixels of a low-resolution scene (SceneSize) or table (Sized)
fn src_texel(uv : vec2<f32>) -> vec3<f32> {
  let d = vec2<i32>(textureDimensions(src));
  return textureLoad(src, clamp(vec2<i32>(uv * vec2<f32>(d)), vec2<i32>(0), d - vec2<i32>(1)), 0).rgb;
}
fn src2_texel(uv : vec2<f32>) -> vec4<f32> {
  let d = vec2<i32>(textureDimensions(src2));
  return textureLoad(src2, clamp(vec2<i32>(uv * vec2<f32>(d)), vec2<i32>(0), d - vec2<i32>(1)), 0);
}
fn src_size() -> vec2<f32> { return vec2<f32>(textureDimensions(src)); }
fn scene_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(scene, lin, uv, 0.0).rgb; }
fn scene_texel(uv : vec2<f32>) -> vec3<f32> {
  let d = vec2<i32>(textureDimensions(scene));
  return textureLoad(scene, clamp(vec2<i32>(uv * vec2<f32>(d)), vec2<i32>(0), d - vec2<i32>(1)), 0).rgb;
}
fn scene_size() -> vec2<f32> { return vec2<f32>(textureDimensions(scene)); }
fn src2_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(src2, lin, uv, 0.0).rgb; }
fn prev_at(uv : vec2<f32>) -> vec3<f32> { return textureSampleLevel(prev, lin, uv, 0.0).rgb; }
// the texel of the scene's full-size targets (depth, aux) under uv, whatever this stage's own size
fn texel(uv : vec2<f32>) -> vec2<i32> {
  let d = vec2<i32>(textureDimensions(zbuf));
  return clamp(vec2<i32>(uv * vec2<f32>(d)), vec2<i32>(0), d - vec2<i32>(1));
}
// the aux target (app/render_pass.mojo Aux): a = 1 where a surface was drawn; with the normal convention, rgb = 0.5 + 0.5 n
fn aux_at(uv : vec2<f32>) -> vec4<f32> { return textureLoad(aux, texel(uv), 0); }
fn gnormal(uv : vec2<f32>) -> vec3<f32> { return normalize(aux_at(uv).xyz * 2.0 - 1.0); }
// the uv of the centre of the `cell`-pixel block that holds px: a lower-resolution grid over the frame
fn cell_uv(px : vec2<f32>, cell : vec2<f32>) -> vec2<f32> { return (floor(px / cell) + 0.5) * cell * frame.res.zw; }
// A screen of the given proportions shown as large as fits the frame, centred: the uv on that screen under px
// (outside 0 .. 1 beyond its border); `inside` tests it.
fn fit_uv(px : vec2<f32>, size : vec2<f32>) -> vec2<f32> {
  let k = min(frame.res.x / size.x, frame.res.y / size.y);
  return (px - (frame.res.xy - size * k) * 0.5) / (size * k);
}
fn inside(u : vec2<f32>) -> bool { return u.x >= 0.0 && u.x < 1.0 && u.y >= 0.0 && u.y < 1.0; }
fn luma(c : vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.299, 0.587, 0.114)); }

// view depth in metres (distance along the camera's forward axis)
fn view_z(uv : vec2<f32>) -> f32 {
  let d = textureLoad(zbuf, texel(uv), 0);
  let n = frame.up.w;
  let f = frame.fwd.w;
  if frame.eye.w < 0.0 { return n + d * (f - n); }  // a parallel projection
  return f * n / (f - d * (f - n));
}
// 1 where nothing nearer than `far` metres was drawn (the sky sphere, the clear colour)
fn is_far(uv : vec2<f32>, far : f32) -> f32 { return step(far, view_z(uv)); }
fn world_at(uv : vec2<f32>) -> vec3<f32> {
  let z = view_z(uv);
  var nx = (uv.x * 2.0 - 1.0) * z / frame.eye.w;
  var ny = (1.0 - uv.y * 2.0) * z / frame.right.w;
  if frame.eye.w < 0.0 {
    nx = (uv.x * 2.0 - 1.0) / -frame.eye.w;
    ny = (1.0 - uv.y * 2.0) / frame.right.w;
  }
  return frame.eye.xyz + frame.right.xyz * nx + frame.up.xyz * ny + frame.fwd.xyz * z;
}
// the surface normal from depth: the cross product of the nearer of the two one-pixel steps along each axis
fn normal_at(uv : vec2<f32>) -> vec3<f32> {
  let e = 1.0 / vec2<f32>(textureDimensions(zbuf));
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
  let e = w / vec2<f32>(textureDimensions(zbuf));
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
// `edge` with the aux target's normals in place of the ones rebuilt from depth: smooth on a curved surface
fn gedge(uv : vec2<f32>, w : f32) -> f32 {
  let e = w / vec2<f32>(textureDimensions(zbuf));
  let z = view_z(uv);
  let dz = (abs(view_z(uv + e) + view_z(uv - e) - 2.0 * z) + abs(view_z(uv + vec2<f32>(e.x, -e.y)) + view_z(uv - vec2<f32>(e.x, -e.y)) - 2.0 * z)) / z;
  let n = gnormal(uv);
  let dn = 2.0 - dot(n, gnormal(uv + vec2<f32>(e.x, 0.0))) - dot(n, gnormal(uv + vec2<f32>(0.0, e.y)));
  let da = abs(aux_at(uv).a - aux_at(uv + vec2<f32>(e.x, 0.0)).a) + abs(aux_at(uv).a - aux_at(uv + vec2<f32>(0.0, e.y)).a);
  return clamp(max(max(smoothstep(0.02, 0.06, dz), smoothstep(0.25, 0.6, dn)), da), 0.0, 1.0);
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

"""

# the full-screen triangle of a Stage and its fragment entry, after the style's own WGSL
comptime POST_MAIN_WGSL = """
struct PostV { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32> };

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> PostV {
  var o : PostV;
  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = vec2<f32>(p.x, 1.0 - p.y);
  return o;
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


struct PostInputs(Movable):
    """The textures a stage can read. Views are shared (reference counted), so a copy is cheap."""

    var src: TextureView
    var src2: TextureView
    var scene: TextureView
    var depth: TextureView
    var aux: TextureView
    var prev: TextureView

    def __init__(out self, src: TextureView, scene: TextureView, depth: TextureView, aux: TextureView, prev: TextureView):
        self.src = src.clone()
        self.src2 = scene.clone()
        self.scene = scene.clone()
        self.depth = depth.clone()
        self.aux = aux.clone()
        self.prev = prev.clone()

    def with_src(self, src: TextureView) -> Self:
        var o = Self(src, self.scene, self.depth, self.aux, self.prev)
        o.src2 = self.src2.clone()
        return o^

    def with_src2(self, src: TextureView, src2: TextureView) -> Self:
        var o = Self(src, self.scene, self.depth, self.aux, self.prev)
        o.src2 = src2.clone()
        return o^


trait PostEffect(Movable, Deinitable):
    comptime NAME: StaticString
    """The name of the look: the last stage's."""
    comptime AFTER: StaticString
    comptime STAGES: Int
    comptime ON: Bool
    """False only for NoPost: the renderer then draws straight into the frame."""
    comptime DIV: Int = 1
    """The effect's output is 1 / DIV of the size it is given (Scaled)."""
    comptime HISTORY: Bool = False
    """True if a stage reads `prev`: the renderer then keeps each finished frame for the next (History)."""
    comptime OUT_W: Int = 0
    comptime OUT_H: Int = 0
    """Not 0: the effect's output has exactly this size (Sized), whatever the frame's."""
    comptime SCENE_W: Int = 0
    comptime SCENE_H: Int = 0
    """Not 0: the renderer rasterises the scene (colour, depth, aux) at this size instead of the frame's (SceneSize)."""
    comptime ASPECT_W: Int = 0
    comptime ASPECT_H: Int = 0
    """Not 0: the proportions of the picture the scene is drawn for (SceneSize), for the host's camera; `scene_aspect`."""
    comptime VIEWS: Int = 1
    """2: the renderer draws the scene a second time from the other eye, into the top-level `src2` (Stereo)."""
    comptime PLAIN: Bool = False
    """True for no stage or one bare Stage: nothing about the pipeline's structure differs from the default."""

    @staticmethod
    def sig() -> String:
        """The effect's structure in one line, for listing a pipeline."""
        return "post"

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        ...

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        """(Re)build what depends on the targets: called when they are created or resized. width and height are the
        size of the target the effect's last stage draws into, times DIV."""
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

    comptime PLAIN: Bool = True

    @staticmethod
    def sig() -> String:
        return "none"
    def __init__(out self):
        pass

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self()

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
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


def _view_entry(binding: UInt32, v: TextureView) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, null_opaque(), 0, UInt64(0), null_opaque(), v.handle().raw)


def _target(device: Device, color_format: UInt32, width: UInt32, height: UInt32, div: Int, ow: Int, oh: Int) raises -> Texture:
    """The texture an effect draws into: ow x oh if it names a size, else 1 / div of width x height."""
    var w = UInt32(ow) if ow > 0 else max(width // UInt32(div), 1)
    var h = UInt32(oh) if oh > 0 else max(height // UInt32(div), 1)
    return device.create_texture(
        w, h, 1, color_format,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING, label="post_target",
    )


struct Stage[S: Style](PostEffect):
    """One full-screen fragment shader, the Style S."""

    comptime NAME: StaticString = Self.S.NAME
    comptime AFTER: StaticString = Self.S.AFTER
    comptime STAGES: Int = 1
    comptime ON: Bool = True
    comptime PLAIN: Bool = True

    @staticmethod
    def sig() -> String:
        return String(Self.S.NAME)
    var pipeline: RenderPipeline
    var layout: BindGroupLayout
    var ubo: Buffer
    var sampler: Sampler
    var group: Optional[BindGroup]

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(POST_WGSL + String(Self.S.WGSL) + POST_MAIN_WGSL, String(Self.S.NAME))
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
            _tex_entry(UInt32(5), UInt32(2)),
            _tex_entry(UInt32(6), UInt32(2)),
            _tex_entry(UInt32(7), UInt32(2)),
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

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        var e: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(FRAME_BYTES), null_opaque(), null_opaque()),
            _view_entry(1, inp.src),
            _view_entry(2, inp.scene),
            _view_entry(3, inp.depth),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), self.sampler.handle().raw, null_opaque()),
            _view_entry(5, inp.src2),
            _view_entry(6, inp.aux),
            _view_entry(7, inp.prev),
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
    comptime DIV: Int = Self.B.DIV
    comptime HISTORY: Bool = Self.A.HISTORY or Self.B.HISTORY
    comptime OUT_W: Int = Self.B.OUT_W
    comptime OUT_H: Int = Self.B.OUT_H
    comptime SCENE_W: Int = Self.A.SCENE_W if Self.A.SCENE_W > 0 else Self.B.SCENE_W
    comptime SCENE_H: Int = Self.A.SCENE_H if Self.A.SCENE_H > 0 else Self.B.SCENE_H
    comptime ASPECT_W: Int = Self.A.ASPECT_W if Self.A.ASPECT_W > 0 else Self.B.ASPECT_W
    comptime ASPECT_H: Int = Self.A.ASPECT_H if Self.A.ASPECT_H > 0 else Self.B.ASPECT_H
    comptime VIEWS: Int = max(Self.A.VIEWS, Self.B.VIEWS)

    @staticmethod
    def sig() -> String:
        return Self.A.sig() + " > " + Self.B.sig()
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

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.mid_view = None
        self.mid = _target(device, color_format, width, height, Self.A.DIV, Self.A.OUT_W, Self.A.OUT_H)
        self.mid_view = self.mid.value().create_view_default()
        self.first.bind(device, color_format, width, height, inp)
        self.second.bind(device, color_format, width, height, inp.with_src(self.mid_view.value()))

    def update(self, device: Device, frame: List[Float32]) raises:
        self.first.update(device, frame)
        self.second.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.first.record(enc, self.mid_view.value().clone())
        self.second.record(enc, dst^)


struct Join[A: PostEffect, B: PostEffect, C: PostEffect](PostEffect):
    """A and B, each from this composite's input into a texture of its own; then C, reading A's output as `src` and
    B's as `src2`. The shape of a glow (the picture and its blurred highlights), a difference, a mask."""

    comptime NAME: StaticString = Self.C.NAME
    comptime AFTER: StaticString = Self.C.AFTER
    comptime STAGES: Int = Self.A.STAGES + Self.B.STAGES + Self.C.STAGES
    comptime ON: Bool = True
    comptime DIV: Int = Self.C.DIV
    comptime HISTORY: Bool = Self.A.HISTORY or Self.B.HISTORY or Self.C.HISTORY
    comptime OUT_W: Int = Self.C.OUT_W
    comptime OUT_H: Int = Self.C.OUT_H
    comptime SCENE_W: Int = max(Self.A.SCENE_W, max(Self.B.SCENE_W, Self.C.SCENE_W))
    comptime SCENE_H: Int = max(Self.A.SCENE_H, max(Self.B.SCENE_H, Self.C.SCENE_H))
    comptime ASPECT_W: Int = max(Self.A.ASPECT_W, max(Self.B.ASPECT_W, Self.C.ASPECT_W))
    comptime ASPECT_H: Int = max(Self.A.ASPECT_H, max(Self.B.ASPECT_H, Self.C.ASPECT_H))
    comptime VIEWS: Int = max(Self.A.VIEWS, max(Self.B.VIEWS, Self.C.VIEWS))

    @staticmethod
    def sig() -> String:
        return "(" + Self.A.sig() + " | " + Self.B.sig() + ") > " + Self.C.sig()
    var a: Self.A
    var b: Self.B
    var c: Self.C
    var ta: Optional[Texture]
    var tb: Optional[Texture]
    var va: Optional[TextureView]
    var vb: Optional[TextureView]

    def __init__(out self, var a: Self.A, var b: Self.B, var c: Self.C):
        self.a = a^
        self.b = b^
        self.c = c^
        self.ta = None
        self.tb = None
        self.va = None
        self.vb = None

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        var a = Self.A.create(device, color_format)
        var b = Self.B.create(device, color_format)
        var c = Self.C.create(device, color_format)
        return Self(a^, b^, c^)

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.va = None
        self.vb = None
        self.ta = _target(device, color_format, width, height, Self.A.DIV, Self.A.OUT_W, Self.A.OUT_H)
        self.tb = _target(device, color_format, width, height, Self.B.DIV, Self.B.OUT_W, Self.B.OUT_H)
        self.va = self.ta.value().create_view_default()
        self.vb = self.tb.value().create_view_default()
        self.a.bind(device, color_format, width, height, inp)
        self.b.bind(device, color_format, width, height, inp)
        self.c.bind(device, color_format, width, height, inp.with_src2(self.va.value(), self.vb.value()))

    def update(self, device: Device, frame: List[Float32]) raises:
        self.a.update(device, frame)
        self.b.update(device, frame)
        self.c.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.a.record(enc, self.va.value().clone())
        self.b.record(enc, self.vb.value().clone())
        self.c.record(enc, dst^)


struct Scaled[A: PostEffect, D: Int](PostEffect):
    """A at 1 / D of the size: its stages see a frame that much smaller (Frame.res), and the composite around it makes
    the target that small. For an inner stage; the last stage of a renderer's effect draws the frame at full size."""

    comptime NAME: StaticString = Self.A.NAME
    comptime AFTER: StaticString = Self.A.AFTER
    comptime STAGES: Int = Self.A.STAGES
    comptime ON: Bool = True
    comptime DIV: Int = Self.A.DIV * Self.D
    comptime HISTORY: Bool = Self.A.HISTORY
    comptime SCENE_W: Int = Self.A.SCENE_W
    comptime SCENE_H: Int = Self.A.SCENE_H
    comptime ASPECT_W: Int = Self.A.ASPECT_W
    comptime ASPECT_H: Int = Self.A.ASPECT_H
    comptime VIEWS: Int = Self.A.VIEWS

    @staticmethod
    def sig() -> String:
        return "(" + Self.A.sig() + ") / " + String(Self.D)
    var inner: Self.A

    def __init__(out self, var inner: Self.A):
        self.inner = inner^

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(Self.A.create(device, color_format))

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.inner.bind(device, color_format, width // UInt32(Self.D), height // UInt32(Self.D), inp)

    def update(self, device: Device, frame: List[Float32]) raises:
        var f = frame.copy()
        f[0] = Float32(Int(frame[0]) // Self.D)
        f[1] = Float32(Int(frame[1]) // Self.D)
        f[2] = Float32(1.0) / f[0]
        f[3] = Float32(1.0) / f[1]
        self.inner.update(device, f)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.inner.record(enc, dst^)


struct History[A: PostEffect](PostEffect):
    """A, whose stages may read `prev`: the frame this effect finished last time (black before the first)."""

    comptime NAME: StaticString = Self.A.NAME
    comptime AFTER: StaticString = Self.A.AFTER
    comptime STAGES: Int = Self.A.STAGES
    comptime ON: Bool = True
    comptime DIV: Int = Self.A.DIV
    comptime HISTORY: Bool = True
    comptime OUT_W: Int = Self.A.OUT_W
    comptime OUT_H: Int = Self.A.OUT_H
    comptime SCENE_W: Int = Self.A.SCENE_W
    comptime SCENE_H: Int = Self.A.SCENE_H
    comptime ASPECT_W: Int = Self.A.ASPECT_W
    comptime ASPECT_H: Int = Self.A.ASPECT_H
    comptime VIEWS: Int = Self.A.VIEWS

    @staticmethod
    def sig() -> String:
        return "History[" + Self.A.sig() + "]"
    var inner: Self.A

    def __init__(out self, var inner: Self.A):
        self.inner = inner^

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(Self.A.create(device, color_format))

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.inner.bind(device, color_format, width, height, inp)

    def update(self, device: Device, frame: List[Float32]) raises:
        self.inner.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.inner.record(enc, dst^)


struct Sized[A: PostEffect, W: Int, H: Int](PostEffect):
    """A into a target of exactly W x H pixels: a table the next stage looks things up in (one texel per character
    cell, per tile, per panel)."""

    comptime NAME: StaticString = Self.A.NAME
    comptime AFTER: StaticString = Self.A.AFTER
    comptime STAGES: Int = Self.A.STAGES
    comptime ON: Bool = True
    comptime HISTORY: Bool = Self.A.HISTORY
    comptime OUT_W: Int = Self.W
    comptime OUT_H: Int = Self.H
    comptime SCENE_W: Int = Self.A.SCENE_W
    comptime SCENE_H: Int = Self.A.SCENE_H
    comptime ASPECT_W: Int = Self.A.ASPECT_W
    comptime ASPECT_H: Int = Self.A.ASPECT_H
    comptime VIEWS: Int = Self.A.VIEWS

    @staticmethod
    def sig() -> String:
        return "(" + Self.A.sig() + ") @ " + String(Self.W) + "x" + String(Self.H)
    var inner: Self.A

    def __init__(out self, var inner: Self.A):
        self.inner = inner^

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(Self.A.create(device, color_format))

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.inner.bind(device, color_format, UInt32(Self.W), UInt32(Self.H), inp)

    def update(self, device: Device, frame: List[Float32]) raises:
        var f = frame.copy()
        f[0] = Float32(Self.W)
        f[1] = Float32(Self.H)
        f[2] = Float32(1.0) / f[0]
        f[3] = Float32(1.0) / f[1]
        self.inner.update(device, f)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.inner.record(enc, dst^)


struct SceneSize[A: PostEffect, W: Int, H: Int, AW: Int = 0, AH: Int = 0](PostEffect):
    """A, with the scene rasterised at W x H: the triangles themselves are sampled on that grid (and the depth and aux
    targets with them), which no filter over a full-size frame gives back. AW : AH is the picture's proportions when
    the pixels are not square (0: W : H)."""

    comptime NAME: StaticString = Self.A.NAME
    comptime AFTER: StaticString = Self.A.AFTER
    comptime STAGES: Int = Self.A.STAGES
    comptime ON: Bool = True
    comptime DIV: Int = Self.A.DIV
    comptime HISTORY: Bool = Self.A.HISTORY
    comptime OUT_W: Int = Self.A.OUT_W
    comptime OUT_H: Int = Self.A.OUT_H
    comptime SCENE_W: Int = Self.W
    comptime SCENE_H: Int = Self.H
    comptime ASPECT_W: Int = Self.AW if Self.AW > 0 else Self.W
    comptime ASPECT_H: Int = Self.AH if Self.AH > 0 else Self.H
    comptime VIEWS: Int = Self.A.VIEWS

    @staticmethod
    def sig() -> String:
        return "scene " + String(Self.W) + "x" + String(Self.H) + ": " + Self.A.sig()
    var inner: Self.A

    def __init__(out self, var inner: Self.A):
        self.inner = inner^

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(Self.A.create(device, color_format))

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.inner.bind(device, color_format, width, height, inp)

    def update(self, device: Device, frame: List[Float32]) raises:
        self.inner.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.inner.record(enc, dst^)


struct Stereo[A: PostEffect](PostEffect):
    """A, with the scene drawn from two eyes (ArenaRendererOf.eye_sep apart, parallel): the left eye is `src` and
    `scene`, the right eye the top-level `src2`. Each eye sees round the near objects differently, which shifting one
    picture by its depth cannot show."""

    comptime NAME: StaticString = Self.A.NAME
    comptime AFTER: StaticString = Self.A.AFTER
    comptime STAGES: Int = Self.A.STAGES
    comptime ON: Bool = True
    comptime DIV: Int = Self.A.DIV
    comptime HISTORY: Bool = Self.A.HISTORY
    comptime OUT_W: Int = Self.A.OUT_W
    comptime OUT_H: Int = Self.A.OUT_H
    comptime SCENE_W: Int = Self.A.SCENE_W
    comptime SCENE_H: Int = Self.A.SCENE_H
    comptime ASPECT_W: Int = Self.A.ASPECT_W
    comptime ASPECT_H: Int = Self.A.ASPECT_H
    comptime VIEWS: Int = 2

    @staticmethod
    def sig() -> String:
        return "two eyes: " + Self.A.sig()
    var inner: Self.A

    def __init__(out self, var inner: Self.A):
        self.inner = inner^

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(Self.A.create(device, color_format))

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.inner.bind(device, color_format, width, height, inp)

    def update(self, device: Device, frame: List[Float32]) raises:
        self.inner.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.inner.record(enc, dst^)


struct Copy(Style):
    """The source unchanged: the renderer's blit of a kept frame (History) into the frame and into `prev`."""

    comptime NAME: StaticString = "copy"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = "fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> { return src_at(uv); }"


def scene_aspect[F: PostEffect](frame_aspect: Float64) -> Float64:
    """The width over height a host's camera should use with the effect F: the frame's, unless F draws the scene for
    a picture of its own proportions (SceneSize)."""
    comptime if F.ASPECT_W > 0:
        return Float64(F.ASPECT_W) / Float64(F.ASPECT_H)
    else:
        return frame_aspect


def begin_load_pass(device: Device, enc: CommandEncoder, var view: TextureView, depth_view: TextureView) -> FrameRenderPass:
    """A render pass over `view` that keeps what is there (load, not clear), with `depth_view` attached and kept too:
    for what is drawn on top of a finished frame, the HUD after the stages."""
    var color_att_p = raw_alloc[WGPURenderPassColorAttachment](1)
    color_att_p[unsafe_offset=0] = WGPURenderPassColorAttachment(
        null_opaque(), view.handle().raw, UInt32(0xFFFFFFFF), null_opaque(), UInt32(1), UInt32(1),
        WGPUColor(0.0, 0.0, 0.0, 1.0),
    )
    var depth_att_p = raw_alloc[WGPURenderPassDepthStencilAttachment](1)
    depth_att_p[unsafe_offset=0] = WGPURenderPassDepthStencilAttachment(
        null_opaque(), depth_view.handle().raw, UInt32(1), UInt32(1), Float32(1.0), UInt32(0),
        UInt32(0), UInt32(0), UInt32(0), UInt32(0),
    )
    var rp_desc_p = raw_alloc[WGPURenderPassDescriptor](1)
    rp_desc_p[unsafe_offset=0] = WGPURenderPassDescriptor(
        null_opaque(), WGPUStringView.null_view(), UInt(1), color_att_p, depth_att_p, null_opaque(),
        null_ptr[WGPUPassTimestampWrites](),
    )
    var result = device.lib()[].command_encoder_begin_render_pass(enc.handle().raw, rp_desc_p)
    color_att_p.unsafe_free()
    depth_att_p.unsafe_free()
    rp_desc_p.unsafe_free()
    return FrameRenderPass(device.lib(), result, view^)
