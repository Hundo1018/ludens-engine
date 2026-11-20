"""An environment captured from the scene: a cube map for MatPbr's reflections and its irradiance for the ambient.

    var probe = EnvProbe(device, format)
    for face in range(6):
        r.begin(probe.view(position, face))
        ...push the items (without what stands at the probe's position)...
        r.draw(device, probe.target(), ENV_SIZE, ENV_SIZE, empty_hud)
        probe.store(device, r.res, face)
    probe.finish(device, r.res)          # mips, the harmonics, and the renderer starts reflecting the cube map

Each face is one ordinary draw of the renderer (any pipeline), 128 x 128, 90 degrees across. `store` copies it into the
cube map and reads it back for the harmonics; `finish` fills the mips (each the mean of four texels of the one above),
sets the environment from the six faces (RenderResources.set_environment) and turns the cube map on. Capture again
when the surroundings change; nothing recaptures on its own.

The cube map is looked up by direction: a reflection is right for a surface at the probe's position and shifts for
surfaces away from it. What is at the probe's position while capturing hides the room, so leave it out.
"""
from std.math import sqrt, pi
from wgpu import (
    WGPUShaderStage, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
)
from wgpu import null_opaque
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu import WGPUColor
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroupLayout
from wgpu.sampler import Sampler
from wgpu.texture import Texture, TextureView
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from app.render_res import RenderResources, ENV_SIZE, ENV_MIPS, env_sub_view
from app.lights import Environment, sh_basis

comptime BLIT_WGSL = """
@group(0) @binding(0) var src : texture_2d<f32>;
@group(0) @binding(1) var lin : sampler;
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) pos : vec4<f32>) -> @location(0) vec4<f32> {
  // the target is the source's size (a face) or half of it (a mip): TARGET is its width over the source's
  let uv = pos.xy / (vec2<f32>(textureDimensions(src)) * TARGET);
  return vec4<f32>(textureSampleLevel(src, lin, uv, 0.0).rgb, 1.0);
}
"""


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0))


def face_axes(face: Int) -> Tuple[Vec3, Vec3, Vec3]:
    """(forward, right, up) of cube face 0 .. 5 (+x, -x, +y, -y, +z, -z) as a cube map stores it: `right` is the
    direction of increasing u and `up` the direction of the image's top row."""
    if face == 0:
        return (_v(1, 0, 0), _v(0, 0, -1), _v(0, 1, 0))
    if face == 1:
        return (_v(-1, 0, 0), _v(0, 0, 1), _v(0, 1, 0))
    if face == 2:
        return (_v(0, 1, 0), _v(1, 0, 0), _v(0, 0, -1))
    if face == 3:
        return (_v(0, -1, 0), _v(1, 0, 0), _v(0, 0, 1))
    if face == 4:
        return (_v(0, 0, 1), _v(1, 0, 0), _v(0, 1, 0))
    return (_v(0, 0, -1), _v(-1, 0, 0), _v(0, 1, 0))


def cube_environment(faces: List[List[UInt8]], size: Int, linear: Bool) raises -> Environment:
    """The environment of six cube faces (RGBA8 rows from the top, size x size each, in face order): the harmonics by
    each texel's solid angle, and the mean colours of the top face, the four sides and the bottom face. With `linear`
    the pixels are display values of the linear workflow and are raised to 2.2 first."""
    if len(faces) != 6:
        raise Error("env probe: six faces")
    var sh = List[Float64](length=27, fill=0.0)
    var mean = List[Float64](length=18, fill=0.0)
    var total = 0.0
    for f in range(6):
        if len(faces[f]) != size * size * 4:
            raise Error("env probe: a face is size * size RGBA8 pixels")
        var ax = face_axes(f)
        for y in range(size):
            var sy = 1.0 - 2.0 * (Float64(y) + 0.5) / Float64(size)
            for x in range(size):
                var sx = 2.0 * (Float64(x) + 0.5) / Float64(size) - 1.0
                var l2 = 1.0 + sx * sx + sy * sy
                var l = sqrt(l2)
                var dw = (2.0 / Float64(size)) * (2.0 / Float64(size)) / (l2 * l)
                total += dw
                var d = ax[0] + ax[1] * Real(sx) + ax[2] * Real(sy)
                var b = sh_basis(Float64(d[0]) / l, Float64(d[1]) / l, Float64(d[2]) / l)
                for c in range(3):
                    var v = Float64(Int(faces[f][(y * size + x) * 4 + c])) / 255.0
                    if linear:
                        v = v ** 2.2
                    mean[3 * f + c] += v / Float64(size * size)
                    for k in range(9):
                        sh[3 * k + c] += v * b[k] * dw
    var out = List[Float32]()
    for v in sh:
        out.append(Float32(v * 4.0 * pi / total))  # the texels' solid angles sum to 4 pi up to rounding
    var side = [0.0, 0.0, 0.0]
    for c in range(3):
        side[c] = (mean[c] + mean[3 + c] + mean[12 + c] + mean[15 + c]) * 0.25
    return Environment(out^, _v(mean[6], mean[7], mean[8]), _v(side[0], side[1], side[2]), _v(mean[9], mean[10], mean[11]))


