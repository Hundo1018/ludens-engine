"""Three pipelines of this engine's own: each shows something the engine has that a picture does not usually show.

  screw_axes         motion as motors. Between two frames every body's displacement is one motor; its logarithm is a
                     line in space (app/screw.mojo). `ScrewAxisPass` draws that line for each moving body, and the
                     body's centre carried back along the same screw.
  state_fingerprint  bit-exact state. `FingerprintPass` colours each body by a hash of the bits of its pose, and the
                     stage draws the frame's 64-bit hash as a row of cells: two runs agree exactly or visibly do not.
  geometric_product  the algebra the engine's maths is built on. The product of the surface normal and the light
                     direction, n l = n . l + n ^ l: the scalar part is the usual diffuse term; the bivector part,
                     normally thrown away, is the plane the light was turned in. `MatGeometricProduct` shows both.

None follows an existing look. Each is one more type in a list: a pass (app/render_pass.mojo), a material
(app/material.mojo) or a stage (app/post.mojo).
"""
from std.math import sqrt
from wgpu.device import Device
from wgpu.render_pass import FrameRenderPass
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.camera_view import View
from geometry.motor import Motor3
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache
from app.render_res import RenderResources, RenderCaps
from app.render_pass import RenderPass
from app.primitive_pass import PrimitivePass
from app.textures import TextureArray
from app.material import Material
from app.post import Style
from app.screw import Screw, screw_of, screw_pow, foot_on_axis


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, Real(0))


def _motor(it: DrawItem) -> Motor3:
    return Motor3.from_quat_translation(Quat(Real(it.qx), Real(it.qy), Real(it.qz), Real(it.qw)), it.pos)


def _along_y(u: Vec3) -> Quat:
    """The rotation that takes the y axis to the unit vector u."""
    var w = Real(1) + u[1]
    if w < Real(1e-6):
        return Quat(1, 0, 0, 0)
    var n = sqrt(u[2] * u[2] + u[0] * u[0] + w * w)
    return Quat(u[2] / n, 0, -u[0] / n, w / n)


def item_screw(prev: DrawItem, now: DrawItem) -> Screw:
    """The screw that carries a body from its previous pose to its present one: log(M_now * reverse(M_prev))."""
    return screw_of(_motor(now) * _motor(prev).reverse())


struct ScrewAxisPass(RenderPass):
    """For each item that moved since the last frame (matched by its place in the list): a bar along the axis of its
    screw, 4 m long, centred on the axis point nearest the body, and five beads at the body's centre carried 1 to 5
    steps back along the screw. A pure turn's bar is cyan and shades to magenta as the slide along the axis grows; a
    pure translation (axis at infinity) is a yellow bar through the body along its direction."""

    comptime SHADOW: Bool = False
    var inner: PrimitivePass
    var prev: List[DrawItem]
    var marks: List[DrawItem]

    def __init__(out self, var inner: PrimitivePass):
        self.inner = inner^
        self.prev = List[DrawItem]()
        self.marks = List[DrawItem]()

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(PrimitivePass.create(device, color_format, depth_format, textures, res, caps))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.marks.clear()
        for i in range(min(len(items), len(self.prev))):
            if items[i].material == MAT_SKY:
                continue
            var s = item_screw(self.prev[i], items[i])
            if not s.turns and s.slide < Real(1e-5):
                continue
            var at = foot_on_axis(s, items[i].pos) if s.turns else items[i].pos
            var q = _along_y(s.dir)
            var k = abs(s.slide) / (abs(s.slide) + s.angle) if s.turns else Real(1)
            # 2.5 times a full colour: the primitive pass's light term is 0.4 .. 1.0, so the marks stay saturated in shade
            var col = _v(0.25 + 2.25 * k, 2.25 - 1.9 * k, 2.5) if s.turns else _v(2.5, 2.1, 0.25)
            self.marks.append(DrawItem(0, at, Float64(q.x), Float64(q.y), Float64(q.z), Float64(q.w), _v(0.045, 2.0, 0.045), col))
            for b in range(1, 6):
                var p = screw_pow(s, Real(-b)).apply_point(items[i].pos)
                self.marks.append(DrawItem(1, p, 0.0, 0.0, 0.0, 1.0, _v(0.14 - 0.018 * Real(b), 0, 0), col))
        self.prev.clear()
        for i in range(len(items)):
            self.prev.append(items[i].copy())
        self.inner.prepare(device, self.marks, meshes, gpu, palette, view, res)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.inner.record_color(rpass, meshes, gpu)


