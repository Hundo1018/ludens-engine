"""Several views in one frame: split screen, a picture in a picture, an editor's four views.

    var split = SplitScreen(device, format, width, height, split_rects(2, width, height))
    for i in range(2):                                   # any renderer, any pipeline; one renderer can serve all
        r.begin(view_of_player[i])                       # a view with the rectangle's aspect: split.aspect(i)
        ...push items...
        r.draw(device, split.target(i), split.width(i), split.height(i), empty_hud)
    split.compose(device, frame, hud)                    # the views into their rectangles, then the HUD over all

Each view is drawn at its rectangle's size into a texture of its own, and compose copies the textures into the frame
texel for texel, so a view is the picture the renderer draws alone at that size. A pipeline that keeps the previous
frame (History) needs a renderer per view. At most four views; the frame outside every rectangle is black.
"""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout,
    WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,

)
from wgpu import null_opaque
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu import WGPUColor
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.texture import Texture, TextureView
from hud import Hud
from app.post import begin_load_pass

comptime MAX_VIEWS = 4

comptime COMPOSE_WGSL = """
struct Rects { n : vec4<f32>, r : array<vec4<f32>, 4> };   // n.x views; each rectangle x, y, width, height in pixels
@group(0) @binding(0) var<uniform> rects : Rects;
@group(0) @binding(1) var t0 : texture_2d<f32>;
@group(0) @binding(2) var t1 : texture_2d<f32>;
@group(0) @binding(3) var t2 : texture_2d<f32>;
@group(0) @binding(4) var t3 : texture_2d<f32>;
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}
fn inside(px : vec2<f32>, r : vec4<f32>) -> bool {
  return px.x >= r.x && px.y >= r.y && px.x < r.x + r.z && px.y < r.y + r.w;
}
@fragment
fn fs_main(@builtin(position) pos : vec4<f32>) -> @location(0) vec4<f32> {
  let px = floor(pos.xy);
  var c = vec4<f32>(0.0, 0.0, 0.0, 1.0);
  // later views lie over earlier ones (a picture in a picture)
  if rects.n.x > 0.5 && inside(px, rects.r[0]) { c = textureLoad(t0, vec2<i32>(px - rects.r[0].xy), 0); }
  if rects.n.x > 1.5 && inside(px, rects.r[1]) { c = textureLoad(t1, vec2<i32>(px - rects.r[1].xy), 0); }
  if rects.n.x > 2.5 && inside(px, rects.r[2]) { c = textureLoad(t2, vec2<i32>(px - rects.r[2].xy), 0); }
  if rects.n.x > 3.5 && inside(px, rects.r[3]) { c = textureLoad(t3, vec2<i32>(px - rects.r[3].xy), 0); }
  return vec4<f32>(c.rgb, 1.0);
}
"""


@fieldwise_init
struct Rect(Copyable, ImplicitlyCopyable, Movable):
    """A rectangle of the frame in pixels, from its top-left corner."""

    var x: Int
    var y: Int
    var w: Int
    var h: Int


def split_rects(views: Int, width: Int, height: Int) raises -> List[Rect]:
    """The usual split: 1 the whole frame; 2 left and right halves; 3 and 4 the quarters, row by row."""
    if views < 1 or views > MAX_VIEWS:
        raise Error("viewports: 1 to " + String(MAX_VIEWS) + " views")
    if views == 1:
        return [Rect(0, 0, width, height)]
    var hw = width // 2
    if views == 2:
        return [Rect(0, 0, hw, height), Rect(hw, 0, width - hw, height)]
    var hh = height // 2
    var out: List[Rect] = [Rect(0, 0, hw, hh), Rect(hw, 0, width - hw, hh), Rect(0, hh, hw, height - hh)]
    if views == 4:
        out.append(Rect(hw, hh, width - hw, height - hh))
    return out^


