# tier: integration
# Baked irradiance probes (app/irradiance.mojo, issue #141), on native wgpu (lavapipe), 320 x 180:
#   lookup     a 4 x 4 x 4 grid whose light changes along one axis only. A box face that lies at one value of that axis
#              (the top face for y, a side face for x, the front face for z) gets the same colour as a frame lit by one
#              environment holding the grid's harmonics blended at that value (probe_sh_at): within 1 level. This checks
#              the probe index order and the trilinear weights on each axis.
#   off        clear_probes gives the frame of the environment alone, pixel for pixel.
#   bake       a room with a red wall on the left and a green one on the right, lit by the sun and a sky: the probe by
#              the red wall receives more red than green from that side, the one by the green wall the opposite; the
#              middle probe gets both. Prints the bake time per probe.
#   cost       frame time at 1920 x 1080 with the probes and with the environment only (printed; lavapipe).
# `probes_native --dump DIR` writes DIR/gi_*.rgba (scripts/tier3_shots.py makes PNGs of them).
from std.math import pi
from std.sys import argv
from std.time import perf_counter_ns
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from wgpu.texture import Texture
from game.draw_item import DrawItem, MAT_COLOR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget, Then
from app.shadow_pass import ShadowPass
from app.post import PostEffect
from app.lights import Environment, sky_environment, sun_shadow_vp
from app.irradiance import ProbeGrid, bake_probes, probe_irradiance, probe_sh_at

comptime Lit = Then[ShadowPass, DefaultPasses]
comptime W: UInt32 = 320
comptime H: UInt32 = 180


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def look(eye: Vec3, fwd: Vec3, up: Vec3, w: UInt32, h: UInt32) -> View:
    var aspect = Real(Float32(w) / Float32(h))
    return View(CameraPose(eye, look_rotation(fwd, up), 0.9, aspect, 0.1, 200.0), aspect)


def read(device: Device, mut cap: FrameCapture, tex: WGPUTextureHandle, w: UInt32, h: UInt32) raises -> List[UInt8]:
    var req = cap.capture(device, tex)
    req.wait()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(w))
    var out = List[UInt8]()
    for y in range(Int(h)):
        for x in range(Int(w) * 4):
            out.append(p[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


struct Rig(Movable):
    var w: UInt32
    var h: UInt32
    var target: Texture
    var cap: FrameCapture
    var hud: Hud

    def __init__(out self, device: Device, format: UInt32, w: UInt32, h: UInt32) raises:
        self.w = w
        self.h = h
        self.target = device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="gi_target")
        self.cap = FrameCapture(device, w, h)
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(w), Float32(h))

    def __init__(out self, *, deinit move: Self):
        self.w = move.w
        self.h = move.h
        self.target = move.target^
        self.cap = move.cap^
        self.hud = move.hud^

    def shoot[P: RenderPass, F: PostEffect, A: AuxTarget](
        mut self, device: Device, mut r: SceneRendererOf[P, F, A], v: View, items: List[DrawItem],
    ) raises -> List[UInt8]:
        r.begin(v.copy())
        for it in items:
            r.push(it.copy())
        r.draw(device, self.target.handle().raw, self.w, self.h, self.hud)
        return read(device, self.cap, self.target.handle().raw, self.w, self.h)


def box(pos: Vec3, size: Vec3, colour: Vec3, mesh: Int) -> DrawItem:
    return DrawItem(0, pos, 0.0, 0.0, 0.0, 1.0, size, colour, mesh, -1, MAT_COLOR)