struct ScrewLook(Style):
    """The stage of screw_axes: the scene is pulled back to a dim, nearly grey ground so the axes and beads, which
    are the only saturated things, read first; a thin dark outline keeps the bodies legible."""

    comptime NAME: StaticString = "screw_axes"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let hsv = rgb2hsv(c);
  let mark = smoothstep(0.62, 0.8, hsv.y) * step(0.5, hsv.z);
  let ground = mix(vec3<f32>(luma(c)), c, 0.3) * 0.5 + vec3<f32>(0.02, 0.03, 0.05);
  var o = mix(ground, c * 1.25, mark);
  var halo = vec3<f32>(0.0);
  for (var i = 0; i < 12; i++) {
    let a = f32(i) * 2.39996;
    let s = src_at(uv + vec2<f32>(cos(a), sin(a)) * sqrt(f32(i) + 0.5) * 2.2 * frame.res.zw);
    let h = rgb2hsv(s);
    halo += s * smoothstep(0.62, 0.8, h.y) * step(0.5, h.z);
  }
  o += halo / 12.0 * 0.5;
  return mix(o, vec3<f32>(0.0), 0.6 * step(0.4, edge(uv, 1.0)) * (1.0 - mark));
}
"""


def item_hash(it: DrawItem) -> UInt64:
    """FNV-1a over the bits of the item's position, rotation and extents."""
    var h = UInt64(0xCBF29CE484222325)
    for k in range(3):
        h = (h ^ UInt64(it.pos[k].to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(it.half[k].to_bits())) * UInt64(0x100000001B3)
    for q in [it.qx, it.qy, it.qz, it.qw]:
        h = (h ^ UInt64(q.to_bits())) * UInt64(0x100000001B3)
    return h


def frame_hash(items: List[DrawItem]) -> UInt64:
    """The hash of a frame: the item hashes folded in list order (the sky excluded, as in FingerprintPass)."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(items)):
        if items[i].material != MAT_SKY:
            h = (h ^ item_hash(items[i])) * UInt64(0x100000001B3)
    return h


def hash_user(h: UInt64) -> SIMD[DType.float32, 4]:
    """A 64-bit hash as four 16-bit numbers, for ArenaRendererOf.post_user (the cells FingerprintLook draws)."""
    return SIMD[DType.float32, 4](
        Float32(Int(h & 0xFFFF)), Float32(Int((h >> 16) & 0xFFFF)), Float32(Int((h >> 32) & 0xFFFF)), Float32(Int((h >> 48) & 0xFFFF)),
    )


def hash_color(h: UInt64) -> Vec3:
    """A saturated colour from 32 bits of a hash: hue from 16 bits, saturation and value from 8 each."""
    var hue = Real(Int(h & 0xFFFF)) / Real(65536.0) * Real(6.0)
    var sat = Real(0.55) + Real(0.45) * Real(Int((h >> 16) & 0xFF)) / Real(255.0)
    var val = Real(0.65) + Real(0.35) * Real(Int((h >> 24) & 0xFF)) / Real(255.0)
    var i = Int(hue)
    var f = hue - Real(i)
    var p = val * (Real(1) - sat)
    var q = val * (Real(1) - sat * f)
    var t = val * (Real(1) - sat * (Real(1) - f))
    if i == 0:
        return _v(val, t, p)
    if i == 1:
        return _v(q, val, p)
    if i == 2:
        return _v(p, val, t)
    if i == 3:
        return _v(p, q, val)
    if i == 4:
        return _v(t, p, val)
    return _v(val, p, q)


struct FingerprintPass(RenderPass):
    """Draws every item except the sky as a primitive (a box, or a sphere for kind 1; an item on the unit cube or
    sphere mesh keeps its size) in the colour of `item_hash`. The colour depends on every bit of the pose, so a body
    whose state differs by one unit in the last place from another run's has another colour."""

    comptime SHADOW: Bool = False
    var inner: PrimitivePass
    var marks: List[DrawItem]

    def __init__(out self, var inner: PrimitivePass):
        self.inner = inner^
        self.marks = List[DrawItem]()

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(PrimitivePass.create(device, color_format, depth_format, textures, res, caps))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.marks.clear()
        for i in range(len(items)):
            if items[i].material == MAT_SKY:
                continue
            var half = items[i].half * Real(0.5) if items[i].mesh_id >= 0 else items[i].half
            self.marks.append(DrawItem(
                items[i].kind, items[i].pos, items[i].qx, items[i].qy, items[i].qz, items[i].qw, half,
                hash_color(item_hash(items[i])),
            ))
        self.inner.prepare(device, self.marks, meshes, gpu, palette, view, res)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.inner.record_color(rpass, meshes, gpu)


struct FingerprintLook(Style):
    """The stage of state_fingerprint: the hashed colours over a dark ground with an outline, and along the bottom
    the frame's hash as 64 cells, one per bit (Frame.user, four 16-bit numbers, bit 0 at the left)."""

    comptime NAME: StaticString = "state_fingerprint"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var o = src_at(uv);
  if is_far(uv, 400.0) > 0.5 { o = vec3<f32>(0.055, 0.06, 0.075) + 0.02 * step(fract(px.y / 4.0), 0.25); }
  o = mix(o, vec3<f32>(0.0), step(0.4, edge(uv, 1.2)));
  if uv.y > 0.925 {
    let i = u32(clamp(uv.x, 0.0, 0.9999) * 64.0);
    let word = u32(frame.user[i / 16u]);
    let bit = f32((word >> (i % 16u)) & 1u);
    let f = fract(uv.x * 64.0);
    let cell = step(0.12, f) * step(f, 0.88) * step(0.94, uv.y) * step(uv.y, 0.985);
    o = mix(vec3<f32>(0.02), mix(vec3<f32>(0.16), vec3<f32>(0.95, 0.97, 1.0), bit), cell);
  }
  return o;
}
"""


struct MatGeometricProduct(Material):
    """The geometric product of the unit normal n and the unit light direction l, both parts:
      n . l (scalar)    how much the surface faces the light: the grey level, with the shadow map
      n ^ l (bivector)  the plane that turns n into l, shown by its dual vector as a colour (x, y, z -> r, g, b about
                        mid grey), as strong as the bivector is large (the sine of the angle)
    A face square to the light is white, a grazing one is the pure colour of its plane, one turned away keeps a dim
    colour: the plane is still defined where the scalar part has gone negative. A dark line marks every 15 degrees of
    the angle between n and l (the angle of the rotor that takes one to the other): rings about the light's direction
    on a sphere, none on a flat face."""

    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let l = normalize(vec3<f32>(0.4, 1.0, 0.6));
  let scalar = dot(n, l);
  let biv = cross(n, l);
  let size = length(biv);
  let plane = 0.5 + 0.5 * biv / max(size, 1e-4);
  let lit = max(scalar, 0.0) * s.sf;
  let c = vec3<f32>(lit * lit) + plane * size * (0.3 + 0.7 * step(0.0, scalar) * (0.4 + 0.6 * s.sf));
  let turn = acos(clamp(scalar, -1.0, 1.0));
  let iso = step(abs(fract(turn / 0.261799 + 0.5) - 0.5) * 0.261799, 0.011) * step(0.02, size);
  return vec4<f32>(mix(c, vec3<f32>(0.03, 0.03, 0.06), 0.75 * iso), 1.0);"""


