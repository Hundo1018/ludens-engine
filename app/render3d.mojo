"""Draws the arena: boxes and spheres by vertex pulling, lit and coloured per instance, from a chase camera.

A Depth32Float buffer does the hidden-surface work (wgpu-mojo's `create_render_pipeline(depth_format=)` and
`begin_surface_clear_pass_depth`). `app/render.mojo` stays as it was: the parity gates compare its pixels.

Buffer layout (vec4<f32> elements): [0] eye.xyz + sx, [1] right.xyz + sy, [2] up.xyz + near, [3] fwd.xyz + far, [4] (count);
instance i is four elements at 5 + 4 i: position + kind (0 box, 1 sphere), rotation xyzw, half extents, colour.
1152 vertices per instance (a 16 x 12 sphere); a box uses the first 36 and collapses the rest."""
from game.arena import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.structs import WGPUColor
from wgpu._ffi.types import WGPUTextureHandle
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.texture import Texture, TextureView
from hud import Hud
from app.mesh_pass import MeshPass, MeshRegistry, add_unit_cube, unit_cube_arrays
from app.skin_draw import SkinnedPass
from app.skin_pass import build_palette, rot_y
from geometry.mat import Mat4

comptime DEPTH_FORMAT = WGPUTextureFormat.Depth32Float
comptime CLEAR = WGPUColor(0.55, 0.68, 0.85, 1.0)
comptime MAX_INSTANCES = 2048
comptime VERTS_PER_INSTANCE = 1152


comptime WGSL = """
@group(0) @binding(0) var<storage, read> data : array<vec4<f32>>;

struct VOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec3<f32> };

const NORMAL = array<vec3<f32>, 6>(
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(-1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, -1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, -1.0));
const TAN1 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0),
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0));
const TAN2 = array<vec3<f32>, 6>(
  vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 0.0, 1.0),
  vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(1.0, 0.0, 0.0),
  vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 1.0, 0.0));
const QUAD = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
const PI = 3.14159265;

fn rotate(q : vec4<f32>, v : vec3<f32>) -> vec3<f32> {
  let t = 2.0 * cross(q.xyz, v);
  return v + q.w * t + cross(q.xyz, t);
}

@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VOut {
  let b = 5u + ii * 4u;
  let p = data[b].xyz;
  let kind = data[b].w;
  let q = data[b + 1u];
  let h = data[b + 2u].xyz;
  let base = data[b + 3u].xyz;
  var local = vec3<f32>(0.0);
  var normal = vec3<f32>(0.0, 1.0, 0.0);
  var live = true;
  if (kind < 0.5) {
    if (vi >= 36u) { live = false; }
    let face = (vi / 6u) % 6u;
    let k = QUAD[vi % 6u];
    local = (NORMAL[face] + (f32(k & 1u) * 2.0 - 1.0) * TAN1[face] + (f32(k >> 1u) * 2.0 - 1.0) * TAN2[face]) * h;
    normal = rotate(q, NORMAL[face]);
  } else {
    let quad = vi / 6u;
    let k = QUAD[vi % 6u];
    let seg = quad % 16u;
    let ring = quad / 16u;
    let a = f32(seg + (k & 1u)) / 16.0 * 2.0 * PI;
    let t = f32(ring + (k >> 1u)) / 12.0 * PI;
    let u = vec3<f32>(sin(t) * cos(a), cos(t), sin(t) * sin(a));
    local = u * h.x;
    normal = u;
  }
  let world = p + rotate(q, local);
  let eye = data[0].xyz;
  let d = world - eye;
  let x = dot(d, data[1].xyz);
  let y = dot(d, data[2].xyz);
  let z = dot(d, data[3].xyz);
  let near = data[2].w;
  let far = data[3].w;
  var out : VOut;
  if (live) {
    out.pos = vec4<f32>(x * data[0].w, y * data[1].w, far * (z - near) / (far - near), z);
  } else {
    out.pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
  }
  let lit = 0.4 + 0.6 * max(dot(normal, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0);
  out.color = base * lit;
  return out;
}

@fragment
fn fs_main(in : VOut) -> @location(0) vec4<f32> {
  return vec4<f32>(in.color, 1.0);
}
"""