def diff(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = 0
    for i in range(0, len(a), 4):
        if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
            n += 1
    return n


def centre_diff(a: List[UInt8], b: List[UInt8]) -> Int:
    """The largest channel difference over the 20 x 20 pixels at the centre."""
    var worst = 0
    for y in range(Int(H) // 2 - 10, Int(H) // 2 + 10):
        for x in range(Int(W) // 2 - 10, Int(W) // 2 + 10):
            for c in range(3):
                var o = (y * Int(W) + x) * 4 + c
                worst = max(worst, abs(Int(a[o]) - Int(b[o])))
    return worst


def centre_rgb(a: List[UInt8]) -> String:
    var o = (Int(H) // 2 * Int(W) + Int(W) // 2) * 4
    return String(Int(a[o])) + " " + String(Int(a[o + 1])) + " " + String(Int(a[o + 2]))


def field(grid: ProbeGrid, axis: Int) -> List[Float32]:
    """Uniform light at each probe, its colour a linear function of the probe's index along `axis` (a different slope
    per channel), so the trilinear blend is exact anywhere along that axis."""
    var out = List[Float32]()
    for i in range(grid.count()):
        var idx = [i % grid.nx, (i // grid.nx) % grid.ny, i // (grid.nx * grid.ny)]
        var t = Float64(idx[axis])
        var rgb = [0.15 + 0.2 * t, 0.6 - 0.15 * t, 0.3 + 0.05 * t]
        for k in range(9):
            for c in range(3):
                out.append(Float32(rgb[c] * 0.282095 * 4.0 * pi) if k == 0 else Float32(0.0))
    return out^


def dump(dir: String, name: String, p: List[UInt8]) raises:
    if dir.byte_length() == 0:
        return
    with open(dir + "/" + name + ".rgba", "w") as f:
        f.write_bytes(Span(p))


def room[P: RenderPass, F: PostEffect, A: AuxTarget](r: SceneRendererOf[P, F, A]) -> List[DrawItem]:
    var items = List[DrawItem]()
    items.append(box(_v(0.0, -0.25, -8.0), _v(6.0, 0.5, 12.0), _v(0.8, 0.8, 0.8), r.cube))  # floor
    items.append(box(_v(-3.25, 1.5, -8.0), _v(0.5, 3.5, 12.0), _v(0.85, 0.1, 0.1), r.cube))  # red wall
    items.append(box(_v(3.25, 1.5, -8.0), _v(0.5, 3.5, 12.0), _v(0.1, 0.75, 0.1), r.cube))  # green wall
    items.append(box(_v(0.0, 1.5, -14.25), _v(7.0, 3.5, 0.5), _v(0.8, 0.8, 0.8), r.cube))  # back wall
    items.append(box(_v(-1.0, 0.5, -9.0), _v(1.0, 1.0, 1.0), _v(0.9, 0.9, 0.9), r.cube))  # two white boxes
    items.append(box(_v(1.2, 0.75, -10.0), _v(1.0, 1.5, 1.0), _v(0.9, 0.9, 0.9), r.cube))
    return items^


def main() raises:
    var s = Suite("probes_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var dir = String("")
    var cost = False
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--dump" and i + 1 < len(args):
            dir = String(args[i + 1])
        if args[i] == "--cost":
            cost = True
    var rig = Rig(device, format, W, H)
    var env = sky_environment(_v(0.35, 0.5, 0.8), _v(0.7, 0.75, 0.8), _v(0.3, 0.28, 0.25))

    # ---- lookup along each axis
    var grid = ProbeGrid(_v(-1.0, -1.0, -10.0), _v(1.0, 1.0, 1.0), 4, 4, 4)
    var faces = List[Tuple[Int, Vec3, Vec3, Vec3, Vec3, Vec3, String]]()
    # axis, box centre, box size, eye, forward, the face's point, label
    faces.append((1, _v(0.0, 0.0, -8.0), _v(2.0, 1.0, 2.0), _v(0.0, 6.0, -8.0), _v(0.0, -1.0, 0.0), _v(0.0, 0.5, -8.0), String("y (top face at y = 0.5)")))
    faces.append((0, _v(1.3, 0.5, -8.5), _v(1.0, 2.0, 2.0), _v(7.0, 0.5, -8.5), _v(-1.0, 0.0, 0.0), _v(1.8, 0.5, -8.5), String("x (side face at x = 1.8)")))
    faces.append((2, _v(0.5, 0.5, -8.3), _v(2.0, 2.0, 1.0), _v(0.5, 0.5, -2.0), _v(0.0, 0.0, -1.0), _v(0.5, 0.5, -7.8), String("z (front face at z = -7.8)")))
    for f in faces:
        var axis = f[0]
        var sh = field(grid, axis)
        var up = _v(0.0, 0.0, -1.0) if axis == 1 else _v(0.0, 1.0, 0.0)
        var v = look(f[3], f[4], up, W, H)
        var a = SceneRendererOf[DefaultPasses](device, format, v)
        a.set_probes(device, grid.origin, grid.cell, grid.nx, grid.ny, grid.nz, sh)
        var items = List[DrawItem]()
        items.append(box(f[1], f[2], _v(0.9, 0.9, 0.9), a.cube))
        var with_probes = rig.shoot(device, a, v, items)
        var b = SceneRendererOf[DefaultPasses](device, format, v)
        b.set_environment(device, Environment(probe_sh_at(grid, sh, f[5]), env.top, env.horizon, env.ground))
        var with_env = rig.shoot(device, b, v, items)
        var d = centre_diff(with_probes, with_env)
        print("axis", f[6], ": probes", centre_rgb(with_probes), "; one environment at that point", centre_rgb(with_env), "; largest difference", d)
        s.check(d <= 1, "probe lookup along " + f[6] + " matches the blended harmonics within 1 level")
        # off
        if axis == 1:
            a.set_environment(device, env)
            var only_env = SceneRendererOf[DefaultPasses](device, format, v)
            only_env.set_environment(device, env)
            a.clear_probes(device)
            s.eqi(diff(rig.shoot(device, a, v, items), rig.shoot(device, only_env, v, items)), 0, "clear_probes: the environment's frame, pixel for pixel")

    # ---- bake a room
    var to_sun = _v(0.5, 1.0, 0.3)
    var view = look(_v(0.0, 1.6, -1.0), _v(0.0, -0.25, -1.0), _v(0.0, 1.0, 0.0), W, H)
    var r = SceneRendererOf[Lit](device, format, view)
    r.set_sun(device, to_sun, _v(1.0, 0.95, 0.9), 1.0)
    r.set_shadow(device, sun_shadow_vp(to_sun, _v(0.0, 0.0, -8.0), 12.0, 30.0), True)
    r.set_environment(device, env)
    var items = room(r)
    var plain = rig.shoot(device, r, view, items)
    dump(dir, "gi_environment", plain)
    var bake_grid = ProbeGrid(_v(-2.0, 1.0, -12.0), _v(2.0, 1.0, 2.0), 3, 2, 5)
    var t0 = perf_counter_ns()
    var baked = bake_probes(device, r, format, bake_grid, items)
    var ms = Float64(perf_counter_ns() - t0) / 1e6
    print("bake:", bake_grid.count(), "probes,", ms, "ms (", ms / Float64(bake_grid.count()), "ms per probe, 6 faces of 32 x 32 each, lavapipe)")
    var p_red = probe_irradiance(bake_grid, baked, _v(-2.0, 1.0, -8.0), _v(-1.0, 0.0, 0.0))
    var p_green = probe_irradiance(bake_grid, baked, _v(2.0, 1.0, -8.0), _v(1.0, 0.0, 0.0))
    var p_mid_l = probe_irradiance(bake_grid, baked, _v(0.0, 1.0, -8.0), _v(-1.0, 0.0, 0.0))
    var p_mid_r = probe_irradiance(bake_grid, baked, _v(0.0, 1.0, -8.0), _v(1.0, 0.0, 0.0))
    print("irradiance facing the red wall, at x = -2:", p_red[0], p_red[1], p_red[2])
    print("irradiance facing the green wall, at x = 2:", p_green[0], p_green[1], p_green[2])
    print("at x = 0 facing left:", p_mid_l[0], p_mid_l[1], p_mid_l[2], "; facing right:", p_mid_r[0], p_mid_r[1], p_mid_r[2])
    s.check(p_red[0] > 1.5 * p_red[1], "beside the red wall, facing it: red above green by half again")
    s.check(p_green[1] > 1.5 * p_green[0], "beside the green wall, facing it: green above red by half again")
    s.check(p_mid_l[0] / p_mid_l[1] > p_mid_r[0] / p_mid_r[1], "in the middle, the side toward the red wall is redder")
    r.set_probes(device, bake_grid.origin, bake_grid.cell, bake_grid.nx, bake_grid.ny, bake_grid.nz, baked)
    var lit = rig.shoot(device, r, view, items)
    dump(dir, "gi_probes", lit)
    print("pixels changed by the probes:", diff(plain, lit), "of", Int(W * H))
    s.check(diff(plain, lit) > Int(W * H) // 4, "the probes change the room's ambient")

    if cost:
        var big = Rig(device, format, 1920, 1080)
        var bv = look(_v(0.0, 1.6, -1.0), _v(0.0, -0.25, -1.0), _v(0.0, 1.0, 0.0), 1920, 1080)
        var times = List[Float64]()
        for on in [False, True]:
            if on:
                r.set_probes(device, bake_grid.origin, bake_grid.cell, bake_grid.nx, bake_grid.ny, bake_grid.nz, baked)
            else:
                r.clear_probes(device)
            for _ in range(2):
                _ = big.shoot(device, r, bv, items)
            var t = perf_counter_ns()
            for _ in range(5):
                _ = big.shoot(device, r, bv, items)
            times.append(Float64(perf_counter_ns() - t) / 5.0 / 1e6)
        print("| frame at 1920 x 1080 (lavapipe, wall clock incl. read-back) | ms |")
        print("|---|---:|")
        print("| environment only |", times[0], "|")
        print("| irradiance probes, 3 x 2 x 5 |", times[1], "|")
        print("| added by the probes |", times[1] - times[0], "|")
    s.finish()