struct SplitScreen(Movable):
    var rects: List[Rect]
    var textures: List[Texture]
    var views: List[TextureView]
    var pipeline: RenderPipeline
    var group: BindGroup
    var ubo: Buffer
    var depth: Texture  # for the HUD's pass
    var depth_view: TextureView

    def __init__(out self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, var rects: List[Rect]) raises:
        if len(rects) < 1 or len(rects) > MAX_VIEWS:
            raise Error("viewports: 1 to " + String(MAX_VIEWS) + " views")
        for r in rects:
            if r.w < 1 or r.h < 1 or r.x < 0 or r.y < 0 or r.x + r.w > Int(width) or r.y + r.h > Int(height):
                raise Error("viewports: a rectangle must lie inside the frame and not be empty")
        self.textures = List[Texture]()
        self.views = List[TextureView]()
        var usage = WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.COPY_SRC
        for r in rects:
            var t = device.create_texture(UInt32(r.w), UInt32(r.h), 1, color_format, usage, label="split_view")
            self.views.append(t.create_view_default())
            self.textures.append(t^)
        var shader = device.create_shader_module_wgsl(COMPOSE_WGSL, "split_compose")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        for b in range(MAX_VIEWS):
            entries.append(WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1 + b), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(2), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ))
        var bgl = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(bgl, "split_layout")
        self.pipeline = device.create_render_pipeline(shader, "vs_main", "fs_main", color_format, pl)
        self.ubo = device.create_buffer(UInt64(80), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="split_rects")
        var data = List[Float32](length=20, fill=Float32(0))
        data[0] = Float32(len(rects))
        for i in range(len(rects)):
            data[4 + 4 * i] = Float32(rects[i].x)
            data[5 + 4 * i] = Float32(rects[i].y)
            data[6 + 4 * i] = Float32(rects[i].w)
            data[7 + 4 * i] = Float32(rects[i].h)
        device.queue_write_data(self.ubo, UInt64(0), data)
        var ge: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.ubo.handle().raw, 0, UInt64(80), null_opaque(), null_opaque()),
        ]
        for b in range(MAX_VIEWS):  # a slot past the last view holds the first view's texture; the shader does not read it
            ref v = self.views[b if b < len(rects) else 0]
            ge.append(WGPUBindGroupEntry(null_opaque(), UInt32(1 + b), null_opaque(), 0, UInt64(0), null_opaque(), v.handle().raw))
        self.group = device.create_bind_group(bgl, ge, "split_group")
        self.depth = device.create_texture(width, height, 1, WGPUTextureFormat.Depth32Float, WGPUTextureUsage.RENDER_ATTACHMENT, label="split_depth")
        self.depth_view = self.depth.create_view_default()
        self.rects = rects^

    def count(self) -> Int:
        return len(self.rects)

    def target(self, i: Int) -> WGPUTextureHandle:
        """The texture view i is drawn into (SceneRendererOf.draw's target)."""
        return self.textures[i].handle().raw

    def width(self, i: Int) -> UInt32:
        return UInt32(self.rects[i].w)

    def height(self, i: Int) -> UInt32:
        return UInt32(self.rects[i].h)

    def aspect(self, i: Int) -> Float64:
        return Float64(self.rects[i].w) / Float64(self.rects[i].h)

    def compose(self, device: Device, frame: WGPUTextureHandle, hud: Hud) raises:
        """Copy every view into its rectangle of `frame`, then draw the HUD over the whole frame."""
        hud.upload(device)
        var enc = device.create_command_encoder("split_compose")
        var rp = enc.begin_render_pass_clear(device.create_texture_view(frame), WGPUColor(0.0, 0.0, 0.0, 1.0), "split")
        rp.set_pipeline(self.pipeline)
        rp.set_bind_group(UInt32(0), self.group)
        rp.draw(UInt32(3))
        rp^.end()
        var hp = begin_load_pass(device, enc, device.create_texture_view(frame), self.depth_view)
        hud.record(hp)
        hp^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