struct EnvProbe(Movable):
    var face: Texture  # one face as the renderer draws it
    var face_view: TextureView
    var capture: FrameCapture
    var pixels: List[List[UInt8]]  # the six faces read back (store)
    var pipeline: RenderPipeline  # texture to texture at the same size: a face into the cube map
    var half_pipeline: RenderPipeline  # to half the size: a mip from the one above
    var layout: BindGroupLayout
    var sampler: Sampler
    var linear: Bool

    def __init__(out self, device: Device, color_format: UInt32, linear: Bool = False) raises:
        """`linear`: the renderer's atmosphere uses the linear workflow (set_atmosphere), so the faces hold display
        values."""
        self.face = device.create_texture(
            UInt32(ENV_SIZE), UInt32(ENV_SIZE), 1, color_format,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.COPY_SRC, label="env_face",
        )
        self.face_view = self.face.create_view_default()
        self.capture = FrameCapture(device, UInt32(ENV_SIZE), UInt32(ENV_SIZE))
        self.pixels = List[List[UInt8]]()
        for _ in range(6):
            self.pixels.append(List[UInt8]())
        var shader = device.create_shader_module_wgsl(String("const TARGET = 1.0;\n") + String(BLIT_WGSL), "env_blit")
        var half_shader = device.create_shader_module_wgsl(String("const TARGET = 0.5;\n") + String(BLIT_WGSL), "env_half")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(2), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "env_blit_layout")
        self.pipeline = device.create_render_pipeline(shader, "vs_main", "fs_main", WGPUTextureFormat.RGBA8Unorm, pl)
        var pl2 = device.create_pipeline_layout(self.layout, "env_half_layout")
        self.half_pipeline = device.create_render_pipeline(half_shader, "vs_main", "fs_main", WGPUTextureFormat.RGBA8Unorm, pl2)
        self.sampler = device.create_sampler(mag_filter=2, min_filter=2, label="env_linear")
        self.linear = linear

    def view(self, pos: Vec3, face: Int, near: Float64 = 0.1, far: Float64 = 500.0) -> View:
        """The view of cube face `face` from `pos`: 90 degrees across, with the cube map's orientation."""
        var ax = face_axes(face)
        var v = View(CameraPose(pos, look_rotation(ax[0], ax[2]), Real(pi / 2.0), Real(1.0), Real(near), Real(far)), Real(1.0))
        v.fwd = ax[0]
        v.right = ax[1]
        v.up = ax[2]
        v.sx = 1.0
        v.sy = 1.0
        return v^

    def target(self) -> WGPUTextureHandle:
        """The texture to draw a face into (ENV_SIZE x ENV_SIZE), then store()."""
        return self.face.handle().raw

    def _blit(self, device: Device, src: TextureView, var dst: TextureView, half: Bool = False) raises:
        var ge: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), 0, null_opaque(), 0, UInt64(0), null_opaque(), src.handle().raw),
            WGPUBindGroupEntry(null_opaque(), 1, null_opaque(), 0, UInt64(0), self.sampler.handle().raw, null_opaque()),
        ]
        var group = device.create_bind_group(self.layout, ge, "env_blit_group")
        var enc = device.create_command_encoder("env_blit")
        var rp = enc.begin_render_pass_clear(dst^, WGPUColor(0.0, 0.0, 0.0, 1.0), "env_blit")
        if half:
            rp.set_pipeline(self.half_pipeline)
        else:
            rp.set_pipeline(self.pipeline)
        rp.set_bind_group(UInt32(0), group)
        rp.draw(UInt32(3))
        rp^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)

    def store(mut self, device: Device, res: RenderResources, face: Int) raises:
        """Copy the face just drawn into the cube map and keep its pixels for the harmonics."""
        if face < 0 or face > 5:
            raise Error("env probe: faces are 0 .. 5")
        self._blit(device, self.face_view, env_sub_view(res.env_tex, 2, 0, 1, face, 1))
        var req = self.capture.capture(device, self.face.handle().raw)
        req.wait()
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(UInt32(ENV_SIZE)))
        var out = List[UInt8]()
        for y in range(ENV_SIZE):
            for x in range(ENV_SIZE * 4):
                out.append(p[unsafe_offset=y * pitch + x])
        self.capture.unmap()
        self.pixels[face] = out^

    def finish(mut self, device: Device, mut res: RenderResources) raises:
        """After six store() calls: the mips, the environment from the faces, and the cube map in use."""
        for f in range(6):
            if len(self.pixels[f]) != ENV_SIZE * ENV_SIZE * 4:
                raise Error("env probe: face " + String(f) + " was not stored")
            for m in range(1, ENV_MIPS):
                var src = env_sub_view(res.env_tex, 2, m - 1, 1, f, 1)
                self._blit(device, src, env_sub_view(res.env_tex, 2, m, 1, f, 1), True)
        res.set_environment(device, cube_environment(self.pixels, ENV_SIZE, self.linear))
        res.use_env_cube(device, True)
