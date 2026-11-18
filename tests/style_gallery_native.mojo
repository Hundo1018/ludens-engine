# tier: integration
# Every style pipeline of the engine renders one scene (`pipelines()` below draws each).
#   style_gallery_native              the checks
#   style_gallery_native --dump [s]   also writes build/gallery/<name>.rgba (names containing s); scripts/style_gallery.py
# Checks, per pipeline:
#   - its structure is not the default one: it has a pass, a material or an aux list of its own, or its stages are more
#     than one bare full-screen shader (a full-screen shader alone is a shader, not a pipeline);
#   - the frame is not flat and differs from the plain frame on at least a tenth of the pixels;
#   - no two pipelines give the same frame (the mean absolute difference of their 16 x 9 tile means).
# Each line printed is the pipeline's structure: its passes, its aux list, its stage graph and what it is after.
from std.sys import argv
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.device import Device
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY, MAT_PBR
from game.camera_view import View
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from app.render3d import ArenaRendererOf, DefaultPasses
from app.render_pass import RenderPass, Then, AuxTarget, NoAux, Aux
from app.render_res import PointLight
from app.shadow_pass import ShadowPass
from app.post import PostEffect, NoPost, Stage, ThenPost, scene_aspect
from app.styles_display import (
    DotMatrixHandheld, RedLedVisor, CgaComposite, Spectrum, C64, OneBit, OneBitAux, AsciiTerminal, CrtTelevision,
    VectorScopePasses, VectorScope, Console32Passes, Console32, LedWall,
)
from app.primitive_pass import PrimitivePass
from app.styles_own import frame_hash, hash_user
from geometry.quat import Quat
from app.mesh_pass import MeshPassOf
from arena_frame_native import sun_light_vp

comptime W: UInt32 = 640
comptime H: UInt32 = 360
comptime Lit = Then[ShadowPass, DefaultPasses]



def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def _box(x: Float64, y: Float64, z: Float64, hx: Float64, hy: Float64, hz: Float64, yaw: Float64, c: Vec3, cube: Int) -> DrawItem:
    """A colour box on the mesh pass (so it is shadowed and casts): the unit cube is 1 across, so the extents double."""
    from std.math import sin, cos
    return DrawItem(0, _v(x, y, z), 0.0, sin(yaw / 2), 0.0, cos(yaw / 2), _v(2 * hx, 2 * hy, 2 * hz), c, cube, -1, MAT_COLOR)


def _turn(it: DrawItem, axis: Vec3, angle: Float64, about: Vec3, shift: Vec3, t: Float64) -> DrawItem:
    """`it` turned by t x `angle` about the line through `about` along `axis`, then moved by t x `shift`."""
    var q = Quat.from_axis_angle(axis, Real(angle * t))
    var r = q.rotate(it.pos - about)
    var o = it.copy()
    o.pos = about + r + shift * Real(t)
    var n = q * Quat(Real(it.qx), Real(it.qy), Real(it.qz), Real(it.qw))
    o.qx = Float64(n.x)
    o.qy = Float64(n.y)
    o.qz = Float64(n.z)
    o.qw = Float64(n.w)
    return o^


