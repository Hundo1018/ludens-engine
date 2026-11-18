# tier: integration
# Every style pipeline of the engine renders one scene (app/pipelines.mojo lists them; `pipelines()` below draws each).
#   style_gallery_native              the checks
#   style_gallery_native --dump [s]   also writes build/gallery/<name>.rgba (names containing s); scripts/style_gallery.py
# Checks, per pipeline: the frame is not flat, differs from the plain frame on at least a tenth of the pixels, and no two
# pipelines give the same frame (the mean absolute difference of their 16 x 9 tile means is above a threshold).
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
from app.render_pass import RenderPass, Then
from app.render_res import PointLight
from app.shadow_pass import ShadowPass
from app.post import PostEffect, NoPost, Stage, ThenPost
from app.styles_display import (
    DotMatrixHandheld, RedLedVisor, Cga, Spectrum, C64, OneBit, AsciiTerminal, CompositeBleed, CrtTube, VectorLines,
    PhosphorGlow, Console32, LedWall,
)
from app.styles_film import (
    Daguerreotype, FilmNoir, TwoStrip, Vhs, Anaglyph, Aerochrome, TiltShift, AnamorphicGrade, InstantPrint, NightVision,
    Ironbow, XrayFilm,
)
from app.styles_material import MatCel, MatFlatSky, MatHeat, MatDark, MatXray
from app.primitive_pass import PrimitivePass
from app.styles_own import (
    ScrewAxisPass, ScrewLook, FingerprintPass, FingerprintLook, MatGeometricProduct, MatVoid, ProductKey, item_screw,
    frame_hash, hash_user,
)
from geometry.quat import Quat
from app.mesh_pass import MeshPassOf
from app.styles_print import (
    NewsHalftone, ComicCmyk, Risograph, Engraving, CrossHatch, Woodcut, Blueprint, UkiyoE, Constructivist, PopArt,
    LigneClaire, TopoMap,
)
from app.styles_util import Kuwahara, BrightPass, StreakH
from app.styles_paint import (
    Pointillism, ImpastoRelief, SwirlStrokes, WatercolourPaper, SumiE, DeStijl, StainedGlass, Mosaic, CrossStitch,
    PencilSketch, Chalkboard, Chiaroscuro, PaperCut, Porcelain, InkLine,
)
from arena_frame_native import sun_light_vp

comptime W: UInt32 = 640
comptime H: UInt32 = 360
comptime Lit = Then[ShadowPass, DefaultPasses]
# pipelines whose look starts on the surface: a material pack of their own on the mesh pass (app/styles_material.mojo)
comptime CelPasses = Then[ShadowPass, Then[PrimitivePass, MeshPassOf[MatCel, MatFlatSky]]]
comptime HeatPasses = Then[ShadowPass, Then[PrimitivePass, MeshPassOf[MatHeat, MatDark]]]
# the engine's own three (app/styles_own.mojo)
comptime ScrewPasses = Then[Lit, ScrewAxisPass]
comptime ProductPasses = Then[ShadowPass, Then[PrimitivePass, MeshPassOf[MatGeometricProduct, MatVoid]]]
comptime XrayPasses = Then[PrimitivePass, MeshPassOf[MatXray, MatDark]]


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def _box(x: Float64, y: Float64, z: Float64, hx: Float64, hy: Float64, hz: Float64, yaw: Float64, c: Vec3, cube: Int) -> DrawItem:
    """A colour box on the mesh pass (so it is shadowed and casts): the unit cube is 1 across, so the extents double."""
    from std.math import sin, cos
    return DrawItem(0, _v(x, y, z), 0.0, sin(yaw / 2), 0.0, cos(yaw / 2), _v(2 * hx, 2 * hy, 2 * hz), c, cube, -1, MAT_COLOR)


