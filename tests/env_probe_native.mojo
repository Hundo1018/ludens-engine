# tier: integration
# The captured environment (app/env_probe.mojo). A room of six walls 10 m from the origin, each its own colour and lit
# evenly, is captured from the origin; a mirror ball at the origin then shows each wall where the law of reflection puts
# it. For a point of the ball with normal n seen from the camera along v, the mirror direction is 2 (n . v) n - v and
# the wall it meets is the one of its largest component (the probe is at the room's centre, so direction decides).
#   +x red, -x cyan, +y green, -y magenta, +z blue, -z yellow
from std.math import sqrt, pi, cos, sin
from harness.runner import Suite
from wgpu import Instance
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUTextureHandle
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_PBR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_res import ENV_SIZE
from app.lights import uniform_environment, sh_lit
from app.env_probe import EnvProbe, face_axes, cube_environment

comptime W: UInt32 = 480
comptime H: UInt32 = 270


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def wall_color(k: Int) -> Vec3:
    var c = [_v(1, 0, 0), _v(0, 1, 1), _v(0, 1, 0), _v(1, 0, 1), _v(0, 0, 1), _v(1, 1, 0)]
    return c[k]


def wall_of(d: Vec3) -> Int:
    """The wall a direction from the room's centre meets."""
    var ax = abs(Float64(d[0]))
    var ay = abs(Float64(d[1]))
    var az = abs(Float64(d[2]))
    if ax >= ay and ax >= az:
        return 0 if d[0] > 0 else 1
    if ay >= az:
        return 2 if d[1] > 0 else 3
    return 4 if d[2] > 0 else 5


def walls(mut r: SceneRendererOf[DefaultPasses]):
    for k in range(6):
        var ax = face_axes(k)[0]
        var size = _v(22, 22, 22) - _v(abs(Float64(ax[0])), abs(Float64(ax[1])), abs(Float64(ax[2]))) * Real(21.0)
        r.push(DrawItem(0, ax * Real(10.5), 0.0, 0.0, 0.0, 1.0, size, wall_color(k), r.cube, -1, MAT_COLOR))


def read(device: Device, mut cap: FrameCapture, tex: WGPUTextureHandle) raises -> List[UInt8]:
    var req = cap.capture(device, tex)
    req.wait()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
    var pitch = Int(padded_row_pitch(W))
    var out = List[UInt8]()
    for y in range(Int(H)):
        for x in range(Int(W) * 4):
            out.append(p[unsafe_offset=y * pitch + x])
    cap.unmap()
    return out^


def at(px: List[UInt8], v: View, p: Vec3) -> Vec3:
    var c = v.project(p)
    var x = Int((Float64(c.x) / Float64(c.w) * 0.5 + 0.5) * Float64(W))
    var y = Int((0.5 - Float64(c.y) / Float64(c.w) * 0.5) * Float64(H))
    var o = (y * Int(W) + x) * 4
    return _v(Float64(Int(px[o])) / 255.0, Float64(Int(px[o + 1])) / 255.0, Float64(Int(px[o + 2])) / 255.0)


def unit(a: Vec3) -> Vec3:
    var l = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
    return a * (Real(1.0) / l)


def dist(a: Vec3, b: Vec3) -> Float64:
    var d = a - b
    return Float64(sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))