def gallery_scene(cube: Int, sphere: Int, t: Float64 = 0.0) -> List[DrawItem]:
    """A courtyard: a floor, an arch, pillars, a stack of turned crates, four spheres (one metal), a far wall.
    t runs 0 .. 1 over one motion: the red sphere rolls 0.5 m along x without slipping (item 10), the lowest crate
    spins in place (4), the middle one spins and rises (5), the top one slides (6), the purple block tumbles (9), the
    ball on the arch rises (13)."""
    var s = List[DrawItem]()
    s.append(_box(0, -0.25, 0, 12, 0.25, 12, 0, _v(0.62, 0.66, 0.55), cube))
    s.append(_box(-3.2, 1.25, -2.0, 0.4, 1.25, 0.4, 0, _v(0.85, 0.82, 0.74), cube))
    s.append(_box(-1.2, 1.25, -2.0, 0.4, 1.25, 0.4, 0, _v(0.85, 0.82, 0.74), cube))
    s.append(_box(-2.2, 2.75, -2.0, 1.6, 0.25, 0.5, 0, _v(0.80, 0.36, 0.24), cube))
    s.append(_box(2.4, 0.5, -0.5, 0.5, 0.5, 0.5, 0.3, _v(0.25, 0.52, 0.85), cube))
    s.append(_box(2.5, 1.4, -0.5, 0.4, 0.4, 0.4, 0.9, _v(0.93, 0.74, 0.20), cube))
    s.append(_box(2.4, 2.1, -0.5, 0.3, 0.3, 0.3, 1.5, _v(0.80, 0.25, 0.30), cube))
    s.append(_box(4.6, 1.0, -3.5, 0.5, 1.0, 0.5, 0.4, _v(0.45, 0.70, 0.45), cube))
    s.append(_box(0, 1.5, -7.0, 7.0, 1.5, 0.3, 0, _v(0.72, 0.60, 0.50), cube))
    s.append(_box(-5.0, 0.35, 1.5, 0.9, 0.35, 0.6, -0.5, _v(0.55, 0.38, 0.62), cube))
    s.append(DrawItem(1, _v(0.2, 0.8, 1.0), 0.0, 0.0, 0.0, 1.0, _v(1.6, 1.6, 1.6), _v(0.90, 0.30, 0.25), sphere, -1, MAT_COLOR))
    s.append(DrawItem(1, _v(-2.2, 0.5, 2.6), 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(0.95, 0.95, 0.9), sphere, -1, MAT_PBR, 1, 0.2, 1.0))
    s.append(DrawItem(1, _v(3.2, 0.45, 3.2), 0.0, 0.0, 0.0, 1.0, _v(0.9, 0.9, 0.9), _v(0.20, 0.65, 0.60), sphere, -1, MAT_COLOR))
    s.append(DrawItem(1, _v(-2.2, 3.5, -2.0), 0.0, 0.0, 0.0, 1.0, _v(1.0, 1.0, 1.0), _v(0.95, 0.85, 0.35), sphere, -1, MAT_COLOR))
    s.append(DrawItem(1, _v(0, 3, 9), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), sphere, -1, MAT_SKY))
    if t > 0.0:
        s[10] = _turn(s[10], _v(0, 0, -1), 0.5 / 0.8, s[10].pos, _v(0.5, 0, 0), t)
        s[4] = _turn(s[4], _v(0, 1, 0), 0.5, s[4].pos, _v(0, 0, 0), t)
        s[5] = _turn(s[5], _v(0, 1, 0), 0.6, _v(2.4, 0, -0.5), _v(0, 0.25, 0), t)
        s[6] = _turn(s[6], _v(0, 1, 0), 0.0, s[6].pos, _v(0.3, 0, 0), t)
        s[9] = _turn(s[9], _v(0.6, 0.0, 0.8), 0.7, _v(-5.0, 0.0, 2.2), _v(0.1, 0.15, 0), t)
        s[13] = _turn(s[13], _v(0, 1, 0), 0.0, s[13].pos, _v(0, 0.3, 0), t)
    return s^


