"""A reproducible frame of the rendering tier 2 features (#140) for the native/web pixel parity and the tile reference: a
terrain (129 x 129 corners of ludens-core's generated heights, 0.5 m cells, chunks of 16, levels by distance, splat by
height and slope), a mesh cube standing on it, two decals (one on the terrain, one on the cube's face), a camera-facing
alpha trail and a flat additive trail, drawn by SceneRendererOf[Tier2Passes] into a 480 x 270 RGBA8Unorm target and read
back through FrameCapture. The same code runs natively (app/tier2_pixels.mojo, tests/tier2_native.mojo) and in the web
app (app_tier2_request)."""
from game.camera_view import View
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
from game.terrain import TerrainField
from game.decals import Decal, DecalMesh
from game.trails import TrailStyle, TRAIL_BLEND_ALPHA, TRAIL_BLEND_ADD
from collision.trimesh import HeightField
from procedural.terrain_gen import TerrainParams, height_tile
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture
from wgpu.device import Device
from wgpu.texture import Texture
from app.render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.terrain_pass import TerrainPass
from app.decal_pass import DecalPass
from app.trail_pass import TrailPass

comptime TIER2_FRAME_W: UInt32 = 480
comptime TIER2_FRAME_H: UInt32 = 270
comptime Tier2Passes = Then[DefaultPasses, Then[TerrainPass, Then[DecalPass, TrailPass]]]
comptime CUBE_X: Float64 = 22.0
comptime CUBE_Z: Float64 = 18.0


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


def tier2_view() -> View:
    var aspect = Real(Float32(TIER2_FRAME_W) / Float32(TIER2_FRAME_H))
    var eye = _v(6, 14, 2)
    return View(CameraPose(eye, look_rotation(_v(24, 0, 22) - eye, _v(0, 1, 0)), 0.9, aspect, 0.1, 500.0), aspect)


def tier2_field() raises -> TerrainField:
    var p = TerrainParams(3, 24.0, 6.0, 4, False, 0.0)
    var h = height_tile(0, 0, 128, 128, Real(0.5), p)
    var hf = HeightField(h, 129, 129, Real(0.5))
    var f = TerrainField.from_heightfield(hf, 16, 6.0)
    f.splat_by_height_slope(Float32(-1.0), Float32(2.5), Float32(0.9))
    return f^


def ground_at(f: TerrainField, x: Float64, z: Float64) -> Float64:
    """The terrain's height at (x, z), bilinear between the four corners of the cell (the level-0 surface is within a
    few centimetres of it on this field)."""
    var gu = (x - Float64(f.ox)) / Float64(f.cell)
    var gv = (z - Float64(f.oz)) / Float64(f.cell)
    var i = Int(gu)
    var j = Int(gv)
    var a = gu - Float64(i)
    var b = gv - Float64(j)
    var h0 = Float64(f.height(i, j)) * (1.0 - a) + Float64(f.height(i + 1, j)) * a
    var h1 = Float64(f.height(i, j + 1)) * (1.0 - a) + Float64(f.height(i + 1, j + 1)) * a
    return h0 * (1.0 - b) + h1 * b


def tyre_point(f: TerrainField, t: Float64) -> Tuple[Float64, Float64, Float64]:
    """Where the tyre mark's trail is at time t: a curve 15 cm above the ground."""
    var x = CUBE_X - 7.0 + 4.0 * t
    var z = CUBE_Z - 6.0 + 0.5 * t * t
    return (x, ground_at(f, x, z) + 0.15, z)