def _put(mut staging: List[Float32], it: DrawItem):
    for v in [it.pos[0], it.pos[1], it.pos[2], Real(it.kind)]:
        staging.append(Float32(v))
    for v in [it.qx, it.qy, it.qz, it.qw]:
        staging.append(Float32(v))
    for v in [it.half[0], it.half[1], it.half[2], Real(0)]:
        staging.append(Float32(v))
    for v in [it.color[0], it.color[1], it.color[2], Real(0)]:
        staging.append(Float32(v))


struct ArenaRenderer(Movable):
    var pipeline: RenderPipeline
    var mesh: MeshPass
    var meshes: MeshRegistry
    var cube: Int  # the unit cube's mesh id, for the centre probe
    var probe: Int  # 0 off; 1 a rigid cube at the view's centre; 2 / 3 a skinned cube at the centre, identity / joint turned 20 deg
    var skin: SkinnedPass
    var skin_palette: List[Float32]
    var skin_ident: Int  # skinned mesh ids
    var skin_turn: Int
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var view: View
    var floor: List[DrawItem]
    var items: List[DrawItem]
    var depth: Optional[Texture]
    var depth_view: Optional[TextureView]
    var depth_w: UInt32
    var depth_h: UInt32

    def __init__(out self, device: Device, color_format: UInt32, view: View) raises:
        var shader = device.create_shader_module_wgsl(WGSL, "arena")
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
        var layout = device.create_pipeline_layout(bgl, "arena_layout")
        self.pipeline = device.create_render_pipeline(
            shader, "vs_main", "fs_main", color_format, layout, depth_format=DEPTH_FORMAT
        )
        self.mesh = MeshPass(device, color_format, DEPTH_FORMAT)
        self.meshes = MeshRegistry()
        self.cube = add_unit_cube(self.meshes)
        self.probe = 0
        self.skin = SkinnedPass(device, color_format, DEPTH_FORMAT)
        var c = unit_cube_arrays()
        var nv = len(c[0]) // 3
        var jt_id = List[UInt16]()
        var jt_turn = List[UInt16]()
        var wt = List[Float32]()
        for _ in range(nv):
            for j in range(4):
                jt_id.append(0)
                jt_turn.append(1)
                wt.append(Float32(1.0) if j == 0 else Float32(0.0))
        self.skin_ident = self.meshes.add_skinned(c[0].copy(), c[1].copy(), c[2].copy(), jt_id^, wt.copy(), c[3].copy())
        self.skin_turn = self.meshes.add_skinned(c[0].copy(), c[1].copy(), c[2].copy(), jt_turn^, wt^, c[3].copy())
        var pal_locals = List[Mat4]()
        pal_locals.append(Mat4.identity())
        pal_locals.append(rot_y(20.0))
        var pal_parents = List[Int]()
        pal_parents.append(-1)
        pal_parents.append(0)
        var pal_ibm = List[Mat4]()
        pal_ibm.append(Mat4.identity())
        pal_ibm.append(Mat4.identity())
        self.skin_palette = build_palette(pal_locals, pal_parents, pal_ibm)
        var bytes = UInt64((5 + 4 * MAX_INSTANCES) * 16)
        self.buffer = device.create_buffer(bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="arena")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, self.buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "arena_group")
        self.staging = List[Float32]()
        self.view = view.copy()
        self.floor = List[DrawItem]()
        self.items = List[DrawItem]()
        self.depth = None
        self.depth_view = None
        self.depth_w = 0
        self.depth_h = 0

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.mesh = move.mesh^
        self.meshes = move.meshes^
        self.cube = move.cube
        self.probe = move.probe
        self.skin = move.skin^
        self.skin_palette = move.skin_palette^
        self.skin_ident = move.skin_ident
        self.skin_turn = move.skin_turn
        self.buffer = move.buffer^
        self.group = move.group^
        self.staging = move.staging^
        self.view = move.view^
        self.floor = move.floor^
        self.items = move.items^
        self.depth = move.depth^
        self.depth_view = move.depth_view^
        self.depth_w = move.depth_w
        self.depth_h = move.depth_h

    def begin(mut self, view: View):
        self.view = view.copy()
        self.floor.clear()
        self.items.clear()

    def push(mut self, it: DrawItem):
        """One item; the depth buffer sorts them out."""
        self.items.append(it.copy())

    def _depth_view(mut self, device: Device, width: UInt32, height: UInt32) raises:
        if not self.depth_view or self.depth_w != width or self.depth_h != height:
            self.depth_view = None
            self.depth = device.create_texture(
                width, height, 1, DEPTH_FORMAT, WGPUTextureUsage.RENDER_ATTACHMENT, label="arena_depth",
            )
            self.depth_view = self.depth.value().create_view_default()
            self.depth_w = width
            self.depth_h = height

    def draw(mut self, device: Device, target: WGPUTextureHandle, width: UInt32, height: UInt32, hud: Hud) raises:
        var v = self.view.copy()
        # the centre of the view: 4 units ahead, unit-sized, colour (0.8, 0.2, 0.2)
        var t = Real(4.0)
        var at = Vec3(v.eye[0] + v.fwd[0] * t, v.eye[1] + v.fwd[1] * t, v.eye[2] + v.fwd[2] * t, Real(0.0))
        if self.probe == 2 or self.probe == 3:
            self.items.append(DrawItem(
                -1, at, 0.0, 0.0, 0.0, 1.0,
                Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.8), Real(0.2), Real(0.2), Real(0.0)),
                self.skin_ident if self.probe == 2 else self.skin_turn, 0, 0,
            ))
        if self.probe == 1:
            self.items.append(
                DrawItem(-1, at, 0.0, 0.0, 0.0, 1.0, Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)),
                         Vec3(Real(0.8), Real(0.2), Real(0.2), Real(0.0)), self.cube, -1, 0)
            )
        self.staging.clear()
        for e in [v.eye, v.right, v.up, v.fwd]:
            for c in range(3):
                self.staging.append(Float32(e[c]))
            self.staging.append(0.0)
        self.staging[3] = Float32(v.sx)
        self.staging[7] = Float32(v.sy)
        self.staging[11] = Float32(v.near)
        self.staging[15] = Float32(v.far)
        # primitives only: items with a mesh (mesh_id >= 0) are drawn by the mesh pass, once
        var count = 0
        for i in range(len(self.items)):
            if self.items[i].mesh_id >= 0 or count >= MAX_INSTANCES:
                continue
            count += 1
        for _ in range(4):
            self.staging.append(0.0)
        self.staging[16] = Float32(count)
        var put = 0
        for i in range(len(self.items)):
            if self.items[i].mesh_id >= 0 or put >= count:
                continue
            _put(self.staging, self.items[i])
            put += 1
        device.queue_write_data(self.buffer, UInt64(0), self.staging)
        hud.upload(device)
        self._depth_view(device, width, height)
        self.mesh.prepare(device, self.items, self.meshes, v)
        self.skin.prepare(device, self.items, self.meshes, self.skin_palette, v)
        var enc = device.create_command_encoder("frame")
        var rpass = enc.begin_surface_clear_pass_depth(target, self.depth_view.value(), CLEAR, 1.0, "arena_pass")
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.draw(UInt32(VERTS_PER_INSTANCE), UInt32(count), UInt32(0), UInt32(0))
        self.mesh.record(rpass, self.meshes)
        self.skin.record(rpass, self.meshes)
        hud.record(rpass)
        rpass^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
