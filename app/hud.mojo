"""The heads-up display: a `ui.draw.DrawList` of filled rectangles (panels and `ui.font` text), drawn as 2D quads on top
of the 3D scene in the same render pass. Positions are in pixels, origin top-left. Opaque: the pipeline helper has no
blend state, so panels are solid.

Buffer (f32): 4 header floats (width, height, 0, 0), then 6 per vertex: x y r g b a. Vertices come from `ui.batch.build_batch`.

Text (#116): once `set_font` has been given an `.lfont` file, every `DrawList.text` run is drawn from its SDF atlas by a second
pass after the rectangles (alpha blended, so text is always on top of the panels): a storage buffer of glyph vertices
(8 header floats: width, height, atlas width, atlas height, spread, 0 0 0; then 8 per vertex: x y u v r g b a) and the atlas
as a storage buffer of packed bytes, bilinear-filtered in the fragment shader (`GLYPH_WGSL`). Without a font, text runs draw nothing."""
from ui.batch import FLOATS_PER_VERTEX, build_batch, build_batch_font
from ui.sdf_font import GLYPH_VERT_FLOATS, SdfFont
from ui.draw import DrawList
from game.mode import GameMode
from app.gpu_blend import pulled_pipeline, BLEND_ALPHA, DEPTH_ALWAYS
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
from wgpu import WGPUTextureFormat
from wgpu.render_pass import FrameRenderPass

comptime MAX_VERTS = 65536
comptime MAX_GLYPH_VERTS = 49152  # 8192 glyphs
comptime GLYPH_HEADER = 8

comptime WGSL = """
@group(0) @binding(0) var<storage, read> data : array<f32>;

struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec4<f32> };

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> VOut {
  let b = 4u + vi * 6u;
  var out : VOut;
  out.pos = vec4<f32>(data[b] / data[0] * 2.0 - 1.0, 1.0 - data[b + 1u] / data[1] * 2.0, 0.0, 1.0);
  out.color = vec4<f32>(data[b + 2u], data[b + 3u], data[b + 4u], data[b + 5u]);
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  return in.color;
}
"""

comptime GLYPH_WGSL = """
@group(0) @binding(0) var<storage, read> data : array<f32>;
@group(0) @binding(1) var<storage, read> atlas : array<u32>;

struct VOut { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32>, @location(1) color : vec4<f32> };

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> VOut {
  let b = 8u + vi * 8u;
  var out : VOut;
  out.pos = vec4<f32>(data[b] / data[0] * 2.0 - 1.0, 1.0 - data[b + 1u] / data[1] * 2.0, 0.0, 1.0);
  out.uv = vec2<f32>(data[b + 2u], data[b + 3u]);
  out.color = vec4<f32>(data[b + 4u], data[b + 5u], data[b + 6u], data[b + 7u]);
  return out;
}

fn texel(x : i32, y : i32) -> f32 {
  let aw = i32(data[2]);
  let ah = i32(data[3]);
  let i = u32(clamp(y, 0, ah - 1) * aw + clamp(x, 0, aw - 1));
  return f32((atlas[i >> 2u] >> ((i & 3u) * 8u)) & 255u);
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  let fu = in.uv.x - 0.5;
  let fv = in.uv.y - 0.5;
  let ix = floor(fu);
  let iy = floor(fv);
  let tx = fu - ix;
  let ty = fv - iy;
  let x0 = i32(ix);
  let y0 = i32(iy);
  let s = (texel(x0, y0) * (1.0 - tx) + texel(x0 + 1, y0) * tx) * (1.0 - ty)
        + (texel(x0, y0 + 1) * (1.0 - tx) + texel(x0 + 1, y0 + 1) * tx) * ty;
  let dist = (s - 128.0) * data[4] / 128.0;
  let tpp = max(fwidth(in.uv.x), 0.0001);
  let cov = clamp(dist / tpp + 0.5, 0.0, 1.0);
  return vec4<f32>(in.color.rgb, in.color.a * cov);
}
"""


