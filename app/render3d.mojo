"""The arena renderer: the frame's draw items through a compile-time list of passes (app/render_pass.mojo).

`ArenaRenderer` is `ArenaRendererOf[DefaultPasses]`: the primitives (app/primitive_pass.mojo), the indexed meshes
(app/mesh_pass.mojo) and the skinned meshes (app/skin_draw.mojo), in that order, then the HUD. A game that wants other
passes names its own list, e.g. `ArenaRendererOf[Then[DefaultPasses, MyPass]]`.

A Depth32Float buffer does the hidden-surface work (wgpu-mojo's `create_render_pipeline(depth_format=)` and
`begin_surface_clear_pass_depth`). `app/render.mojo` stays as it was: the parity gates compare its pixels."""
from game.draw_item import DrawItem, MAT_COLOR, MAT_SKY
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
from app.mesh_pass import MeshPass, MeshRegistry, add_unit_cube, add_unit_sphere, unit_cube_arrays, RenderCaps
from app.skin_draw import SkinnedPass
from app.primitive_pass import PrimitivePass
from app.render_pass import RenderPass, Then
from app.shadow_pass import begin_depth_pass
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.render_res import RenderResources, PointLight
from app.skin_pass import build_palette, rot_y
from app.textures import TextureArray, box_levels, checker_base
from app.debug_view import DEBUG_NONE, DEBUG_SKY, debug_recolor
from geometry.mat import Mat4

comptime DEPTH_FORMAT = WGPUTextureFormat.Depth32Float
comptime CLEAR = WGPUColor(0.55, 0.68, 0.85, 1.0)
comptime DefaultPasses = Then[PrimitivePass, Then[MeshPass, SkinnedPass]]
comptime ArenaRenderer = ArenaRendererOf[DefaultPasses]


