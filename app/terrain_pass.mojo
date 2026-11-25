"""The terrain (#140) as a RenderPass: the height grid of `game/terrain.mojo` uploaded once, chunks drawn by vertex
pulling at the level their distance picks, stitched on the edges so no crack opens, textured from a splat map.

    comptime MyPasses = Then[DefaultPasses, TerrainPass]
    var r = SceneRendererOf[MyPasses](device, format, view)
    r.passes.second.set_field(device, TerrainField.from_heightfield(collider_heights))

Per frame `prepare` picks every chunk's level (`TerrainField.levels`), drops the chunks whose bounding sphere is outside
the view (app/cull.mojo `capsule_outside`), groups the rest by level and uploads one u32x4 record per chunk. `record_color`
issues one instanced draw per level present (at most log2(chunk) + 1 draws): instance = chunk, vertex = 6 per cell.
The vertex shader is `TerrainField.chunk_vertex` in WGSL, the CPU tests check that function.

Shading: the fixed sun of the primitive pass (0.4 + 0.6 max(n . sun, 0)), the normal from central differences of the
grid, bilinear between the four corners of the fragment's cell. Texturing: four texture array layers (`layers`), each
times a tint (`tints`), sampled at world (x, z) * `tiling`, weighted by the splat map read bilinearly at the fragment's
(x, z). Layer 0 is the engine's white layer, so a tint alone colours a splat channel. No shadow, fog or point lights.

Buffers: header (vec4<f32>): [0..3] camera (gpu_mesh.cam_floats), [4] nx nz cell chunk, [5] ox oz tiling stitch,
[6] layers 0..3, [7..10] tints. Chunks: vec4<u32> each. Heights: f32 per corner. Splat: u32 per corner (RGBA8).
A 4097 x 4097 grid is 67 MB of heights and 67 MB of splat weights, under the default 128 MiB binding limit."""
from std.math import sqrt
from game.camera_view import View
from game.draw_item import DrawItem
from game.terrain import TerrainField
from geometry.vec import Real, Vec3
from wgpu import WGPUBufferUsage, WGPUShaderStage, WGPUBindGroupLayoutEntry, WGPUBindGroupEntry
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup, BindGroupLayout
from wgpu.pipeline_layout import PipelineLayout
from wgpu.render_pass import FrameRenderPass
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.gpu_blend import pulled_pipeline, BLEND_NONE, CULL_NONE, DEPTH_LESS_EQUAL
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass, DrawCounts
from app.textures import TextureArray
from app.cull import capsule_outside
from app.bind_entries import storage_entry, texture_array_entry, sampler_entry, buffer_bind, view_bind, sampler_bind

comptime TERRAIN_HEADER_VEC4 = 11

