"""Indexed meshes (step 5, PR A): static geometry with one transform per instance, drawn in the arena's render pass.

A draw item with mesh_id >= 0 takes this path; mesh_id -1 keeps the primitive path in app/render3d.mojo. The camera
header is the arena's (same projection), so a mesh and a sphere at the same place line up.

Vertex buffers (step mode vertex): 0 position float32x3, 1 normal float32x3, 2 uv float32x2.
Instance buffer (step mode instance, 24 floats = 96 bytes per instance): model matrix as four columns (16 floats,
column-major), colour (4 floats: rgb, 1), meta (4 floats, zero in PR A; material, layer and palette base come later).
Model matrix: rotation from the quaternion, scaled per axis by `half` (per-axis scale for meshes), then translated by `pos`.
Instances of one mesh are contiguous in the instance buffer; the draw uses first_instance to address the group.
"""
from game.arena import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.textures import TextureArray, TRI_WGSL
from wgpu.texture import Texture, TextureView
from wgpu.sampler import Sampler
from wgpu._ffi.types import WGPUTextureUsage
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUVertexFormat, WGPUVertexStepMode, WGPUIndexFormat,
)
from wgpu._ffi.nulls import null_opaque, null_ptr
from wgpu._ffi.structs import (
    WGPURenderPipelineDescriptor, WGPUVertexState, WGPUVertexBufferLayout, WGPUVertexAttribute,
    WGPUFragmentState, WGPUColorTargetState, WGPUPrimitiveState, WGPUMultisampleState,
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUBlendState, WGPUConstantEntry, WGPUStringView,
)
from wgpu._backend.wgpu_native.structs import str_to_sv
from wgpu._ffi.types import WGPUTextureFormat
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule

