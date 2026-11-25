"""Baked irradiance probes (#141): global illumination from a grid of order-2 spherical harmonics, captured from the
scene once and read by the mesh and skinned passes for their ambient light.

    var grid = ProbeGrid(origin, cell, 4, 2, 4)        # 32 probes, `cell` metres apart, from `origin`
    var sh = bake_probes(device, r, format, grid, items)  # 6 small renders per probe, read back
    r.set_probes(device, grid.origin, grid.cell, grid.nx, grid.ny, grid.nz, sh)

A probe is what EnvProbe (app/env_probe.mojo) captures, without the cube map: the renderer draws the six faces of a cube
around the probe's position (BAKE_FACE x BAKE_FACE pixels each, 90 degrees across), the faces are read back, and
`cube_environment` projects them onto the nine harmonics by each texel's solid angle. So a probe holds the light that
reaches its position from everything the renderer draws: the sky, the sun's light reflected by nearby surfaces, the
colour of a wall beside it. The renderer's own ambient at baking time is what the surfaces in the faces are lit with,
so a second bake with the first grid set adds a second bounce.

In the shaders (app/wgsl.mojo PROBES_WGSL) a surface point blends the irradiance of the eight probes around it by
trilinear weights and uses it where the environment's harmonics were used (`sh_lit`); outside the grid the nearest
probes are used. `probe_irradiance` below is the same arithmetic on the CPU. Primitives (items with no mesh) keep the
environment's ambient. Leakage: nothing stops a probe on one side of a thin wall from lighting the other side; place
the grid so that probes do not sit inside geometry, and keep walls at least one cell thick or split the grid.
"""
from std.math import pi
from wgpu import WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.texture import Texture
from game.draw_item import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf
from app.render_pass import RenderPass, AuxTarget
from app.post import PostEffect
from app.env_probe import face_axes, cube_environment
from app.lights import sh_basis
from app.render_res import MAX_PROBES

comptime BAKE_FACE = 32  # pixels across a captured face


