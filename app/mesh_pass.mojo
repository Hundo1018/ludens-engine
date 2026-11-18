"""Indexed meshes (step 5, PR A): static geometry with one transform per instance, drawn in the arena's render pass.

A draw item with mesh_id >= 0 takes this path; mesh_id -1 keeps the primitive path in app/render3d.mojo. The camera
header is the arena's (same projection), so a mesh and a sphere at the same place line up.

Vertex buffers (step mode vertex): 0 position float32x3, 1 normal float32x3, 2 uv float32x2.
Instance buffer (step mode instance, 24 floats = 96 bytes per instance): model matrix as four columns (16 floats,
column-major), colour (4 floats: rgb, 1), meta (4 floats, zero in PR A; material, layer and palette base come later).
Model matrix: rotation from the quaternion, scaled per axis by `half` (per-axis scale for meshes), then translated by `pos`.
Instances of one mesh are contiguous in the instance buffer; the draw uses first_instance to address the group.
"""
from game.draw_item import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from std.math import sin, cos
from app.textures import TextureArray, TRI_WGSL, ATMO_WGSL
from app.wgsl import CAM_WGSL, SHADOW_UBO_WGSL, PCF_WGSL, POINT_LIGHTS_WGSL
from app.render_res import RenderResources, LIGHTS_BYTES, SHADOW_MAP_SIZE, AO_MAX_CELLS, RenderCaps, MAX_MESH_INSTANCES, DEFAULT_ARENA_INSTANCES, DEFAULT_PALETTE_MATRICES
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
from app.mesh_data import MeshData, SkinnedMeshData, MeshRegistry
from app.render_pass import RenderPass
from app.gpu_blend import blend_state, cull_mode, BLEND_NONE, CULL_NONE
from app.material import Material, Materials, MatColor, MatUv, MatTriplanar, MatSky, MatPbr, PBR_WGSL
from app.gpu_mesh import GpuMeshCache, MeshBatches, cam_floats, STATIC_BUFFERS, S_POS, S_NRM, S_UV

comptime FLOATS_PER_INSTANCE = 24
comptime MESH_WGSL = CAM_WGSL + SHADOW_UBO_WGSL + """
@group(0) @binding(3) var shadow_map : texture_depth_2d;
@group(0) @binding(4) var shadow_cmp : sampler_comparison;
@group(0) @binding(5) var<uniform> shadow : Shadow;
// ao: a grid of ambient occlusion over the floor, 1 open and 0 occluded, row-major by z; ext is (x0, z0, sx, sz) in
// metres, dims is (nx, ny), params.x 1 turns it on. Outside the grid the factor is 1.
struct Ao { ext : vec4<f32>, dims : vec4<f32>, params : vec4<f32> };
@group(0) @binding(6) var<storage, read> ao_cells : array<f32>;
@group(0) @binding(7) var<uniform> ao : Ao;
@group(0) @binding(8) var<uniform> lights : Lights;
fn ao_factor(p : vec3<f32>) -> f32 {
  let uv = (p.xz - ao.ext.xy) / ao.ext.zw;
  if uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0 { return 1.0; }
  let n = vec2<u32>(ao.dims.xy);
  let c = min(vec2<u32>(uv * vec2<f32>(n)), n - vec2<u32>(1u));
  return ao_cells[c.y * n.x + c.x];
}
""" + TRI_WGSL + ATMO_WGSL + PCF_WGSL + POINT_LIGHTS_WGSL + PBR_WGSL + """

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
// info: x unused by static meshes, y the material (0 colour, 1 uv, 2 triplanar, 3 sky), z the texture layer
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
  @location(9) @interpolate(flat) rm : vec2<f32>,
};

@vertex
fn vs_main(v : VIn) -> VOut {
  let m = mat4x4<f32>(v.m0, v.m1, v.m2, v.m3);
  var world = (m * vec4<f32>(v.pos, 1.0)).xyz;
  let n = normalize((m * vec4<f32>(v.nrm, 0.0)).xyz);
  /*VERT_WORLD*/
  var out : VOut;
  out.pos = cam_clip(world);
  /*VERT_CLIP*/
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
  out.rm = vec2<f32>(floor(v.info.w / 256.0) / 255.0, (v.info.w - floor(v.info.w / 256.0) * 256.0) / 255.0);  // MAT_PBR: roughness, metallic
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  // with the shadow off the factor is exactly 1.0, so the colour is unchanged bit for bit
  let ndl = max(dot(normalize(in.wnrm), normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  // the AO factor multiplies the shadow factor; with AO off it is exactly 1.0, so the colour is unchanged bit for bit
  let sf = select(1.0, shadow_factor(in.lpos, ndl), shadow.params.x > 0.5) * select(1.0, ao_factor(in.wpos), ao.params.x > 0.5);
  // the item's material (app/material.mojo): shade() is generated from the pass's material pack
  // the point lights, per pixel, on top of the per-vertex sun; with none the vertex colour is used as it was
  var lit3 = vec3<f32>(in.lit);
  var color = in.color;
  if has_point_lights() {
    lit3 = lit3 + point_lights(in.wpos, normalize(in.wnrm));
    color = in.base * lit3;
  }
  return shade(in.mat, Surface(in.base, color, lit3, in.uv, in.layer, in.wpos, in.wnrm, sf, in.rm.x, in.rm.y));
}
"""