struct Gallery(Movable):
    var device: Device
    var cap: FrameCapture
    var target: Texture
    var hud: Hud
    var counted: Int  # pipelines whose structure is not the default
    var dump: Bool
    var only: String
    var names: List[String]
    var tiles: List[List[Int]]  # per frame: 16 x 9 tile means, r g b
    var plain: List[UInt8]

    def __init__(out self, var device: Device, dump: Bool, only: String) raises:
        var format = WGPUTextureFormat.RGBA8Unorm
        self.target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="gallery")
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(W), Float32(H))
        self.cap = FrameCapture(device, W, H)
        self.device = device^
        self.dump = dump
        self.only = only
        self.names = List[String]()
        self.tiles = List[List[Int]]()
        self.plain = List[UInt8]()
        self.counted = 0

    def shot[P: RenderPass, F: PostEffect, A: AuxTarget = NoAux](mut self, mut s: Suite, frames: Int = 1) raises:
        """One pipeline: passes P, stages F, aux list A. Renders the gallery scene and records its tile means.
        `frames` > 1 draws the scene's motion in that many steps (for a pipeline that reads the last frame, or compares
        poses); the last one is kept."""
        var name = String(F.NAME)
        if self.only.byte_length() > 0 and self.only not in name and name != "plain":
            return
        var aspect = Real(scene_aspect[F](Float64(W) / Float64(H)))
        var eye = _v(0.6, 3.2, 9.5)
        var view = View(CameraPose(eye, look_rotation(_v(0, 1.0, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)
        var r = ArenaRendererOf[P, F, A](self.device, WGPUTextureFormat.RGBA8Unorm, view)
        r.set_atmosphere(self.device, _v(0.25, 0.45, 0.8), _v(0.78, 0.82, 0.86), 0.012, 1.0, True, True)
        r.set_shadow(self.device, sun_light_vp(), True)
        r.set_lights(self.device, [PointLight(_v(-2.2, 1.2, -1.2), 5.0, _v(1.0, 0.6, 0.3), 2.0)])
        r.post_seed = 7.0
        r.eye_sep = 0.35
        for k in range(frames):
            var items = gallery_scene(r.cube, r.sphere, Float64(k) / Float64(frames - 1) if frames > 1 else 0.0)
            r.post_user = hash_user(frame_hash(items))
            r.post_time = Float32(k) / Float32(60.0)
            r.begin(view.copy())
            for it in items:
                r.push(it)
            r.draw(self.device, self.target.handle().raw, W, H, self.hud)
        var req = self.cap.capture(self.device, self.target.handle().raw)
        req.wait()
        var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(req.take()))
        var pitch = Int(padded_row_pitch(W))
        var out = List[UInt8]()
        for y in range(Int(H)):
            for x in range(Int(W) * 4):
                out.append(px[unsafe_offset=y * pitch + x])
        self.cap.unmap()
        var tw = Int(W) // 16
        var th = Int(H) // 9
        var t = List[Int](length=16 * 9 * 3, fill=0)
        for y in range(Int(H)):
            for x in range(Int(W)):
                for c in range(3):
                    t[((y // th) * 16 + x // tw) * 3 + c] += Int(out[(y * Int(W) + x) * 4 + c])
        var lo = 255
        var hi = 0
        for i in range(len(t)):
            t[i] //= tw * th
            lo = min(lo, t[i])
            hi = max(hi, t[i])
        var changed = 0
        if len(self.plain) == 0:
            self.plain = out.copy()
        else:
            for i in range(0, len(out), 4):
                if abs(Int(out[i]) - Int(self.plain[i])) + abs(Int(out[i + 1]) - Int(self.plain[i + 1])) + abs(Int(out[i + 2]) - Int(self.plain[i + 2])) > 24:
                    changed += 1
        var own = P.sig() != Lit.sig() or not F.PLAIN or A.ON
        print("style", name, "| passes:", P.sig(), "| aux:", A.sig() if A.ON else String("-"), "| stages:", F.sig(), "| after:", String(F.AFTER))
        print("      tile range", lo, hi, "changed", changed * 100 // (Int(W) * Int(H)), "%")
        s.check(hi - lo > 40, name + ": the frame is not flat")
        if F.ON:
            s.check(own, name + ": the pipeline's structure is its own (passes, aux or stage graph), not one shader over the default")
            s.check(changed * 10 > Int(W) * Int(H), name + ": differs from the plain frame on more than a tenth of the pixels")
            if own:
                self.counted += 1
        if self.dump:
            with open("build/gallery/" + name + ".rgba", "w") as f:
                f.write_bytes(out)
        self.names.append(name)
        self.tiles.append(t^)

    def distinct(self, mut s: Suite):
        """No two pipelines give the same picture: the least mean tile difference over all pairs."""
        var worst = 1 << 30
        var wa = 0
        var wb = 0
        for a in range(len(self.tiles)):
            for b in range(a + 1, len(self.tiles)):
                var d = 0
                for i in range(len(self.tiles[a])):
                    d += abs(self.tiles[a][i] - self.tiles[b][i])
                if d < worst:
                    worst = d
                    wa = a
                    wb = b
        if len(self.tiles) > 1:
            print("closest pair:", self.names[wa], self.names[wb], "mean tile channel difference", Float64(worst) / Float64(16 * 9 * 3))
            s.check(worst > 16 * 9 * 3 * 2, "every two pipelines differ by more than 2 / 255 per tile channel on average")


def pipelines(mut g: Gallery, mut s: Suite) raises:
    g.shot[Lit, NoPost](s)
    # display hardware (app/styles_display.mojo)
    g.shot[Lit, DotMatrixHandheld](s, 4)
    g.shot[Lit, RedLedVisor](s)
    g.shot[Lit, CgaComposite](s)
    g.shot[Lit, Spectrum](s)
    g.shot[Lit, C64](s)
    g.shot[Lit, OneBit, Aux[OneBitAux]](s)
    g.shot[Lit, AsciiTerminal](s)
    g.shot[Lit, CrtTelevision](s, 4)
    g.shot[VectorScopePasses, VectorScope](s, 4)
    g.shot[Console32Passes, Console32](s)
    g.shot[Lit, LedWall](s)


def main() raises:
    var s = Suite("style_gallery_native")
    var a = argv()
    var dump = len(a) > 1 and String(a[1]) == "--dump"
    var only = String(a[2]) if len(a) > 2 else String()
    var g = Gallery(Instance().request_adapter().request_device(), dump, only)
    print("size", W, H)
    pipelines(g, s)
    if only.byte_length() == 0:
        g.distinct(s)
    print("pipelines with a structure of their own:", g.counted)
    s.finish()