struct MatVoid(Material):
    """The background of geometric_product: nothing to multiply."""

    comptime ID: Int = MAT_SKY
    comptime BODY: StaticString = """
  return vec4<f32>(0.045, 0.045, 0.06, 1.0);"""


struct ProductKey(Style):
    """The stage of geometric_product: an outline, and in the corner the key to the colours: a sphere shaded by the
    same product (its normals cover every direction that faces the camera), as a map carries its legend."""

    comptime NAME: StaticString = "geometric_product"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var o = mix(src_at(uv), vec3<f32>(0.0), step(0.4, edge(uv, 1.0)));
  let r = frame.res.y * 0.11;
  let q = (px - vec2<f32>(frame.res.x - r * 1.35, frame.res.y - r * 1.35)) / r;
  let d = dot(q, q);
  if d < 1.12 { o = vec3<f32>(0.02, 0.02, 0.04); }
  if d < 1.0 {
    let n = normalize(frame.right.xyz * q.x - frame.up.xyz * q.y - frame.fwd.xyz * sqrt(1.0 - d));
    let scalar = dot(n, SUN);
    let biv = cross(n, SUN);
    let size = length(biv);
    let lit = max(scalar, 0.0);
    o = vec3<f32>(lit * lit) + (0.5 + 0.5 * biv / max(size, 1e-4)) * size * (0.3 + 0.7 * step(0.0, scalar));
    let turn = acos(clamp(scalar, -1.0, 1.0));
    o = mix(o, vec3<f32>(0.03, 0.03, 0.06), 0.75 * step(abs(fract(turn / 0.261799 + 0.5) - 0.5) * 0.261799, 0.02));
  }
  return o;
}
"""