def vertex_normals(positions: List[Float32], indices: List[UInt32]) -> List[Float32]:
    """Per-vertex normals of a triangle mesh: each triangle's (unnormalised, so area-weighted) normal added to its three
    vertices, then normalised; a vertex no triangle uses gets (0, 1, 0). For a dynamic mesh's update_dynamic."""
    var n = List[Float32](length=len(positions), fill=Float32(0))
    for t in range(len(indices) // 3):
        var a = Int(indices[3 * t])
        var b = Int(indices[3 * t + 1])
        var c = Int(indices[3 * t + 2])
        var ux = positions[3 * b] - positions[3 * a]
        var uy = positions[3 * b + 1] - positions[3 * a + 1]
        var uz = positions[3 * b + 2] - positions[3 * a + 2]
        var vx = positions[3 * c] - positions[3 * a]
        var vy = positions[3 * c + 1] - positions[3 * a + 1]
        var vz = positions[3 * c + 2] - positions[3 * a + 2]
        var nx = uy * vz - uz * vy
        var ny = uz * vx - ux * vz
        var nz = ux * vy - uy * vx
        for k in [a, b, c]:
            n[3 * k] += nx
            n[3 * k + 1] += ny
            n[3 * k + 2] += nz
    for v in range(len(positions) // 3):
        var l = (n[3 * v] * n[3 * v] + n[3 * v + 1] * n[3 * v + 1] + n[3 * v + 2] * n[3 * v + 2]) ** Float32(0.5)
        if l > Float32(1e-12):
            n[3 * v] /= l
            n[3 * v + 1] /= l
            n[3 * v + 2] /= l
        else:
            n[3 * v + 1] = 1.0
    return n^


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


def unit_sphere_arrays(segments: Int = 24, rings: Int = 16) -> Tuple[List[Float32], List[Float32], List[Float32], List[UInt32]]:
    """A sphere of radius 0.5 centred on the origin (1 across, like the unit cube), uv by longitude and latitude."""
    var pos = List[Float32]()
    var nrm = List[Float32]()
    var uv = List[Float32]()
    var idx = List[UInt32]()
    comptime PI = 3.141592653589793
    for r in range(rings + 1):
        var v = Float64(r) / Float64(rings)
        var phi = v * PI
        for s in range(segments + 1):
            var u = Float64(s) / Float64(segments)
            var th = u * 2.0 * PI
            var x = sin(phi) * cos(th)
            var y = cos(phi)
            var z = sin(phi) * sin(th)
            pos.append(Float32(0.5 * x))
            pos.append(Float32(0.5 * y))
            pos.append(Float32(0.5 * z))
            nrm.append(Float32(x))
            nrm.append(Float32(y))
            nrm.append(Float32(z))
            uv.append(Float32(u))
            uv.append(Float32(v))
    var row = segments + 1
    for r in range(rings):
        for s in range(segments):
            var a = UInt32(r * row + s)
            var b = UInt32((r + 1) * row + s)
            idx.append(a)
            idx.append(a + 1)
            idx.append(b)
            idx.append(b)
            idx.append(a + 1)
            idx.append(b + 1)
    return (pos^, nrm^, uv^, idx^)


def add_unit_sphere(mut registry: MeshRegistry) raises -> Int:
    """The unit sphere (radius 0.5) as a static mesh."""
    var c = unit_sphere_arrays()
    return registry.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())


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
    # info.w: MAT_PBR's roughness and metallic, 8 bits each: round(r * 255) * 256 + round(m * 255)
    var r = Int(min(max(it.roughness, Float32(0)), Float32(1)) * 255.0 + 0.5)
    var m = Int(min(max(it.metallic, Float32(0)), Float32(1)) * 255.0 + 0.5)
    out.append(Float32(r * 256 + m))


struct MeshPassOf[*Ms: Material](RenderPass):
    """The indexed mesh pass. Built once per device. The camera, shadow, atmosphere and AO uniforms it binds are the
    renderer's RenderResources (app/render_res.mojo); the GPU copies of the meshes are the renderer's GpuMeshCache."""

    comptime SHADOW: Bool = False

    var pipeline: RenderPipeline
    var instances: Buffer

    @staticmethod
    def sig() -> String:
        """Mesh, with the names of the pack's materials that have one (the built-in materials do not)."""
        var names = String()
        comptime for i in range(len(Self.Ms)):
            if String(Self.Ms[i].NAME).byte_length() > 0:
                names += (", " if names.byte_length() > 0 else "") + String(Self.Ms[i].NAME)
        return "Mesh[" + names + "]" if names.byte_length() > 0 else String("Mesh")

    var group: BindGroup
    var staging: List[Float32]
    var batches: MeshBatches[False]  # this frame's static mesh items by mesh (prepare)
    var max_instances: Int  # RenderCaps.mesh_instances

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
                 ref res: RenderResources, caps: RenderCaps = RenderCaps.default()) raises:
        caps.check()
        self.max_instances = caps.mesh_instances
        # the pack's first material configures the pass: its vertex hooks, blend, cull and depth write
        var wgsl = String(MESH_WGSL).replace("/*VERT_WORLD*/", String(Self.Ms[0].VERT_WORLD)).replace("/*VERT_CLIP*/", String(Self.Ms[0].VERT_CLIP))
        var shader = device.create_shader_module_wgsl(wgsl + Materials[*Self.Ms].wgsl(), "mesh")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value | WGPUShaderStage.FRAGMENT.value, UInt32(0),  # the fragment reads the eye (fog, sky)
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
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(8), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var layout = device.create_pipeline_layout(bgl, "mesh_layout")
        self.pipeline = _build_pipeline(
            device, shader, layout, color_format, depth_format, Self.Ms[0].BLEND, Self.Ms[0].CULL, Self.Ms[0].DEPTH_WRITE,
        )
        self.instances = device.create_buffer(
            UInt64(caps.mesh_instances * FLOATS_PER_INSTANCE * 4),
            WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="mesh_instances",
        )
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, res.camera.handle().raw, 0, UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), null_opaque(), textures.view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 2, null_opaque(), 0, UInt64(0), textures.main_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 3, null_opaque(), 0, UInt64(0), null_opaque(), res.shadow_view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 4, null_opaque(), 0, UInt64(0), res.shadow_sampler.handle().raw, null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 5, res.shadow_ubo.handle().raw, 0, UInt64(128), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 6, res.ao_cells.handle().raw, 0, UInt64(AO_MAX_CELLS * 4), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 7, res.ao_ubo.handle().raw, 0, UInt64(48), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), 8, res.lights.handle().raw, 0, UInt64(LIGHTS_BYTES), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "mesh_group")
        self.staging = List[Float32]()
        self.batches = MeshBatches[False]()

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(device, color_format, depth_format, textures, res, caps)

    def prepare(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        """Everything that can fail, done before the render pass opens: sync the meshes' GPU copies, group the mesh
        items by mesh, write the instance records. record() then only sets state and draws. The camera header is
        written by the renderer (RenderResources.write_camera)."""
        gpu.sync(device, registry)
        self.batches = MeshBatches[False](items)
        if self.batches.total > self.max_instances:
            raise Error("mesh pass: " + String(self.batches.total) + " instances, more than its capacity " + String(self.max_instances))
        # instances grouped by mesh, in group order
        var floats = List[Float32]()
        for i in self.batches.members:
            var rec = len(floats)
            model_floats(items[i], floats)
            floats[rec + 21] = Float32(items[i].material)  # info.y: material
            floats[rec + 22] = Float32(items[i].layer) if items[i].material > 0 else 0.0  # info.z: the texture layer
        if self.batches.total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)

    def record_color(self, mut rpass: FrameRenderPass, registry: MeshRegistry, gpu: GpuMeshCache):
        """Set state and draw the groups prepared by prepare(). Nothing here can fail: an invariant that prepare()
        guarantees is a debug_assert, not an error. Each bind passes its exact byte size: the wrapper's default size
        of 0 binds nothing, and WGPU_WHOLE_SIZE does not survive the web translation (setVertexBuffer rejects it)."""
        if len(self.batches.order) == 0:
            return
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.set_vertex_buffer(UInt32(3), self.instances, UInt64(0), UInt64(self.batches.total * FLOATS_PER_INSTANCE * 4))
        for k in range(len(self.batches.order)):
            var mid = self.batches.order[k]
            debug_assert(mid < gpu.uploaded(), "mesh pass: a mesh is drawn before its GPU copy exists")
            var vb = STATIC_BUFFERS * mid
            rpass.set_vertex_buffer(UInt32(0), gpu.vbufs[vb + S_POS], UInt64(0), UInt64(len(registry.meshes[mid].positions) * 4))
            rpass.set_vertex_buffer(UInt32(1), gpu.vbufs[vb + S_NRM], UInt64(0), UInt64(len(registry.meshes[mid].normals) * 4))
            rpass.set_vertex_buffer(UInt32(2), gpu.vbufs[vb + S_UV], UInt64(0), UInt64(len(registry.meshes[mid].uv) * 4))
            var n_idx = len(registry.meshes[mid].indices)
            rpass.set_index_buffer(gpu.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(n_idx * 4))
            rpass.draw_indexed(
                UInt32(n_idx), UInt32(self.batches.counts[k]), UInt32(0), Int32(0), UInt32(self.batches.base[k]),
            )


