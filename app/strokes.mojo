"""Strokes: a post effect that draws geometry instead of a full-screen triangle (app/post.mojo PostEffect).

One quad per cell of a grid over the frame, per layer. The vertex stage asks the StrokeKind where the cell's stroke
goes, how big it is, which way it turns and what colour it carries (it can read the source there, once per stroke, not
once per pixel), and the fragment stage gives the quad its shape. The quads are blended over a canvas colour in a
shuffled order, so later strokes lie on top of earlier ones.

What this gives that a per-pixel filter cannot: each stroke is one object with one colour, a real edge and a place in
the paint order, however large it is and whatever it overlaps.

    struct Dots(StrokeKind):
        comptime NAME: StaticString = "dots"
        comptime AFTER: StaticString = "..."
        comptime CELL: Int = 6
        comptime WGSL: StaticString = '''
    fn place(cell : vec2<f32>, layer : u32) -> Stroke { ... }       // pixels
    fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> { ... }   // q in -1 .. 1 across the quad
    '''
    ArenaRendererOf[Passes, Strokes[Dots]]
"""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.structs import WGPUColor
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.sampler import Sampler
from wgpu.texture import TextureView
from app.post import PostEffect, PostInputs, POST_WGSL, FRAME_BYTES
from app.gpu_blend import pulled_pipeline, TOPOLOGY_TRIANGLES, BLEND_ALPHA

comptime STROKE_HEAD_WGSL = """
struct Stroke {
  centre : vec2<f32>,  // pixels
  half : vec2<f32>,    // half the quad's size, pixels
  angle : f32,         // radians, turning the quad's x axis
  color : vec4<f32>,
  seed : f32,
};
"""

comptime STROKE_MAIN_WGSL = """
struct SV {
  @builtin(position) pos : vec4<f32>,
  @location(0) q : vec2<f32>,
  @location(1) color : vec4<f32>,
  @location(2) seed : f32,
};
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> SV {
  let cols = u32(ceil(frame.res.x / STROKE_CELL)) + 1u;
  let rows = u32(ceil(frame.res.y / STROKE_CELL)) + 1u;
  let per = cols * rows;
  let layer = ii / per;
  let k = ((ii % per) * 7919u) % per;   // a shuffled paint order
  let s = place(vec2<f32>(f32(k % cols), f32(k / cols)), layer);
  let corner = vec2<f32>(f32(vi == 1u || vi == 4u || vi == 5u), f32(vi == 2u || vi == 3u || vi == 5u)) * 2.0 - 1.0;
  let c = cos(s.angle);
  let n = sin(s.angle);
  let o = corner * s.half;
  let p = s.centre + vec2<f32>(c * o.x - n * o.y, n * o.x + c * o.y);
  var out : SV;
  out.pos = vec4<f32>(p.x * frame.res.z * 2.0 - 1.0, 1.0 - p.y * frame.res.w * 2.0, 0.0, 1.0);
  out.q = corner;
  out.color = s.color;
  out.seed = s.seed;
  return out;
}
@fragment
fn fs_main(in : SV) -> @location(0) vec4<f32> {
  return shape(in.q, in.color, in.seed);
}
"""


trait StrokeKind:
    comptime NAME: StaticString
    comptime WHAT: StaticString
    """What the strokes are, in a few words, for listing a pipeline's structure."""
    comptime AFTER: StaticString
    comptime WGSL: StaticString
    """`fn place(cell : vec2<f32>, layer : u32) -> Stroke` and `fn shape(q, color, seed) -> vec4<f32>` (rgb and
    coverage), after POST_WGSL: the helpers of a Style are all available, in the vertex stage too."""
    comptime CELL: Int
    """The grid's spacing in pixels: one stroke per cell per layer."""
    comptime LAYERS: Int = 1
    comptime BLEND: Int = BLEND_ALPHA
    comptime CANVAS_R: Float64 = 1.0
    comptime CANVAS_G: Float64 = 1.0
    comptime CANVAS_B: Float64 = 1.0


def _tex(binding: UInt32, sample_type: UInt32) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), sample_type, UInt32(2), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _view(binding: UInt32, v: TextureView) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, null_opaque(), 0, UInt64(0), null_opaque(), v.handle().raw)


struct Strokes[K: StrokeKind](PostEffect):
    comptime NAME: StaticString = Self.K.NAME
    comptime AFTER: StaticString = Self.K.AFTER
    comptime STAGES: Int = 1
    comptime ON: Bool = True

    @staticmethod
    def sig() -> String:
        return "Strokes[" + String(Self.K.WHAT) + "]"

    var pipeline: RenderPipeline
    var layout: BindGroupLayout
    var ubo: Buffer
    var sampler: Sampler
    var group: Optional[BindGroup]
    var instances: Int

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var src = String(POST_WGSL) + String(STROKE_HEAD_WGSL) + "const STROKE_CELL : f32 = " + String(Self.K.CELL) + ".0;\n"
        var shader = device.create_shader_module_wgsl(src + String(Self.K.WGSL) + String(STROKE_MAIN_WGSL), String(Self.K.NAME))
        var both = WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), both, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            _tex(UInt32(1), UInt32(2)),
            _tex(UInt32(2), UInt32(2)),
            _tex(UInt32(3), UInt32(4)),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(4), both, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            _tex(UInt32(5), UInt32(2)),
            _tex(UInt32(6), UInt32(2)),
            _tex(UInt32(7), UInt32(2)),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "strokes_layout")
        self.pipeline = pulled_pipeline(device, shader, pl, color_format, 0, TOPOLOGY_TRIANGLES, Self.K.BLEND)
        self.ubo = device.create_buffer(UInt64(FRAME_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="strokes_frame")
        self.sampler = device.create_sampler(mag_filter=2, min_filter=2, label="strokes_linear")
        self.group = None
        self.instances = 0

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(device, color_format)

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        var e: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(FRAME_BYTES), null_opaque(), null_opaque()),
            _view(1, inp.src),
            _view(2, inp.scene),
            _view(3, inp.depth),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), self.sampler.handle().raw, null_opaque()),
            _view(5, inp.src2),
            _view(6, inp.aux),
            _view(7, inp.prev),
        ]
        self.group = device.create_bind_group(self.layout, e, "strokes_group")
        var cols = (Int(width) + Self.K.CELL - 1) // Self.K.CELL + 1
        var rows = (Int(height) + Self.K.CELL - 1) // Self.K.CELL + 1
        self.instances = cols * rows * Self.K.LAYERS

    def update(self, device: Device, frame: List[Float32]) raises:
        device.queue_write_data(self.ubo, UInt64(0), frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        var rp = enc.begin_render_pass_clear(dst^, WGPUColor(Self.K.CANVAS_R, Self.K.CANVAS_G, Self.K.CANVAS_B, 1.0), "strokes")
        rp.set_pipeline(self.pipeline)
        rp.set_bind_group(UInt32(0), self.group.value())
        rp.draw(UInt32(6), UInt32(self.instances))
        rp^.end()