comptime MAX_MESH_INSTANCES = 8192  # mesh and skinned instances per frame: 8192 x 24 floats = 768 KB
comptime SHADOW_MAP_SIZE = 1024  # the mesh pass's shadow map, square; 4 MB of depth
comptime AO_MAX_CELLS = 16384  # the ambient-occlusion grid: up to 128 by 128 floats over the floor (64 KB)
comptime FLOATS_PER_INSTANCE = 24
comptime MESH_WGSL = """
struct Cam { eye : vec4<f32>, right : vec4<f32>, up : vec4<f32>, fwd : vec4<f32> };
@group(0) @binding(0) var<uniform> cam : Cam;
// shadow: the light's view-projection (orthographic, z in [0, 1]); params.x 1 turns the shadow factor on
struct Shadow { vp : mat4x4<f32>, params : vec4<f32> };
@group(0) @binding(3) var shadow_map : texture_depth_2d;
@group(0) @binding(4) var shadow_cmp : sampler_comparison;
@group(0) @binding(5) var<uniform> shadow : Shadow;
// ao: a grid of ambient occlusion over the floor, 1 open and 0 occluded, row-major by z; ext is (x0, z0, sx, sz) in
// metres, dims is (nx, ny), params.x 1 turns it on. Outside the grid the factor is 1.
struct Ao { ext : vec4<f32>, dims : vec4<f32>, params : vec4<f32> };
@group(0) @binding(6) var<storage, read> ao_cells : array<f32>;
@group(0) @binding(7) var<uniform> ao : Ao;
fn ao_factor(p : vec3<f32>) -> f32 {
  let uv = (p.xz - ao.ext.xy) / ao.ext.zw;
  if uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0 { return 1.0; }
  let n = vec2<u32>(ao.dims.xy);
  let c = min(vec2<u32>(uv * vec2<f32>(n)), n - vec2<u32>(1u));
  return ao_cells[c.y * n.x + c.x];
}
""" + TRI_WGSL + """

struct VIn {
  @location(0) pos : vec3<f32>,
  @location(1) nrm : vec3<f32>,
  @location(2) uv : vec2<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
  @location(7) color : vec4<f32>,
  @location(8) info : vec4<f32>,
};
// info: x unused by static meshes, y the material (0 colour, 1 uv, 2 triplanar), z the texture layer
struct VOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color : vec3<f32>,
  @location(1) wpos : vec3<f32>,
  @location(2) wnrm : vec3<f32>,
  @location(3) uv : vec2<f32>,
  @location(4) base : vec3<f32>,
  @location(5) lit : f32,
  @location(6) @interpolate(flat) mat : u32,
  @location(7) @interpolate(flat) layer : u32,
  @location(8) lpos : vec3<f32>,
};

// the light-space position of a world point: NDC xy in [-1, 1], z in [0, 1]
fn shadow_factor(p : vec3<f32>, ndl : f32) -> f32 {
  // uv: NDC +y is the top row of the depth texture
  let uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  // a constant bias scaled by (1 - N.L) against acne on the faces turned from the light
  let ref_z = p.z - 0.003 * (1.0 - ndl);
  let texel = 1.0 / vec2<f32>(textureDimensions(shadow_map));
  // 3x3 percentage-closer filter; every tap is uniform control flow, so textureSampleCompareLevel is valid
  var acc = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      acc += textureSampleCompareLevel(shadow_map, shadow_cmp, uv + vec2<f32>(f32(i), f32(j)) * texel, ref_z);
    }
  }
  let inside = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 && p.z <= 1.0;
  return select(1.0, acc / 9.0, inside);
}

@vertex
fn vs_main(v : VIn) -> VOut {
  let m = mat4x4<f32>(v.m0, v.m1, v.m2, v.m3);
  let world = (m * vec4<f32>(v.pos, 1.0)).xyz;
  let n = normalize((m * vec4<f32>(v.nrm, 0.0)).xyz);
  let d = world - cam.eye.xyz;
  let x = dot(d, cam.right.xyz);
  let y = dot(d, cam.up.xyz);
  let z = dot(d, cam.fwd.xyz);
  let near = cam.up.w;
  let far = cam.fwd.w;
  var out : VOut;
  out.pos = vec4<f32>(x * cam.eye.w, y * cam.right.w, far * (z - near) / (far - near), z);
  let lit = 0.4 + 0.6 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  out.color = v.color.rgb * lit;
  out.wpos = world;
  out.wnrm = n;
  out.uv = v.uv;
  out.base = v.color.rgb;
  out.lit = lit;
  out.mat = u32(v.info.y);
  out.layer = u32(v.info.z);
  let lp = shadow.vp * vec4<f32>(world, 1.0);
  out.lpos = lp.xyz / lp.w;
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  // with the shadow off the factor is exactly 1.0, so the colour is unchanged bit for bit
  let ndl = max(dot(normalize(in.wnrm), normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  // the AO factor multiplies the shadow factor; with AO off it is exactly 1.0, so the colour is unchanged bit for bit
  let sf = select(1.0, shadow_factor(in.lpos, ndl), shadow.params.x > 0.5) * select(1.0, ao_factor(in.wpos), ao.params.x > 0.5);
  // material 0 is the colour-only look: the same output as before textures existed
  if in.mat == 0u {
    return vec4<f32>(in.color * sf, 1.0);
  }
  var t : vec4<f32>;
  if in.mat == 1u {
    t = textureSampleLevel(tex, samp, in.uv, in.layer, 0.0);
  } else {
    t = triplanar(in.wpos, in.wnrm, in.layer, 0.0);
  }
  return vec4<f32>(in.base * t.rgb * in.lit * sf, 1.0);
}
"""