def tier2_setup(
    mut r: SceneRendererOf[Tier2Passes], device: Device, terrain: Bool = True, decals: Bool = True, trails_on: Bool = True,
) raises:
    """Terrain, decals and trails into the renderer's passes; then the frame's items (begin + push). The flags leave a
    feature out (tests/tier2_native.mojo measures each one's cost and checks each one changes the frame)."""
    var f = tier2_field()
    var field_copy = tier2_field()
    var ground = Float64(f.height(Int(CUBE_X / 0.5), Int(CUBE_Z / 0.5)))
    # a scorch mark on the terrain in front of the cube, and a red mark on the cube's face towards the camera (-z)
    var scorch = DecalMesh(Decal(CUBE_X - 2.5, ground + 1.0, CUBE_Z - 2.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 1.6, 1.6, 3.0, [0.08, 0.06, 0.05, 0.85]))
    _ = scorch.project_terrain(f)
    if terrain:
        r.passes.second.first.set_field(device, f^)
    if decals:
        _ = r.passes.second.second.first.decals.add(scorch^)
    var cube_y = ground + 0.9
    var mark = DecalMesh(Decal(CUBE_X, cube_y + 0.2, CUBE_Z - 1.2, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.5, 0.5, 0.4, [0.9, 0.1, 0.1, 0.9]))
    _ = mark.project_mesh(
        r.meshes.meshes[r.cube].positions, r.meshes.meshes[r.cube].indices,
        CUBE_X, cube_y, CUBE_Z, 0.0, 0.0, 0.0, 1.0, 2.0, 2.0, 2.0,
    )
    if decals:
        _ = r.passes.second.second.first.decals.add(mark^)
    # a swing: an arc of 2 s at 60 steps a second, camera-facing, orange fading to clear; a tyre mark: flat, additive
    ref tp = r.passes.second.second.second
    var swing = tp.trails.add(TrailStyle(
        2.5, 0.05, 256, [0.7, 0.4, 0.0], [1.0, 0.7, 0.2, 1.0], [1.0, 0.4, 0.1, 0.7], [0.8, 0.2, 0.1, 0.0], TRAIL_BLEND_ALPHA,
    ))
    var tyre = tp.trails.add(TrailStyle(
        5.0, 0.2, 256, [0.5], [0.1, 0.5, 0.9, 0.9], [0.1, 0.4, 0.8, 0.6], [0.1, 0.3, 0.6, 0.2], TRAIL_BLEND_ADD, True,
    ))
    for i in range(120 if trails_on else 0):
        var t = Float64(i) / 60.0
        var u = t - 1.0
        tp.trails.trails[swing].move_to(t, CUBE_X - 3.0 + 3.0 * u, ground + 3.0 - 1.5 * u * u, CUBE_Z - 4.0)
        var p = tyre_point(field_copy, t)
        tp.trails.trails[tyre].move_to(t, p[0], p[1], p[2])
    tp.advance(2.0)
    tier2_items(r, cube_y)


def tier2_items(mut r: SceneRendererOf[Tier2Passes], cube_y: Float64):
    """begin() and the frame's two items: the cube (2 m, a mesh) and the sky sphere."""
    r.begin(tier2_view())
    r.push(DrawItem(0, _v(CUBE_X, cube_y, CUBE_Z), 0.0, 0.0, 0.0, 1.0, _v(2.0, 2.0, 2.0), _v(0.7, 0.72, 0.75), r.cube, -1, MAT_COLOR))
    r.push(DrawItem(1, _v(20, 3, 20), 0.0, 0.0, 0.0, 1.0, _v(190, 190, 190), _v(1, 1, 1), r.sphere, -1, MAT_SKY))


struct Tier2Reference(Movable):
    var renderer: SceneRendererOf[Tier2Passes]
    var target: Texture
    var capture: FrameCapture
    var hud: Hud
    var req: Optional[MapRequest]

    def __init__(out self, device: Device) raises:
        var format = WGPUTextureFormat.RGBA8Unorm  # pinned, so both sides produce the same bytes
        self.renderer = SceneRendererOf[Tier2Passes](device, format, tier2_view())
        self.target = device.create_texture(
            TIER2_FRAME_W, TIER2_FRAME_H, 1, format,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="tier2_reference_target",
        )
        self.capture = FrameCapture(device, TIER2_FRAME_W, TIER2_FRAME_H)
        self.hud = Hud(device, format)
        var dl = DrawList()
        self.hud.set(dl, Float32(TIER2_FRAME_W), Float32(TIER2_FRAME_H))
        self.req = None

    def __init__(out self, *, deinit move: Self):
        self.renderer = move.renderer^
        self.target = move.target^
        self.capture = move.capture^
        self.hud = move.hud^
        self.req = move.req^

    def start(mut self, device: Device) raises:
        tier2_setup(self.renderer, device)
        self.renderer.draw(device, self.target.handle().raw, TIER2_FRAME_W, TIER2_FRAME_H, self.hud)
        self.req = self.capture.capture(device, self.target.handle().raw)

    def poll(mut self) raises -> UInt64:
        """Address of the mapped pixels once the read-back finished, else 0."""
        if self.req and self.req.value().ready():
            var req = self.req.take()
            return UInt64(Int(req.take()))
        return 0

    def release(mut self):
        self.capture.unmap()

    def pitch(self) -> UInt32:
        return self.capture.row_pitch()