struct ProbeGrid(Copyable, Movable):
    var origin: Vec3  # the position of probe (0, 0, 0)
    var cell: Vec3  # the spacing along x, y, z (m)
    var nx: Int
    var ny: Int
    var nz: Int

    def __init__(out self, origin: Vec3, cell: Vec3, nx: Int, ny: Int, nz: Int) raises:
        if nx < 1 or ny < 1 or nz < 1 or nx * ny * nz > MAX_PROBES:
            raise Error("probe grid: 1 .. " + String(MAX_PROBES) + " probes")
        for a in range(3):
            if not (Float64(cell[a]) > 0.0):
                raise Error("probe grid: the spacing is above 0 on every axis")
        self.origin = origin
        self.cell = cell
        self.nx = nx
        self.ny = ny
        self.nz = nz

    def count(self) -> Int:
        return self.nx * self.ny * self.nz

    def index(self, ix: Int, iy: Int, iz: Int) -> Int:
        return (iz * self.ny + iy) * self.nx + ix

    def position(self, i: Int) -> Vec3:
        var ix = i % self.nx
        var iy = (i // self.nx) % self.ny
        var iz = i // (self.nx * self.ny)
        return Vec3(
            self.origin[0] + self.cell[0] * Real(ix), self.origin[1] + self.cell[1] * Real(iy),
            self.origin[2] + self.cell[2] * Real(iz), Real(0),
        )


def face_view(pos: Vec3, face: Int, near: Float64 = 0.05, far: Float64 = 500.0) -> View:
    """The view of cube face `face` from `pos` (app/env_probe.mojo's orientation)."""
    var ax = face_axes(face)
    var v = View(CameraPose(pos, look_rotation(ax[0], ax[2]), Real(pi / 2.0), Real(1.0), Real(near), Real(far)), Real(1.0))
    v.fwd = ax[0]
    v.right = ax[1]
    v.up = ax[2]
    v.sx = 1.0
    v.sy = 1.0
    return v^


def bake_probes[P: RenderPass, F: PostEffect, A: AuxTarget](
    device: Device, mut r: SceneRendererOf[P, F, A], color_format: UInt32, grid: ProbeGrid, items: List[DrawItem],
    linear: Bool = False,
) raises -> List[Float32]:
    """The harmonics of every probe of the grid (27 floats each, the grid's order), from six renders of `items` around
    each probe. `linear`: the renderer's atmosphere uses the linear workflow (the faces hold display values). The
    renderer's view is restored afterwards; its targets are made again at the next frame's size."""
    var keep = r.view.copy()
    var target = device.create_texture(
        UInt32(BAKE_FACE), UInt32(BAKE_FACE), 1, color_format,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="probe_face",
    )
    var cap = FrameCapture(device, UInt32(BAKE_FACE), UInt32(BAKE_FACE))
    var hud = Hud(device, color_format)
    var dl = DrawList()
    hud.set(dl, Float32(BAKE_FACE), Float32(BAKE_FACE))
    var pitch = Int(padded_row_pitch(UInt32(BAKE_FACE)))
    var out = List[Float32]()
    for i in range(grid.count()):
        var p = grid.position(i)
        var faces = List[List[UInt8]]()
        for f in range(6):
            r.begin(face_view(p, f))
            for it in items:
                r.push(it.copy())
            r.draw(device, target.handle().raw, UInt32(BAKE_FACE), UInt32(BAKE_FACE), hud)
            var req = cap.capture(device, target.handle().raw)
            req.wait()
            var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
            var face = List[UInt8]()
            for y in range(BAKE_FACE):
                for x in range(BAKE_FACE * 4):
                    face.append(px[unsafe_offset=y * pitch + x])
            cap.unmap()
            faces.append(face^)
        var env = cube_environment(faces, BAKE_FACE, linear)
        for v in env.sh:
            out.append(v)
    r.view = keep^
    return out^


def _irr(sh: List[Float32], base: Int, n: Vec3) -> List[Float64]:
    """The shader's probe_irr: irradiance over pi of probe `base` (offset in floats) at unit normal n."""
    var x = Float64(n[0])
    var y = Float64(n[1])
    var z = Float64(n[2])
    var out = List[Float64]()
    for c in range(3):
        var k = List[Float64]()
        for i in range(9):
            k.append(Float64(sh[base + 3 * i + c]))
        var e = 0.429043 * k[8] * (x * x - y * y) + 0.743125 * k[6] * z * z + 0.886227 * k[0] - 0.247708 * k[6]
        e += 2.0 * 0.429043 * (k[4] * x * y + k[7] * x * z + k[5] * y * z)
        e += 2.0 * 0.511664 * (k[3] * x + k[1] * y + k[2] * z)
        out.append(max(e, 0.0) / pi)
    return out^


def probe_irradiance(grid: ProbeGrid, sh: List[Float32], pos: Vec3, n: Vec3) -> List[Float64]:
    """What a white matte surface at `pos` facing `n` reflects from the grid's ambient (rgb), as the shaders compute it:
    the eight probes around the point by trilinear weights, clamped to the grid."""
    var dim = [grid.nx, grid.ny, grid.nz]
    var lo = [0, 0, 0]
    var f = [0.0, 0.0, 0.0]
    for a in range(3):
        var g = (Float64(pos[a]) - Float64(grid.origin[a])) / Float64(grid.cell[a])
        g = min(max(g, 0.0), Float64(dim[a] - 1))
        var l = min(Int(g), max(dim[a] - 2, 0))
        lo[a] = l
        f[a] = g - Float64(l)
    var e: List[Float64] = [0.0, 0.0, 0.0]
    for k in range(8):
        var o = [k & 1, (k >> 1) & 1, (k >> 2) & 1]
        var w = 1.0
        var c = [0, 0, 0]
        for a in range(3):
            w *= f[a] if o[a] == 1 else 1.0 - f[a]
            c[a] = min(lo[a] + o[a], dim[a] - 1)
        if w > 0.0:
            var v = _irr(sh, 27 * grid.index(c[0], c[1], c[2]), n)
            for ch in range(3):
                e[ch] += w * v[ch]
    return e^


def probe_sh_at(grid: ProbeGrid, sh: List[Float32], pos: Vec3) -> List[Float32]:
    """The 27 harmonics at `pos`, blended from the eight probes around it with the same weights as probe_irradiance
    (the irradiance is linear in the harmonics, so a set_environment with these gives the same light at that point)."""
    var dim = [grid.nx, grid.ny, grid.nz]
    var lo = [0, 0, 0]
    var f = [0.0, 0.0, 0.0]
    for a in range(3):
        var g = (Float64(pos[a]) - Float64(grid.origin[a])) / Float64(grid.cell[a])
        g = min(max(g, 0.0), Float64(dim[a] - 1))
        var l = min(Int(g), max(dim[a] - 2, 0))
        lo[a] = l
        f[a] = g - Float64(l)
    var out = List[Float64](length=27, fill=0.0)
    for k in range(8):
        var o = [k & 1, (k >> 1) & 1, (k >> 2) & 1]
        var w = 1.0
        var c = [0, 0, 0]
        for a in range(3):
            w *= f[a] if o[a] == 1 else 1.0 - f[a]
            c[a] = min(lo[a] + o[a], dim[a] - 1)
        if w > 0.0:
            var b = 27 * grid.index(c[0], c[1], c[2])
            for j in range(27):
                out[j] += w * Float64(sh[b + j])
    var r = List[Float32]()
    for v in out:
        r.append(Float32(v))
    return r^