@fieldwise_init
struct MeshData(Copyable, Movable):
    """One static mesh on the CPU: positions, normals, uv and a triangle index list."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var indices: List[UInt32]


def _check_mesh(positions: List[Float32], normals: List[Float32], uv: List[Float32], indices: List[UInt32]) raises:
    """The boundary check for every mesh: arrays that agree, and indices inside the vertex range."""
    var nv = len(positions) // 3
    if len(positions) % 3 != 0 or nv == 0:
        raise Error("mesh: positions must be a non-empty multiple of 3 floats")
    if len(normals) != len(positions):
        raise Error("mesh: normals must have one vector per position")
    if len(uv) != nv * 2:
        raise Error("mesh: uv must have one pair per position")
    if len(indices) == 0 or len(indices) % 3 != 0:
        raise Error("mesh: indices must be a non-empty list of triangles")
    for i in indices:
        if Int(i) >= nv:
            raise Error("mesh: an index is outside the vertex range")


@fieldwise_init
struct SkinnedMeshData(Copyable, Movable):
    """A mesh with joints: 4 joint indices (u16) and 4 weights per vertex. The joint indices are relative to the pose's
    palette base (the draw item's pose_id)."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var joints: List[UInt16]
    var weights: List[Float32]
    var indices: List[UInt32]


struct MeshRegistry(Movable):
    """The meshes a game registers. Static meshes are indexed by the mesh_id a draw item carries; skinned meshes by the
    id add_skinned returns. A draw item with pose_id >= 0 refers to a skinned mesh."""

    var meshes: List[MeshData]
    var skinned: List[SkinnedMeshData]

    def __init__(out self):
        self.meshes = List[MeshData]()
        self.skinned = List[SkinnedMeshData]()

    def add_skinned(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var joints: List[UInt16],
        var weights: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """As add_static, plus 4 joints and 4 weights per vertex. Returns the skinned id."""
        _check_mesh(positions, normals, uv, indices)
        if len(joints) != 4 * (len(positions) // 3) or len(weights) != 4 * (len(positions) // 3):
            raise Error("mesh: a skinned mesh needs 4 joints and 4 weights per vertex")
        for w in weights:
            if w < 0.0:
                raise Error("mesh: skinning weights are not negative")
        self.skinned.append(SkinnedMeshData(positions^, normals^, uv^, joints^, weights^, indices^))
        return len(self.skinned) - 1

    def add_static(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """Check the arrays at the boundary (an invalid mesh raises), then keep it. Returns its id."""
        _check_mesh(positions, normals, uv, indices)
        self.meshes.append(MeshData(positions^, normals^, uv^, indices^))
        return len(self.meshes) - 1

    def count(self) -> Int:
        return len(self.meshes)


def _fnv_word(mut h: UInt64, v: Int):
    """FNV-1a over the eight little-endian bytes of v, v >= 0."""
    var x = UInt64(v)
    for _ in range(8):
        h = h ^ (x & 0xFF)
        h = h * 1099511628211
        x = x >> 8


def _round4(v: Float64) -> Int:
    """Rounded to 1e-4 and shifted to be non-negative (|v| < 2^39 / 1e4), for the hash."""
    var q = v * 10000.0
    var r = Int(q + 0.5) if q >= 0.0 else -Int(-q + 0.5)
    return r + (1 << 40)


def mesh_draw_hash(items: List[DrawItem], registry: MeshRegistry) -> UInt64:
    """FNV-1a over the mesh draw list, in draw order: per mesh group, mesh_id, instance count, index count, and the
    first instance's position rounded to 1e-4. Items with mesh_id < 0 are not part of this list."""
    var h = UInt64(0xCBF29CE484222325)
    var seen = List[Int]()
    for it in items:
        if it.mesh_id < 0 or it.mesh_id in seen:
            continue
        seen.append(it.mesh_id)
        var n = 0
        var first = -1
        for j in range(len(items)):
            if items[j].mesh_id == it.mesh_id:
                if first < 0:
                    first = j
                n += 1
        _fnv_word(h, it.mesh_id)
        _fnv_word(h, n)
        _fnv_word(h, len(registry.meshes[it.mesh_id].indices))
        _fnv_word(h, _round4(Float64(items[first].pos[0])))
        _fnv_word(h, _round4(Float64(items[first].pos[1])))
        _fnv_word(h, _round4(Float64(items[first].pos[2])))
    return h


def unit_cube_arrays() -> Tuple[List[Float32], List[Float32], List[Float32], List[UInt32]]:
    """A cube of half-extent 0.5 centred on the origin: 6 faces, 4 vertices each, outward normals, uv per corner."""
    var pos = List[Float32]()
    var nrm = List[Float32]()
    var uv = List[Float32]()
    var idx = List[UInt32]()
    for a in range(3):
        for s in [-1.0, 1.0]:
            var u = (a + 1) % 3
            var v = (a + 2) % 3
            var base = UInt32(len(pos) // 3)
            var corners = [(-1.0, -1.0, 0.0, 0.0), (1.0, -1.0, 1.0, 0.0), (1.0, 1.0, 1.0, 1.0), (-1.0, 1.0, 0.0, 1.0)]
            for c in corners:
                var p = [0.0, 0.0, 0.0]
                p[a] = s * 0.5
                p[u] = c[0] * 0.5
                p[v] = c[1] * 0.5
                for k in range(3):
                    pos.append(Float32(p[k]))
                    nrm.append(Float32(s if k == a else 0.0))
                uv.append(Float32(c[2]))
                uv.append(Float32(c[3]))
            idx.append(base)
            idx.append(base + 1)
            idx.append(base + 2)
            idx.append(base)
            idx.append(base + 2)
            idx.append(base + 3)
    return (pos^, nrm^, uv^, idx^)


def add_unit_cube(mut registry: MeshRegistry) raises -> Int:
    """The unit cube as a static mesh."""
    var c = unit_cube_arrays()
    return registry.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())


def mesh_probe_hash() raises -> UInt64:
    """The draw-list hash of a fixed probe: one unit cube, three instances at non-integer positions (so the rounding
    runs). Native and wasm64 run this same code, so equal values show that both agree on the hash's inputs."""
    var reg = MeshRegistry()
    var cube = add_unit_cube(reg)
    var items = List[DrawItem]()
    items.append(DrawItem(-1, Vec3(Real(0.25), Real(-1.5), Real(0.1), Real(0.0)), 0.0, 0.0, 0.0, 1.0,
                          Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.5), Real(0.5), Real(0.5), Real(0.0)), cube, -1, 0))
    items.append(DrawItem(-1, Vec3(Real(-2.75), Real(0.3), Real(0.6), Real(0.0)), 0.0, 0.0, 0.0, 1.0,
                          Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.5), Real(0.5), Real(0.5), Real(0.0)), cube, -1, 0))
    items.append(DrawItem(-1, Vec3(Real(0.33333), Real(1.0), Real(-0.7), Real(0.0)), 0.0, 0.0, 0.0, 1.0,
                          Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.5), Real(0.5), Real(0.5), Real(0.0)), cube, -1, 0))
    return mesh_draw_hash(items, reg)