struct Hud(Movable):
    var pipeline: RenderPipeline
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var verts: Int
    var key: Int64  # the game's hud_key for the vertices held (-2 = none yet)
    var width: Float32
    var height: Float32
    var dirty: Bool  # staging changed since the last upload
    var color_format: UInt32
    var font: Optional[SdfFont]
    var glyph_pipeline: Optional[RenderPipeline]
    var glyph_buffer: Optional[Buffer]
    var atlas_buffer: Optional[Buffer]
    var glyph_group: Optional[BindGroup]
    var glyph_staging: List[Float32]
    var glyph_verts: Int

    def __init__(out self, device: Device, color_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(WGSL, "hud")
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
        var layout = device.create_pipeline_layout(bgl, "hud_layout")
        # Drawn in the scene pass, which has a depth attachment: same depth format, always passes, writes nothing.
        self.pipeline = device.create_render_pipeline(
            shader, "vs_main", "fs_main", color_format, layout,
            depth_format=WGPUTextureFormat.Depth32Float, depth_write=False, depth_compare=UInt32(8),
        )
        var bytes = UInt64((4 + MAX_VERTS * FLOATS_PER_VERTEX) * 4)
        self.buffer = device.create_buffer(bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="hud")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "hud_group")
        self.staging = List[Float32]()
        self.verts = 0
        self.key = -2
        self.width = 0
        self.height = 0
        self.dirty = False
        self.color_format = color_format
        self.font = None
        self.glyph_pipeline = None
        self.glyph_buffer = None
        self.atlas_buffer = None
        self.glyph_group = None
        self.glyph_staging = List[Float32]()
        self.glyph_verts = 0

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.buffer = move.buffer^
        self.group = move.group^
        self.staging = move.staging^
        self.verts = move.verts
        self.key = move.key
        self.width = move.width
        self.height = move.height
        self.dirty = move.dirty
        self.color_format = move.color_format
        self.font = move.font^
        self.glyph_pipeline = move.glyph_pipeline^
        self.glyph_buffer = move.glyph_buffer^
        self.atlas_buffer = move.atlas_buffer^
        self.glyph_group = move.glyph_group^
        self.glyph_staging = move.glyph_staging^
        self.glyph_verts = move.glyph_verts

    def set_font(mut self, device: Device, var bytes: List[UInt8]) raises:
        """Load an `.lfont` file (scripts/assets/convert_font.py): the atlas goes to the GPU once, text runs are drawn from it
        from the next `set`. Raises if the file does not parse."""
        var font = SdfFont(bytes^)
        var n = font.atlas_w * font.atlas_h
        var atlas = List[UInt8](length=(n + 3) // 4 * 4, fill=0)
        for i in range(n):
            atlas[i] = font.data[font.atlas_off + i]
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "hud_glyph_layout")
        var shader = device.create_shader_module_wgsl(GLYPH_WGSL, "hud_glyph")
        self.glyph_pipeline = pulled_pipeline(
            device, shader, layout, self.color_format, UInt32(WGPUTextureFormat.Depth32Float), blend=BLEND_ALPHA,
            depth_write=False, depth_compare=DEPTH_ALWAYS,
        )
        var gbytes = UInt64((GLYPH_HEADER + MAX_GLYPH_VERTS * GLYPH_VERT_FLOATS) * 4)
        self.glyph_buffer = device.create_buffer(gbytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="hud_glyphs")
        self.atlas_buffer = device.create_buffer(UInt64(len(atlas)), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="hud_atlas")
        device.queue_write_data(self.atlas_buffer.value(), UInt64(0), atlas)
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.glyph_buffer.value().handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, self.atlas_buffer.value().handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.glyph_group = device.create_bind_group(bgl, bg_entries, "hud_glyph_group")
        self.font = font^
        self.key = -2  # rebuild the next frame: text runs now have glyphs

    def set(mut self, list: DrawList, width: Float32, height: Float32):
        """Take this frame's draw list; the vertices are uploaded by `upload`."""
        self.key = -1
        self.width = width
        self.height = height
        self.dirty = True
        var b = build_batch_font(list, self.font.value()) if self.font else build_batch(list)
        self.staging.clear()
        self.staging.append(width)
        self.staging.append(height)
        self.staging.append(0.0)
        self.staging.append(0.0)
        self.verts = min(b.vertex_count(), MAX_VERTS)
        for i in range(self.verts * FLOATS_PER_VERTEX):
            self.staging.append(b.verts[i])
        self.glyph_staging.clear()
        self.glyph_verts = 0
        if self.font:
            ref f = self.font.value()
            self.glyph_verts = min(len(b.glyph_verts) // GLYPH_VERT_FLOATS, MAX_GLYPH_VERTS)
            self.glyph_staging.append(width)
            self.glyph_staging.append(height)
            self.glyph_staging.append(Float32(f.atlas_w))
            self.glyph_staging.append(Float32(f.atlas_h))
            self.glyph_staging.append(f.m.spread)
            self.glyph_staging.append(0.0)
            self.glyph_staging.append(0.0)
            self.glyph_staging.append(0.0)
            for i in range(self.glyph_verts * GLYPH_VERT_FLOATS):
                self.glyph_staging.append(b.glyph_verts[i])

    def upload(self, device: Device) raises:
        """Write the vertices to the GPU buffer when they changed since the last `uploaded` (the buffer keeps them)."""
        if self.dirty and len(self.staging) > 0:
            device.queue_write_data(self.buffer, UInt64(0), self.staging)
        if self.dirty and self.glyph_buffer and len(self.glyph_staging) > 0:
            device.queue_write_data(self.glyph_buffer.value(), UInt64(0), self.glyph_staging)

    def draws(self) -> Int:
        """Draw calls `record` issues."""
        return (1 if self.verts > 0 else 0) + (1 if self.glyph_verts > 0 and self.glyph_pipeline else 0)

    def triangles(self) -> Int:
        return self.verts // 3 + (self.glyph_verts // 3 if self.glyph_pipeline else 0)

    def uploaded(mut self):
        """The host calls this after the frame that uploaded the vertices was drawn."""
        self.dirty = False

    def record(self, rpass: FrameRenderPass):
        if self.verts > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.draw(UInt32(self.verts), UInt32(1), UInt32(0), UInt32(0))
        if self.glyph_verts > 0 and self.glyph_pipeline:
            rpass.set_pipeline(self.glyph_pipeline.value())
            rpass.set_bind_group(UInt32(0), self.glyph_group.value())
            rpass.draw(UInt32(self.glyph_verts), UInt32(1), UInt32(0), UInt32(0))


def refresh_hud[M: GameMode](mut hud: Hud, m: M, width: Float32, height: Float32, frame_ms: Float32) raises:
    """Rebuild the HUD only when the game's `hud_key` or the size changed (a key < 0 always rebuilds). The HUD was the
    largest CPU segment of the default frame (about 0.18 ms of 0.32 ms, `pixi run frame-budget`) while drawing the
    same thing frame after frame."""
    var key = m.hud_key(width, height)
    if key >= 0 and key == hud.key and width == hud.width and height == hud.height:
        return
    hud.set(m.hud(width, height, frame_ms), width, height)
    hud.key = key