comptime MeshPass = MeshPassOf[MatColor, MatUv, MatTriplanar, MatSky, MatPbr]
"""The mesh pass with the built-in materials."""

def _build_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout,
    color_format: UInt32, depth_format: UInt32, blend: Int = BLEND_NONE, cull: Int = CULL_NONE, depth_write: Bool = True,
) raises -> RenderPipeline:
    """The mesh pipeline: vertex buffers 0-2 per vertex, 3 per instance, the arena's depth state; blend, cull and
    depth write as the pack's first material asks (app/material.mojo)."""
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
    var blend_p = raw_alloc[WGPUBlendState](1)
    blend_p[unsafe_offset=0] = blend_state(blend)
    target_p[unsafe_offset=0] = WGPUColorTargetState(
        null_opaque(), color_format, blend_p if blend != BLEND_NONE else null_ptr[WGPUBlendState](), UInt64(0xF),
    )
    var fragment_p = raw_alloc[WGPUFragmentState](1)
    fragment_p[unsafe_offset=0] = WGPUFragmentState(
        null_opaque(), shader.handle().raw, str_to_sv(fs_name),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(1), target_p,
    )
    var primitive = WGPUPrimitiveState(
        null_opaque(), 4, UInt32(0), UInt32(1), cull_mode(cull) if cull != CULL_NONE else UInt32(0), UInt32(0),
    )
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1) if depth_write else UInt32(0), UInt32(4), face, face,
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
    blend_p.unsafe_free()
    fragment_p.unsafe_free()
    dp.unsafe_free()
    return result^