def model_floats(it: DrawItem, mut out: List[Float32]):
    """Four columns of pos + rotation(q) * scale(half); then colour rgb,1; then four zeros (meta)."""
    var x = it.qx
    var y = it.qy
    var z = it.qz
    var w = it.qw
    var xx = x * x
    var yy = y * y
    var zz = z * z
    var xy = x * y
    var xz = x * z
    var yz = y * z
    var wx = w * x
    var wy = w * y
    var wz = w * z
    var sx = Float64(it.half[0])
    var sy = Float64(it.half[1])
    var sz = Float64(it.half[2])
    # column-major: column c is out[4c .. 4c+3]
    out.append(Float32((1.0 - 2.0 * (yy + zz)) * sx))
    out.append(Float32(2.0 * (xy + wz) * sx))
    out.append(Float32(2.0 * (xz - wy) * sx))
    out.append(0.0)
    out.append(Float32(2.0 * (xy - wz) * sy))
    out.append(Float32((1.0 - 2.0 * (xx + zz)) * sy))
    out.append(Float32(2.0 * (yz + wx) * sy))
    out.append(0.0)
    out.append(Float32(2.0 * (xz + wy) * sz))
    out.append(Float32(2.0 * (yz - wx) * sz))
    out.append(Float32((1.0 - 2.0 * (xx + yy)) * sz))
    out.append(0.0)
    out.append(Float32(Float64(it.pos[0])))
    out.append(Float32(Float64(it.pos[1])))
    out.append(Float32(Float64(it.pos[2])))
    out.append(1.0)
    out.append(Float32(Float64(it.color[0])))
    out.append(Float32(Float64(it.color[1])))
    out.append(Float32(Float64(it.color[2])))
    out.append(1.0)
    out.append(0.0)
    out.append(0.0)
    out.append(0.0)
    out.append(0.0)


