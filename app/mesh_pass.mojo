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

comptime MAX_MESH_INSTANCES = 2048
comptime FLOATS_PER_INSTANCE = 24
comptime MESH_WGSL = """
struct Cam { eye : vec4<f32>, right : vec4<f32>, up : vec4<f32>, fwd : vec4<f32> };
@group(0) @binding(0) var<uniform> cam : Cam;

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
struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec3<f32> };

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
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  return vec4<f32>(in.color, 1.0);
}
"""


@fieldwise_init
struct MeshData(Copyable, Movable):
    """One static mesh on the CPU: positions, normals, uv and a triangle index list."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var indices: List[UInt32]


struct MeshRegistry(Movable):
    """The meshes a game registers, by id. The ids are the mesh_id values draw items carry."""

    var meshes: List[MeshData]

    def __init__(out self):
        self.meshes = List[MeshData]()

    def add_static(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """Check the arrays at the boundary (an invalid mesh raises), then keep it. Returns its id."""
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


def add_unit_cube(mut registry: MeshRegistry) raises -> Int:
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
    return registry.add_static(pos^, nrm^, uv^, idx^)


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


def _model_floats(it: DrawItem, mut out: List[Float32]):
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

    def __init__(out self, device: Device, color_format: UInt32, depth_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(MESH_WGSL, "mesh")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
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
            WGPUBindGroupEntry(null_opaque(), 0, self.camera.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "mesh_group")
        self.staging = List[Float32]()
        self.vbufs = List[Buffer]()
        self.ibufs = List[Buffer]()
        self.uploaded = 0
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()

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
            if it.mesh_id < 0:
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
                if it.mesh_id == self.order[k]:
                    _model_floats(it, floats)
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