def _turn(it: DrawItem, axis: Vec3, angle: Float64, about: Vec3, shift: Vec3) -> DrawItem:
    """`it` turned by `angle` about the line through `about` along `axis`, then moved by `shift`."""
    var q = Quat.from_axis_angle(axis, Real(angle))
    var r = q.rotate(it.pos - about)
    var o = it.copy()
    o.pos = about + r + shift
    var n = q * Quat(Real(it.qx), Real(it.qy), Real(it.qz), Real(it.qw))
    o.qx = Float64(n.x)
    o.qy = Float64(n.y)
    o.qz = Float64(n.z)
    o.qw = Float64(n.w)
    return o^


def gallery_scene(cube: Int, sphere: Int, moved: Bool = False) -> List[DrawItem]:
    """A courtyard: a floor, an arch, pillars, a stack of turned crates, four spheres (one metal), a far wall.
    `moved` gives the next frame of a motion: the red sphere has rolled 0.5 m along x (item 10), the lowest crate has
    spun in place (4), the middle one has spun and risen (5), the top one has slid (6), the purple block has tumbled
    (9), the ball on the arch has risen (13)."""
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
    if moved:
        s[10] = _turn(s[10], _v(0, 0, -1), 0.5 / 0.8, s[10].pos, _v(0.5, 0, 0))  # rolling without slipping, radius 0.8
        s[4] = _turn(s[4], _v(0, 1, 0), 0.5, s[4].pos, _v(0, 0, 0))
        s[5] = _turn(s[5], _v(0, 1, 0), 0.6, _v(2.4, 0, -0.5), _v(0, 0.25, 0))
        s[6] = _turn(s[6], _v(0, 1, 0), 0.0, s[6].pos, _v(0.3, 0, 0))
        s[9] = _turn(s[9], _v(0.6, 0.0, 0.8), 0.7, _v(-5.0, 0.0, 2.2), _v(0.1, 0.15, 0))
        s[13] = _turn(s[13], _v(0, 1, 0), 0.0, s[13].pos, _v(0, 0.3, 0))
    return s^