comptime TERRAIN_WGSL = """
@group(0) @binding(0) var<storage, read> hdr : array<vec4<f32>>;
@group(0) @binding(1) var<storage, read> chunks : array<vec4<u32>>;
@group(0) @binding(2) var<storage, read> heights : array<f32>;
@group(0) @binding(3) var<storage, read> splat : array<u32>;
@group(1) @binding(0) var tex : texture_2d_array<f32>;
@group(1) @binding(1) var samp : sampler;

struct VOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) wpos : vec3<f32>,
};

fn nx() -> i32 { return i32(hdr[4].x); }
fn nz() -> i32 { return i32(hdr[4].y); }
fn h(ix : i32, iz : i32) -> f32 {
  let x = clamp(ix, 0, nx() - 1);
  let z = clamp(iz, 0, nz() - 1);
  return heights[u32(z * nx() + x)];
}
fn nb(r : vec4<u32>, side : u32) -> i32 { return i32((r.w >> (8u * side)) & 255u); }

// TerrainField.chunk_vertex, line for line
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VOut {
  let r = chunks[ii];
  let ix0 = i32(r.x);
  let iz0 = i32(r.y);
  let level = i32(r.z);
  let chunk = i32(hdr[4].w);
  let s = 1 << u32(level);
  let n = chunk >> u32(level);
  let c = i32(vi / 6u);
  let k = vi % 6u;
  let cx = c % n;
  let cz = c / n;
  let parity = ((ix0 / s + cx) + (iz0 / s + cz)) & 1;
  var even = array<i32, 6>(0, 2, 3, 0, 3, 1);
  var odd = array<i32, 6>(0, 2, 1, 1, 2, 3);
  var corner = even[k];
  if parity == 1 { corner = odd[k]; }
  var ix = ix0 + (cx + (corner & 1)) * s;
  var iz = iz0 + (cz + (corner >> 1)) * s;
  if hdr[5].w > 0.5 {
    if ix == ix0 || ix == ix0 + chunk {
      var side = 0u;
      if ix != ix0 { side = 1u; }
      let big = 1 << u32(nb(r, side));
      if big > s { iz = iz - iz % big; }
    }
    if iz == iz0 || iz == iz0 + chunk {
      var side = 2u;
      if iz != iz0 { side = 3u; }
      let big = 1 << u32(nb(r, side));
      if big > s { ix = ix - ix % big; }
    }
  }
  let y = h(ix, iz);
  let world = vec3<f32>(hdr[5].x + f32(ix) * hdr[4].z, y, hdr[5].y + f32(iz) * hdr[4].z);
  let d = world - hdr[0].xyz;
  let x = dot(d, hdr[1].xyz);
  let yy = dot(d, hdr[2].xyz);
  let z = dot(d, hdr[3].xyz);
  let near = hdr[2].w;
  let far = hdr[3].w;
  var out : VOut;
  out.pos = vec4<f32>(x * hdr[0].w, yy * hdr[1].w, far * (z - near) / (far - near), z);
  if hdr[0].w < 0.0 { out.pos = vec4<f32>(-x * hdr[0].w, yy * hdr[1].w, (z - near) / (far - near), 1.0); }
  out.wpos = world;
  return out;
}

fn corner_normal(ix : i32, iz : i32) -> vec3<f32> {
  let cell = hdr[4].z;
  let gx = (h(ix + 1, iz) - h(ix - 1, iz)) / (2.0 * cell);
  let gz = (h(ix, iz + 1) - h(ix, iz - 1)) / (2.0 * cell);
  return normalize(vec3<f32>(-gx, 1.0, -gz));
}
fn weights(ix : i32, iz : i32) -> vec4<f32> {
  let x = clamp(ix, 0, nx() - 1);
  let z = clamp(iz, 0, nz() - 1);
  return unpack4x8unorm(splat[u32(z * nx() + x)]);
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  let gu = (in.wpos.x - hdr[5].x) / hdr[4].z;
  let gv = (in.wpos.z - hdr[5].y) / hdr[4].z;
  let i0 = i32(floor(gu));
  let j0 = i32(floor(gv));
  let f = vec2<f32>(gu - floor(gu), gv - floor(gv));
  let w = mix(mix(weights(i0, j0), weights(i0 + 1, j0), f.x), mix(weights(i0, j0 + 1), weights(i0 + 1, j0 + 1), f.x), f.y);
  let nrm = normalize(mix(mix(corner_normal(i0, j0), corner_normal(i0 + 1, j0), f.x),
                          mix(corner_normal(i0, j0 + 1), corner_normal(i0 + 1, j0 + 1), f.x), f.y));
  let uv = in.wpos.xz * hdr[5].z;
  let l = hdr[6];
  let c0 = textureSample(tex, samp, uv, i32(l.x)).rgb * hdr[7].rgb;
  let c1 = textureSample(tex, samp, uv, i32(l.y)).rgb * hdr[8].rgb;
  let c2 = textureSample(tex, samp, uv, i32(l.z)).rgb * hdr[9].rgb;
  let c3 = textureSample(tex, samp, uv, i32(l.w)).rgb * hdr[10].rgb;
  let sum = max(w.x + w.y + w.z + w.w, 1e-4);
  let base = (c0 * w.x + c1 * w.y + c2 * w.z + c3 * w.w) / sum;
  let lit = 0.4 + 0.6 * max(dot(nrm, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  return vec4<f32>(base * lit, 1.0);
}
"""