struct MeshPass(Movable):
    """The indexed mesh pass. Built once per device; the GPU copies of the meshes are made by upload()."""

    var pipeline: RenderPipeline
    var camera: Buffer
    var instances: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var vbufs: List[Buffer]  # three per mesh: positions, normals, uv
    var ibufs: List[Buffer]  # one per mesh
    var uploaded: Int
    var order: List[Int]
    var counts: List[Int]
    var base: List[Int]
    var shadow_tex: Texture  # the shadow map: a shadow pass renders depth into it (shadow_tex.create_view_default())
    var shadow_view: TextureView
    var shadow_sampler: Sampler  # comparison sampler, LessEqual
    var shadow_ubo: Buffer  # light view-projection (64 bytes) and params (16 bytes): params.x 1 turns the shadow on
    var ao_cells: Buffer  # the AO grid: AO_MAX_CELLS floats, all 1 (open) until set_ao
    var ao_ubo: Buffer  # AO extent, dims and the on-flag (48 bytes)

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray) raises:
        var shader = device.create_shader_module_wgsl(MESH_WGSL, "mesh")
        # shadow resources, always bound; with the shadow off the sampled value is ignored (factor 1.0)
        self.shadow_tex = device.create_texture(
            UInt32(SHADOW_MAP_SIZE), UInt32(SHADOW_MAP_SIZE), UInt32(1), WGPUTextureFormat.Depth32Float,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=1, label="mesh_shadow_map",
        )
        self.shadow_view = self.shadow_tex.create_view_default()
        self.shadow_sampler = device.create_sampler(mag_filter=1, min_filter=1, mipmap_filter=1, compare=UInt32(4), label="mesh_shadow_cmp")
        self.shadow_ubo = device.create_buffer(
            UInt64(80), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_shadow_ubo",
        )
        var off = List[Float32]()  # identity light matrix, shadow off
        for c in range(16):
            off.append(Float32(1.0) if c % 5 == 0 else Float32(0.0))
        for c in range(4):
            off.append(0.0)
        device.queue_write_data(self.shadow_ubo, UInt64(0), off)
        self.ao_cells = device.create_buffer(
            UInt64(AO_MAX_CELLS * 4), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="mesh_ao_cells",
        )
        self.ao_ubo = device.create_buffer(UInt64(48), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_ao_ubo")
        var ones = List[Float32]()
        for _ in range(AO_MAX_CELLS):
            ones.append(1.0)
        device.queue_write_data(self.ao_cells, UInt64(0), ones)
        var ao_off = List[Float32]()  # AO off: extent, dims and params all zero, the factor is 1
        for _ in range(12):
            ao_off.append(0.0)
        device.queue_write_data(self.ao_ubo, UInt64(0), ao_off)
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(3), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(2), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(3), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),  # depth, 2D
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(4), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),  # not a buffer
                WGPUSamplerBindingLayout(null_opaque(), UInt32(4)),  # comparison
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(5), WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(6), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(7), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "mesh_layout")
        self.pipeline = _build_pipeline(device, shader, layout, color_format, depth_format)
        self.camera = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_cam")
        self.instances = device.create_buffer(
            UInt64(MAX_MESH_INSTANCES * FLOATS_PER_INSTANCE * 4),
            WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="mesh_instances",
        )
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.camera.handle().raw, 0, UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), textures.view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), textures.main_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), self.shadow_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), self.shadow_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 5, self.shadow_ubo.handle().raw, 0, UInt64(80), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 6, self.ao_cells.handle().raw, 0, UInt64(AO_MAX_CELLS * 4), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 7, self.ao_ubo.handle().raw, 0, UInt64(48), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "mesh_group")
        # the view, sampler and buffer are kept as fields, alive past the bind group call
        self.staging = List[Float32]()
        self.vbufs = List[Buffer]()
        self.ibufs = List[Buffer]()
        self.uploaded = 0
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()

    def set_shadow(mut self, device: Device, light_vp: List[Float32], on: Bool) raises:
        """Set the light's view-projection (16 floats, column-major, NDC z in [0, 1]) and whether the shadow factor is
        applied. The shadow map itself is rendered by the caller into shadow_tex. Off by default: the colour is then
        unchanged bit for bit."""
        if len(light_vp) != 16:
            raise Error("mesh pass: the light view-projection has 16 floats")
        var data = List[Float32]()
        for c in range(16):
            data.append(light_vp[c])
        data.append(Float32(1.0) if on else Float32(0.0))
        data.append(0.0)
        data.append(0.0)
        data.append(0.0)
        device.queue_write_data(self.shadow_ubo, UInt64(0), data)

    def set_ao(mut self, device: Device, cells: List[Float32], nx: Int, ny: Int, x0: Float32, z0: Float32,
               sx: Float32, sz: Float32, on: Bool) raises:
        """Set the ambient-occlusion grid: nx by ny cells (row-major by z, 1 open, 0 occluded) over the floor rectangle
        (x0, z0) to (x0 + sx, z0 + sz) in metres, and whether it multiplies the lit colour. Off by default: the colour is
        then unchanged bit for bit. The grid is uploaded whole; a grid larger than AO_MAX_CELLS is refused."""
        if nx < 1 or ny < 1 or nx * ny > AO_MAX_CELLS or len(cells) != nx * ny:
            raise Error("mesh pass: the AO grid needs nx * ny cells, at most AO_MAX_CELLS, one per cell")
        if sx <= 0.0 or sz <= 0.0:
            raise Error("mesh pass: the AO grid's extent must be positive")
        device.queue_write_data(self.ao_cells, UInt64(0), cells)
        var u = List[Float32]()
        u.append(x0); u.append(z0); u.append(sx); u.append(sz)
        u.append(Float32(nx)); u.append(Float32(ny)); u.append(0.0); u.append(0.0)
        u.append(Float32(1.0) if on else Float32(0.0)); u.append(0.0); u.append(0.0); u.append(0.0)
        device.queue_write_data(self.ao_ubo, UInt64(0), u)

    def upload(mut self, device: Device, registry: MeshRegistry) raises:
        """Create the GPU vertex and index buffers for every mesh not yet uploaded. Meshes are never freed here."""
        while self.uploaded < registry.count():
            var m = registry.meshes[self.uploaded].copy()
            var vb_pos = device.create_buffer(UInt64(len(m.positions) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="mesh_pos")
            device.queue_write_data(vb_pos, UInt64(0), m.positions)
            var vb_nrm = device.create_buffer(UInt64(len(m.normals) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="mesh_nrm")
            device.queue_write_data(vb_nrm, UInt64(0), m.normals)
            var vb_uv = device.create_buffer(UInt64(len(m.uv) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="mesh_uv")
            device.queue_write_data(vb_uv, UInt64(0), m.uv)
            var ib = device.create_buffer(UInt64(len(m.indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="mesh_idx")
            device.queue_write_data(ib, UInt64(0), m.indices)
            self.vbufs.append(vb_pos^)
            self.vbufs.append(vb_nrm^)
            self.vbufs.append(vb_uv^)
            self.ibufs.append(ib^)
            self.uploaded += 1

    def prepare(mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, v: View) raises:
        """Everything that can fail, done before the render pass opens: upload the meshes, group the mesh items by
        mesh, write the camera header and the instance records. record() then only sets state and draws."""
        self.upload(device, registry)
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()
        for it in items:
            if it.mesh_id < 0 or it.pose_id >= 0:
                continue
            var found = -1
            for k in range(len(self.order)):
                if self.order[k] == it.mesh_id:
                    found = k
            if found < 0:
                self.order.append(it.mesh_id)
                self.counts.append(0)
                found = len(self.order) - 1
            self.counts[found] += 1
        var total = 0
        for c in self.counts:
            total += c
        if total > MAX_MESH_INSTANCES:
            raise Error("mesh pass: more instances than MAX_MESH_INSTANCES")
        # the camera header, the arena's layout: eye.w = sx, right.w = sy, up.w = near, fwd.w = far
        var cam = List[Float32]()
        for e in [v.eye, v.right, v.up, v.fwd]:
            for c in range(3):
                cam.append(Float32(e[c]))
            cam.append(0.0)
        cam[3] = Float32(v.sx)
        cam[7] = Float32(v.sy)
        cam[11] = Float32(v.near)
        cam[15] = Float32(v.far)
        device.queue_write_data(self.camera, UInt64(0), cam)
        # instances grouped by mesh, in group order
        var floats = List[Float32]()
        var running = 0
        for k in range(len(self.order)):
            self.base.append(running)
            for it in items:
                if it.mesh_id == self.order[k] and it.pose_id < 0:
                    var rec = len(floats)
                    model_floats(it, floats)
                    floats[rec + 21] = Float32(it.material)  # info.y: material
                    floats[rec + 22] = Float32(it.layer) if it.material > 0 else 0.0  # info.z: the texture layer
                    running += 1
        if total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)

    def record(self, mut rpass: FrameRenderPass, registry: MeshRegistry):
        """Set state and draw the groups prepared by prepare(). Nothing here can fail: an invariant that prepare()
        guarantees is a debug_assert, not an error. Each bind passes its exact byte size: the wrapper's default size
        of 0 binds nothing, and WGPU_WHOLE_SIZE does not survive the web translation (setVertexBuffer rejects it)."""
        if len(self.order) == 0:
            return
        var total = 0
        for c in self.counts:
            total += c
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.set_vertex_buffer(UInt32(3), self.instances, UInt64(0), UInt64(total * FLOATS_PER_INSTANCE * 4))
        for k in range(len(self.order)):
            var mid = self.order[k]
            debug_assert(mid < self.uploaded, "mesh pass: a mesh is drawn before upload()")
            var m = registry.meshes[mid].copy()
            rpass.set_vertex_buffer(UInt32(0), self.vbufs[3 * mid], UInt64(0), UInt64(len(m.positions) * 4))
            rpass.set_vertex_buffer(UInt32(1), self.vbufs[3 * mid + 1], UInt64(0), UInt64(len(m.normals) * 4))
            rpass.set_vertex_buffer(UInt32(2), self.vbufs[3 * mid + 2], UInt64(0), UInt64(len(m.uv) * 4))
            rpass.set_index_buffer(self.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(len(m.indices) * 4))
            rpass.draw_indexed(
                UInt32(len(m.indices)), UInt32(self.counts[k]), UInt32(0), Int32(0), UInt32(self.base[k]),
            )


def _build_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout,
    color_format: UInt32, depth_format: UInt32,
) raises -> RenderPipeline:
    """The mesh pipeline: vertex buffers 0-2 per vertex, 3 per instance, the arena's depth state."""
    var vs_name = String("vs_main")
    var fs_name = String("fs_main")
    var label_name = String("mesh_pipeline")
    # one attribute array per buffer: positions, normals, uv; then the six instance attributes
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var a1 = raw_alloc[WGPUVertexAttribute](1)
    a1[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(1))
    var a2 = raw_alloc[WGPUVertexAttribute](1)
    a2[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x2, UInt64(0), UInt32(2))
    var ai = raw_alloc[WGPUVertexAttribute](6)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    ai[unsafe_offset=4] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(64), UInt32(7))
    ai[unsafe_offset=5] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(80), UInt32(8))
    var vb = raw_alloc[WGPUVertexBufferLayout](4)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a1)
    vb[unsafe_offset=2] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(8), UInt(1), a2)
    vb[unsafe_offset=3] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(6), ai)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv(vs_name),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(4), vb,
    )
    var target_p = raw_alloc[WGPUColorTargetState](1)
    target_p[unsafe_offset=0] = WGPUColorTargetState(null_opaque(), color_format, null_ptr[WGPUBlendState](), UInt64(0xF))
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, str_to_sv(fs_name),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(1), target_p,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, fragment_p,
    )
    var result = device.create_render_pipeline(desc^)
    # the names are read by create_render_pipeline; keep them alive past that call
    _ = vs_name.byte_length() + fs_name.byte_length() + label_name.byte_length()
    a0.unsafe_free()
    a1.unsafe_free()
    a2.unsafe_free()
    ai.unsafe_free()
    vb.unsafe_free()
    target_p.unsafe_free()
    fragment_p.unsafe_free()
    dp.unsafe_free()
    return result^