struct Gallery(Movable):
    var device: Device
    var cap: FrameCapture
    var target: Texture
    var hud: Hud
    var view: View
    var dump: Bool
    var only: String
    var names: List[String]
    var tiles: List[List[Int]]  # per frame: 16 x 9 tile means, r g b
    var plain: List[UInt8]

    def __init__(out self, var device: Device, dump: Bool, only: String) raises:
        var format = WGPUTextureFormat.RGBA8Unorm
        self.target = device.create_texture(W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="gallery")
        var aspect = Real(Float32(W) / Float32(H))
        var eye = _v(0.6, 3.2, 9.5)
        self.view = View(CameraPose(eye, look_rotation(_v(0, 1.0, 0) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)
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

    def shot[P: RenderPass, F: PostEffect](mut self, mut s: Suite, frames: Int = 1) raises:
        """One pipeline: passes P, stages F. Renders the gallery scene and records its tile means. `frames` 2 draws the
        scene and then its next frame (gallery_scene `moved`), for a pass that compares frames."""
        var name = String(F.NAME)
        if self.only.byte_length() > 0 and self.only not in name and name != "plain":
            return
        var r = ArenaRendererOf[P, F](self.device, WGPUTextureFormat.RGBA8Unorm, self.view)
        r.set_atmosphere(self.device, _v(0.25, 0.45, 0.8), _v(0.78, 0.82, 0.86), 0.012, 1.0, True, True)
        r.set_shadow(self.device, sun_light_vp(), True)
        r.set_lights(self.device, [PointLight(_v(-2.2, 1.2, -1.2), 5.0, _v(1.0, 0.6, 0.3), 2.0)])
        r.post_seed = 7.0
        for k in range(frames):
            var items = gallery_scene(r.cube, r.sphere, k == 1)
            r.post_user = hash_user(frame_hash(items))
            r.begin(self.view.copy())
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
        print("style", name, "stages", F.STAGES, "tile range", lo, hi, "changed", changed * 100 // (Int(W) * Int(H)), "% after:", String(F.AFTER))
        s.check(hi - lo > 40, name + ": the frame is not flat")
        if F.ON:
            s.check(changed * 10 > Int(W) * Int(H), name + ": differs from the plain frame on more than a tenth of the pixels")
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
    g.shot[Lit, Stage[DotMatrixHandheld]](s)
    g.shot[Lit, Stage[RedLedVisor]](s)
    g.shot[Lit, Stage[Cga]](s)
    g.shot[Lit, Stage[Spectrum]](s)
    g.shot[Lit, Stage[C64]](s)
    g.shot[Lit, Stage[OneBit]](s)
    g.shot[Lit, Stage[AsciiTerminal]](s)
    g.shot[Lit, ThenPost[Stage[CompositeBleed], Stage[CrtTube]]](s)
    g.shot[Lit, ThenPost[Stage[VectorLines], Stage[PhosphorGlow]]](s)
    g.shot[Lit, Stage[Console32]](s)
    g.shot[Lit, Stage[LedWall]](s)
    g.shot[Lit, Stage[NewsHalftone]](s)
    g.shot[Lit, Stage[ComicCmyk]](s)
    g.shot[Lit, Stage[Risograph]](s)
    g.shot[Lit, Stage[Engraving]](s)
    g.shot[Lit, Stage[CrossHatch]](s)
    g.shot[Lit, Stage[Woodcut]](s)
    g.shot[Lit, Stage[Blueprint]](s)
    g.shot[Lit, Stage[UkiyoE]](s)
    g.shot[Lit, Stage[Constructivist]](s)
    g.shot[Lit, Stage[PopArt]](s)
    g.shot[Lit, Stage[LigneClaire]](s)
    g.shot[Lit, Stage[TopoMap]](s)
    g.shot[Lit, Stage[Pointillism]](s)
    g.shot[Lit, ThenPost[Stage[Kuwahara], Stage[ImpastoRelief]]](s)
    g.shot[Lit, Stage[SwirlStrokes]](s)
    g.shot[Lit, ThenPost[Stage[Kuwahara], Stage[WatercolourPaper]]](s)
    g.shot[Lit, Stage[SumiE]](s)
    g.shot[Lit, Stage[DeStijl]](s)
    g.shot[Lit, Stage[StainedGlass]](s)
    g.shot[Lit, Stage[Mosaic]](s)
    g.shot[Lit, Stage[CrossStitch]](s)
    g.shot[Lit, Stage[PencilSketch]](s)
    g.shot[Lit, Stage[Chalkboard]](s)
    g.shot[Lit, Stage[Chiaroscuro]](s)
    g.shot[Lit, Stage[PaperCut]](s)
    g.shot[Lit, Stage[Porcelain]](s)
    g.shot[CelPasses, Stage[InkLine]](s)
    g.shot[Lit, Stage[Daguerreotype]](s)
    g.shot[Lit, Stage[FilmNoir]](s)
    g.shot[Lit, Stage[TwoStrip]](s)
    g.shot[Lit, Stage[Vhs]](s)
    g.shot[Lit, Stage[Anaglyph]](s)
    g.shot[Lit, Stage[Aerochrome]](s)
    g.shot[Lit, Stage[TiltShift]](s)
    g.shot[Lit, ThenPost[Stage[BrightPass], ThenPost[Stage[StreakH], Stage[AnamorphicGrade]]]](s)
    g.shot[Lit, Stage[InstantPrint]](s)
    g.shot[Lit, Stage[NightVision]](s)
    g.shot[HeatPasses, Stage[Ironbow]](s)
    g.shot[XrayPasses, Stage[XrayFilm]](s)
    # the engine's own three
    g.shot[ScrewPasses, Stage[ScrewLook]](s, 2)
    g.shot[FingerprintPass, Stage[FingerprintLook]](s)
    g.shot[ProductPasses, Stage[ProductKey]](s)


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
    s.finish()