struct TerrainPass(RenderPass):
    comptime SHADOW: Bool = False

    @staticmethod
    def sig() -> String:
        return "Terrain"

    var field: TerrainField
    var on: Bool  # set_field was called
    var pipeline: RenderPipeline
    var bgl: BindGroupLayout
    var header: Buffer
    var chunks: Buffer
    var heights: Buffer
    var splat: Buffer
    var group: BindGroup
    var tex_group: BindGroup  # group 1: the renderer's texture array and sampler
    var layers: List[Int]  # texture array layer of splat channels 0..3
    var tints: List[Float32]  # 4 x rgba
    var tiling: Float32  # texture repeats per metre
    var draw_level: List[Int]  # per draw this frame: level
    var draw_first: List[Int]  # first instance
    var draw_count: List[Int]  # instances
    var drawn_chunks: Int
    var culled_chunks: Int
    var triangles: Int
    var stitch: Bool  # False only for the negative control of tests/terrain_native.mojo
    var force_level: Int  # >= 0: every chunk at this level (tests); -1: by distance
    var forced_levels: List[Int]  # non-empty: these levels, row-major (tests)

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray, samples: UInt32 = 1) raises:
        var shader = device.create_shader_module_wgsl(String(TERRAIN_WGSL), "terrain")
        var vf = WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value
        var entries: List[WGPUBindGroupLayoutEntry] = [
            storage_entry(0, vf), storage_entry(1, WGPUShaderStage.VERTEX.value), storage_entry(2, vf),
            storage_entry(3, WGPUShaderStage.FRAGMENT.value),
        ]
        self.bgl = device.create_bind_group_layout(entries)
        var tex_entries: List[WGPUBindGroupLayoutEntry] = [
            texture_array_entry(0, WGPUShaderStage.FRAGMENT.value), sampler_entry(1, WGPUShaderStage.FRAGMENT.value),
        ]
        var tex_bgl = device.create_bind_group_layout(tex_entries)
        var handles: List[Pointer[NoneType, MutUntrackedOrigin]] = [self.bgl.handle().raw, tex_bgl.handle().raw]
        var layout = device.create_pipeline_layout(handles, "terrain_layout")
        var tex_bg: List[WGPUBindGroupEntry] = [view_bind(0, textures.view), sampler_bind(1, textures.main_sampler)]
        self.tex_group = device.create_bind_group(tex_bgl, tex_bg, "terrain_textures")
        self.pipeline = pulled_pipeline(
            device, shader, layout, color_format, depth_format, 4, BLEND_NONE, CULL_NONE, True, DEPTH_LESS_EQUAL, samples,
        )
        self.field = TerrainField(List[Float32](length=4, fill=0.0), 2, 2, 1.0, 0.0, 0.0, 1)
        self.on = False
        var usage = WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST
        self.header = device.create_buffer(UInt64(TERRAIN_HEADER_VEC4 * 16), usage, label="terrain_header")
        self.chunks = device.create_buffer(UInt64(16), usage, label="terrain_chunks")
        self.heights = device.create_buffer(UInt64(16), usage, label="terrain_heights")
        self.splat = device.create_buffer(UInt64(16), usage, label="terrain_splat")
        self.group = _group(device, self.bgl, self.header, self.chunks, self.heights, self.splat)
        self.layers = [0, 0, 0, 0]
        self.tints = [0.42, 0.55, 0.28, 1.0, 0.55, 0.47, 0.36, 1.0, 0.92, 0.93, 0.95, 1.0, 0.45, 0.43, 0.42, 1.0]
        self.tiling = 0.25
        self.draw_level = List[Int]()
        self.draw_first = List[Int]()
        self.draw_count = List[Int]()
        self.drawn_chunks = 0
        self.culled_chunks = 0
        self.triangles = 0
        self.stitch = True
        self.force_level = -1
        self.forced_levels = List[Int]()

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, textures, UInt32(caps.samples))

    def set_field(mut self, device: Device, var field: TerrainField) raises:
        """Upload a terrain: heights and splat weights once, chunk records every frame."""
        self.field = field^
        var usage = WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST
        var n = self.field.nx * self.field.nz
        self.heights = device.create_buffer(UInt64(n * 4), usage, label="terrain_heights")
        self.splat = device.create_buffer(UInt64(n * 4), usage, label="terrain_splat")
        self.chunks = device.create_buffer(UInt64(self.field.ccx * self.field.ccz * 16), usage, label="terrain_chunks")
        device.queue_write_data(self.heights, UInt64(0), self.field.h)
        device.queue_write_data(self.splat, UInt64(0), self.field.splat)
        self.group = _group(device, self.bgl, self.header, self.chunks, self.heights, self.splat)
        self.on = True

    def upload_heights(mut self, device: Device, first: Int, end: Int) raises:
        """Re-upload corners [first, end) after `field.update_rows` (a deformed collider)."""
        if not self.on or end <= first:
            return
        var part = List[Float32](capacity=end - first)
        for i in range(first, end):
            part.append(self.field.h[i])
        device.queue_write_data(self.heights, UInt64(first * 4), part)

    def upload_splat(mut self, device: Device) raises:
        if self.on:
            device.queue_write_data(self.splat, UInt64(0), self.field.splat)

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.draw_level.clear()
        self.draw_first.clear()
        self.draw_count.clear()
        self.drawn_chunks = 0
        self.culled_chunks = 0
        self.triangles = 0
        if not self.on:
            return
        ref f = self.field
        var levels: List[Int]
        if len(self.forced_levels) == f.ccx * f.ccz:
            levels = self.forced_levels.copy()
        elif self.force_level >= 0:
            levels = List[Int](length=f.ccx * f.ccz, fill=min(self.force_level, f.max_level()))
        else:
            levels = f.levels(Float64(view.eye[0]), Float64(view.eye[1]), Float64(view.eye[2]))
        var records = List[UInt32]()
        var side = Float64(f.chunk) * Float64(f.cell)
        for level in range(f.max_level() + 1):
            var first = len(records) // 4
            for cz in range(f.ccz):
                for cx in range(f.ccx):
                    var i = cz * f.ccx + cx
                    if levels[i] != level:
                        continue
                    var y0 = Float64(f.ymin[i])
                    var y1 = Float64(f.ymax[i])
                    var c = Vec3(
                        Real(Float64(f.ox) + (Float64(cx) + 0.5) * side), Real((y0 + y1) * 0.5),
                        Real(Float64(f.oz) + (Float64(cz) + 0.5) * side), Real(0.0),
                    )
                    var hy = (y1 - y0) * 0.5
                    var radius = sqrt(side * side * 0.5 + hy * hy)
                    if capsule_outside(view, c, c, radius):
                        self.culled_chunks += 1
                        continue
                    var r = f.record(levels, cx, cz)
                    records.append(UInt32(r.ix0))
                    records.append(UInt32(r.iz0))
                    records.append(UInt32(r.level))
                    records.append(UInt32(r.nw) | (UInt32(r.ne) << 8) | (UInt32(r.ns) << 16) | (UInt32(r.nn) << 24))
            var count = len(records) // 4 - first
            if count > 0:
                self.draw_level.append(level)
                self.draw_first.append(first)
                self.draw_count.append(count)
                self.drawn_chunks += count
                self.triangles += count * f.vertices_at(level) // 3
        var hdr = cam_floats(view)
        for v in [Float32(f.nx), Float32(f.nz), f.cell, Float32(f.chunk), f.ox, f.oz, self.tiling, Float32(1.0) if self.stitch else Float32(0.0)]:
            hdr.append(v)
        for k in range(4):
            hdr.append(Float32(self.layers[k]))
        for k in range(16):
            hdr.append(self.tints[k])
        device.queue_write_data(self.header, UInt64(0), hdr)
        if len(records) > 0:
            device.queue_write_data(self.chunks, UInt64(0), records)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        if len(self.draw_level) == 0:
            return
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.set_bind_group(UInt32(1), self.tex_group)
        for d in range(len(self.draw_level)):
            rpass.draw(
                UInt32(self.field.vertices_at(self.draw_level[d])), UInt32(self.draw_count[d]), UInt32(0),
                UInt32(self.draw_first[d]),
            )

    def counts(self, meshes: MeshRegistry) -> DrawCounts:
        return DrawCounts(len(self.draw_level), self.triangles)


def _group(
    device: Device, bgl: BindGroupLayout, header: Buffer, chunks: Buffer, heights: Buffer, splat: Buffer,
) raises -> BindGroup:
    var bg: List[WGPUBindGroupEntry] = [
        buffer_bind(0, header), buffer_bind(1, chunks), buffer_bind(2, heights), buffer_bind(3, splat),
    ]
    return device.create_bind_group(bgl, bg, "terrain_group")