struct ArenaRendererOf[P: RenderPass](Movable):
    var passes: Self.P
    var res: RenderResources  # camera, shadow map and uniform, atmosphere, AO: bound by the passes, set by the host
    var textures: TextureArray  # layer 0 white, layer 1 the placeholder wall (PR D loads the real one)
    var meshes: MeshRegistry
    var gpu: GpuMeshCache  # the GPU copies of `meshes`, shared by the mesh and skinned passes
    var cube: Int  # the unit cube's mesh id, for the centre probe and textured boxes
    var sphere: Int  # the unit sphere's mesh id, for textured spheres
    var debug_view: Int  # DEBUG_NONE / DEBUG_FLAT / DEBUG_SKY (app/debug_view.mojo), for visual tests
    var probe: Int  # 0 off; 1 a rigid cube at the view's centre; 2 / 3 a skinned cube at the centre, identity / joint turned 20 deg
    var skin_palette: List[Float32]
    var skin_ident: Int  # skinned mesh ids
    var skin_turn: Int
    var view: View
    var floor: List[DrawItem]
    var items: List[DrawItem]
    var depth: Optional[Texture]
    var depth_view: Optional[TextureView]
    var depth_w: UInt32
    var depth_h: UInt32

    def __init__(out self, device: Device, color_format: UInt32, view: View, texture_layers: UInt32 = 2,
                 caps: RenderCaps = RenderCaps.default()) raises:
        caps.check()
        # layer 0 white, layer 1 the placeholder checker; a game that loads more textures asks for more layers
        var tex = TextureArray(device, texture_layers)
        tex.load_layer(device, UInt32(1), box_levels(checker_base()))
        self.res = RenderResources(device)
        self.passes = Self.P.create(device, color_format, DEPTH_FORMAT, tex, self.res, caps)  # before the move: they read the array's views
        self.textures = tex^
        self.meshes = MeshRegistry()
        self.gpu = GpuMeshCache()
        self.cube = add_unit_cube(self.meshes)
        self.sphere = add_unit_sphere(self.meshes)
        self.debug_view = DEBUG_NONE
        self.probe = 0
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
        self.view = view.copy()
        self.floor = List[DrawItem]()
        self.items = List[DrawItem]()
        self.depth = None
        self.depth_view = None
        self.depth_w = 0
        self.depth_h = 0

    def __init__(out self, *, deinit move: Self):
        self.passes = move.passes^
        self.res = move.res^
        self.textures = move.textures^
        self.meshes = move.meshes^
        self.gpu = move.gpu^
        self.cube = move.cube
        self.sphere = move.sphere
        self.debug_view = move.debug_view
        self.probe = move.probe
        self.skin_palette = move.skin_palette^
        self.skin_ident = move.skin_ident
        self.skin_turn = move.skin_turn
        self.view = move.view^
        self.floor = move.floor^
        self.items = move.items^
        self.depth = move.depth^
        self.depth_view = move.depth_view^
        self.depth_w = move.depth_w
        self.depth_h = move.depth_h

    def set_shadow(mut self, device: Device, light_vp: List[Float32], on: Bool) raises:
        """RenderResources.set_shadow: the light's view-projection and whether the shadow factor is applied."""
        self.res.set_shadow(device, light_vp, on)

    def set_atmosphere(mut self, device: Device, sky_top: Vec3, sky_horizon: Vec3, fog_density: Float32, exposure: Float32,
                       fog: Bool, linear: Bool, sky_curve: Float32 = 0.5) raises:
        """RenderResources.set_atmosphere: sky colours, fog, the linear workflow and its exposure."""
        self.res.set_atmosphere(device, sky_top, sky_horizon, fog_density, exposure, fog, linear, sky_curve)

    def set_ao(mut self, device: Device, cells: List[Float32], nx: Int, ny: Int, x0: Float32, z0: Float32,
               sx: Float32, sz: Float32, on: Bool) raises:
        """RenderResources.set_ao: the ambient-occlusion grid over the floor."""
        self.res.set_ao(device, cells, nx, ny, x0, z0, sx, sz, on)

    def set_lights(mut self, device: Device, lights: List[PointLight]) raises:
        """RenderResources.set_lights: point lights, per pixel, on top of the sun (at most MAX_POINT_LIGHTS)."""
        self.res.set_lights(device, lights)

    def shadow_target(self) raises -> TextureView:
        """A view of the shadow map, for a shadow pass to render depth into."""
        return self.res.shadow_target()

    def begin(mut self, view: View):
        self.view = view.copy()
        self.floor.clear()
        self.items.clear()

    def push(mut self, it: DrawItem):
        """One item; the depth buffer sorts them out. A textured primitive (material > 0, no mesh, not skinned) is drawn on
        the mesh pass: a box on the unit cube, a sphere (radius half[0]) on the unit sphere, both 1 across, so the half
        extents double. A textured item whose layer is not loaded yet samples white (layer 0) until it is."""
        var item = it.copy()
        if item.material > 0 and item.mesh_id < 0 and item.pose_id < 0:
            if item.kind == 1:
                item.half = Vec3(item.half[0], item.half[0], item.half[0], Real(0.0))
                item.mesh_id = self.sphere
            else:
                item.mesh_id = self.cube
            item.half = item.half * Real(2.0)
        if item.material != MAT_COLOR and item.material != MAT_SKY and not self.textures.is_loaded(item.layer):
            item.layer = 0
        self.items.append(item^)

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
        debug_recolor(self.items, self.debug_view)
        self.res.debug_sky(device, self.debug_view == DEBUG_SKY)
        hud.upload(device)
        self._depth_view(device, width, height)
        self.res.write_camera(device, v)
        self.passes.prepare(device, self.items, self.meshes, self.gpu, self.skin_palette, v, self.res)
        var enc = device.create_command_encoder("frame")
        comptime if Self.P.SHADOW:  # a shadow pass in the list: the depth pass first, in this command buffer
            if self.res.shadow_on:
                var srp = begin_depth_pass(enc, self.res.shadow_view)
                self.passes.record_shadow(srp, self.meshes, self.gpu)
                srp^.end()
        var rpass = enc.begin_surface_clear_pass_depth(target, self.depth_view.value(), CLEAR, 1.0, "arena_pass")
        self.passes.record_color(rpass, self.meshes, self.gpu)
        hud.record(rpass)
        rpass^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