def main() raises:
    var s = Suite("env_probe_native")
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="env")
    var hud = Hud(device, format)
    var dl = DrawList()
    hud.set(dl, Float32(W), Float32(H))
    var cap = FrameCapture(device, W, H)
    var aspect = Real(Float32(W) / Float32(H))
    var eye = _v(0, 0, 4)
    var view = View(CameraPose(eye, look_rotation(_v(0, 0, -1), _v(0, 1, 0)), 0.9, aspect, 0.1, 100.0), aspect)
    var r = SceneRendererOf[DefaultPasses](device, format, view)
    # every wall shows its own colour: no sun, an even white ambient
    r.set_sun(device, _v(0, 1, 0), _v(1, 1, 1), 0.0)
    r.set_environment(device, uniform_environment(_v(1, 1, 1)))

    var probe = EnvProbe(device, format)
    for f in range(6):
        r.begin(probe.view(_v(0, 0, 0), f))
        walls(r)
        r.draw(device, probe.target(), UInt32(ENV_SIZE), UInt32(ENV_SIZE), hud)
        probe.store(device, r.res, f)
    # each face shows the wall it looks at, edge to edge
    var faces_ok = 0
    for f in range(6):
        var o = ((ENV_SIZE // 2) * ENV_SIZE + ENV_SIZE // 2) * 4
        var c = _v(Float64(Int(probe.pixels[f][o])) / 255.0, Float64(Int(probe.pixels[f][o + 1])) / 255.0, Float64(Int(probe.pixels[f][o + 2])) / 255.0)
        if dist(c, wall_color(f)) < 0.02:
            faces_ok += 1
    s.eqi(faces_ok, 6, "each captured face shows the wall on its axis")
    # the ambient the capture gives against the room's exact irradiance over pi on a surface facing +x and one facing
    # up (direct integration over directions, the wall by the direction's largest component)
    var env = cube_environment(probe.pixels, ENV_SIZE, False)
    for which in range(2):
        var n = _v(1, 0, 0) if which == 0 else _v(0, 1, 0)
        var exact = [0.0, 0.0, 0.0]
        var steps = 200
        for i in range(steps):
            var th = (Float64(i) + 0.5) / Float64(steps) * pi
            for j in range(2 * steps):
                var ph = (Float64(j) + 0.5) / Float64(steps) * pi
                var d = _v(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
                var cosine = max(Float64(d[0] * n[0] + d[1] * n[1] + d[2] * n[2]), 0.0)
                var col = wall_color(wall_of(d))
                var dw = sin(th) * (pi / Float64(steps)) * (pi / Float64(steps))
                for c in range(3):
                    exact[c] += Float64(col[c]) * cosine * dw / pi
        var got = sh_lit(env.sh, n)
        print("ambient facing", "+x" if which == 0 else "+y", ": from the capture", got[0], got[1], got[2], "; exact", exact[0], exact[1], exact[2])
        s.check(dist(got, _v(exact[0], exact[1], exact[2])) < 0.06, ("+x" if which == 0 else "+y") + ": the captured ambient is within 0.06 of the room's irradiance")
    probe.finish(device, r.res)

    # a mirror ball of radius 1 at the origin
    r.begin(view.copy())
    walls(r)
    r.push(DrawItem(1, _v(0, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(1, 1, 1), r.sphere, -1, MAT_PBR, 1, 0.0, 1.0))
    r.draw(device, target.handle().raw, W, H, hud)
    var px = read(device, cap, target.handle().raw)
    var hits = 0
    var seen = List[Int](length=6, fill=0)
    # normals that send the camera's ray toward each axis: n = normalize(v + d), d the wanted direction
    var wanted = [_v(1, 0, 0), _v(-1, 0, 0), _v(0, 1, 0), _v(0, -1, 0), _v(0, 0, 1)]
    for d in wanted:
        var n = unit(unit(eye) + d)  # a first guess with v from the centre; the wall is then worked out from the real v
        var v = unit(eye - n)
        var k = 2.0 * Float64(n[0] * v[0] + n[1] * v[1] + n[2] * v[2])
        var refl = n * Real(k) - v
        var w = wall_of(refl)
        var got = at(px, view, n)
        print("ball point with normal", n[0], n[1], n[2], ": mirror direction", refl[0], refl[1], refl[2], "-> wall", w, "; pixel", got[0], got[1], got[2], "; the wall's colour", wall_color(w)[0], wall_color(w)[1], wall_color(w)[2])
        seen[w] += 1
        if dist(got, wall_color(w)) < 0.08:
            hits += 1
    s.eqi(hits, 5, "the ball shows the wall the law of reflection gives at five points")
    s.check(seen[0] == 1 and seen[1] == 1 and seen[2] == 1 and seen[3] == 1 and seen[4] == 1, "those five points reflect five different walls: +x, -x, +y, -y, +z")
    # the sixth wall, from a camera on the +x side
    var eye2 = _v(4, 0, 0)
    var view2 = View(CameraPose(eye2, look_rotation(_v(-1, 0, 0), _v(0, 1, 0)), 0.9, aspect, 0.1, 100.0), aspect)
    r.begin(view2.copy())
    walls(r)
    r.push(DrawItem(1, _v(0, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(1, 1, 1), r.sphere, -1, MAT_PBR, 1, 0.0, 1.0))
    r.draw(device, target.handle().raw, W, H, hud)
    var px2 = read(device, cap, target.handle().raw)
    var n6 = unit(unit(eye2) + _v(0, 0, -1))
    var v6 = unit(eye2 - n6)
    var r6 = n6 * Real(2.0 * Float64(n6[0] * v6[0] + n6[1] * v6[1] + n6[2] * v6[2])) - v6
    var got6 = at(px2, view2, n6)
    print("from +x, ball point", n6[0], n6[1], n6[2], ": mirror direction", r6[0], r6[1], r6[2], "-> wall", wall_of(r6), "; pixel", got6[0], got6[1], got6[2])
    s.check(wall_of(r6) == 5 and dist(got6, wall_color(5)) < 0.08, "and the -z wall (yellow) from a camera on +x")
    # a rougher ball reads smaller mips. A point whose mirror direction is 4 degrees inside the blue wall, next to the
    # red one: a mirror shows blue alone; at roughness 0.7 the red wall's texels are in the mean.
    var nb = unit(unit(eye) + unit(_v(1, 0, 1.3)))
    var vb = unit(eye - nb)
    var rb = nb * Real(2.0 * Float64(nb[0] * vb[0] + nb[1] * vb[1] + nb[2] * vb[2])) - vb
    var reds = List[Float64]()
    for rough in [0.0, 0.7]:
        r.begin(view.copy())
        walls(r)
        r.push(DrawItem(1, _v(0, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(1, 1, 1), r.sphere, -1, MAT_PBR, 1, Float32(rough), 1.0))
        r.draw(device, target.handle().raw, W, H, hud)
        var pr = read(device, cap, target.handle().raw)
        var c = at(pr, view, nb)
        print("roughness", rough, ": mirror direction", rb[0], rb[1], rb[2], "(wall", wall_of(rb), "); pixel", c[0], c[1], c[2])
        reds.append(Float64(c[0]) / max(Float64(c[2]), 1e-3))
    s.check(wall_of(rb) == 4 and reds[0] < 0.02, "a mirror next to the wall's edge shows one wall")
    s.check(reds[1] > 0.1, "at roughness 0.7 the neighbouring wall is in the reflection (red over blue above 0.1)")
    # set_environment turns the cube map off again: the gradient of the three mean colours
    r.set_environment(device, uniform_environment(_v(0.3, 0.3, 0.3)))
    r.begin(view.copy())
    walls(r)
    r.push(DrawItem(1, _v(0, 0, 0), 0.0, 0.0, 0.0, 1.0, _v(2, 2, 2), _v(1, 1, 1), r.sphere, -1, MAT_PBR, 1, 0.0, 1.0))
    r.draw(device, target.handle().raw, W, H, hud)
    var off = read(device, cap, target.handle().raw)
    var mid = at(off, view, _v(0, 0, 1))
    print("after set_environment(uniform 0.3): the ball's middle is", mid[0], mid[1], mid[2])
    s.check(dist(mid, _v(0.3, 0.3, 0.3)) < 0.03, "set_environment replaces the captured cube map")
    s.check(target.handle().raw == target.handle().raw, "the target is alive until here")
    s.finish()
