"""Draws the arena: boxes and spheres by vertex pulling, lit and coloured per instance, from a chase camera.

No depth buffer: wgpu-mojo's pass and pipeline helpers carry no depth attachment. Instead the floor is drawn first and every
other item is sorted far to near by its centre, with long axis-aligned boxes (the walls) cut into 2 m pieces so a centre is a
fair stand-in for a piece. `app/render.mojo` stays as it was: the parity gates compare its pixels.

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
from hud import Hud

comptime CLEAR = WGPUColor(0.55, 0.68, 0.85, 1.0)
comptime MAX_INSTANCES = 2048
comptime VERTS_PER_INSTANCE = 1152
comptime CHUNK = 2.0

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
    var buffer: Buffer
    var group: BindGroup
    var staging: List[Float32]
    var view: View
    var floor: List[DrawItem]
    var items: List[DrawItem]

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
            shader, "vs_main", "fs_main", color_format, layout, primitive_topology=UInt32(4)
        )
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

    def __init__(out self, *, deinit move: Self):
        self.pipeline = move.pipeline^
        self.buffer = move.buffer^
        self.group = move.group^
        self.staging = move.staging^
        self.view = move.view^
        self.floor = move.floor^
        self.items = move.items^

    def begin(mut self, view: View):
        self.view = view.copy()
        self.floor.clear()
        self.items.clear()

    def push(mut self, it: DrawItem):
        """One item. The floor goes first; an axis-aligned box longer than a chunk is cut into pieces."""
        var big = it.kind == 0 and it.half[0] >= 10.0 and it.half[2] >= 10.0 and it.half[1] <= 0.6
        if big:
            self.floor.append(it.copy())
            return
        var upright = it.kind == 0 and abs(it.qx) < 1e-4 and abs(it.qy) < 1e-4 and abs(it.qz) < 1e-4
        var nx = 1
        var nz = 1
        if upright:
            nx = Int(it.half[0] / (CHUNK * 0.5)) + 1 if it.half[0] > CHUNK * 0.5 else 1
            nz = Int(it.half[2] / (CHUNK * 0.5)) + 1 if it.half[2] > CHUNK * 0.5 else 1
        if nx == 1 and nz == 1:
            self.items.append(it.copy())
            return
        var hx = it.half[0] / Real(nx)
        var hz = it.half[2] / Real(nz)
        for i in range(nx):
            for k in range(nz):
                var off = Vec3(-it.half[0] + hx * Real(2 * i + 1), 0.0, -it.half[2] + hz * Real(2 * k + 1), 0.0)
                self.items.append(DrawItem(it.kind, it.pos + off, it.qx, it.qy, it.qz, it.qw, Vec3(hx, it.half[1], hz, 0.0), it.color))

    def _sort(self) -> List[Int]:
        """Item indices, farthest first (insertion sort: a few hundred items)."""
        var order = List[Int]()
        var key = List[Real]()
        for i in range(len(self.items)):
            var d = self.items[i].pos - self.view.eye
            var k = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
            var j = len(order)
            order.append(i)
            key.append(k)
            while j > 0 and key[j - 1] < k:
                key[j] = key[j - 1]
                order[j] = order[j - 1]
                j -= 1
            key[j] = k
            order[j] = i
        return order^

    def draw(mut self, device: Device, target: WGPUTextureHandle, hud: Hud) raises:
        var v = self.view.copy()
        self.staging.clear()
        for e in [v.eye, v.right, v.up, v.fwd]:
            for c in range(3):
                self.staging.append(Float32(e[c]))
            self.staging.append(0.0)
        self.staging[3] = Float32(v.sx)
        self.staging[7] = Float32(v.sy)
        self.staging[11] = Float32(v.near)
        self.staging[15] = Float32(v.far)
        var count = len(self.floor) + len(self.items)
        if count > MAX_INSTANCES:
            count = MAX_INSTANCES
        for _ in range(4):
            self.staging.append(0.0)
        self.staging[16] = Float32(count)
        var n = 0
        for i in range(len(self.floor)):
            if n < MAX_INSTANCES:
                _put(self.staging, self.floor[i])
                n += 1
        var order = self._sort()
        for k in range(len(order)):
            if n < MAX_INSTANCES:
                _put(self.staging, self.items[order[k]])
                n += 1
        device.queue_write_data(self.buffer, UInt64(0), self.staging)
        hud.upload(device)
        var enc = device.create_command_encoder("frame")
        var rpass = enc.begin_surface_clear_pass(target, CLEAR, "frame_pass")
        rpass.set_pipeline(self.pipeline)
        rpass.set_bind_group(UInt32(0), self.group)
        rpass.draw(UInt32(VERTS_PER_INSTANCE), UInt32(count), UInt32(0), UInt32(0))
        hud.record(rpass)
        rpass^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
