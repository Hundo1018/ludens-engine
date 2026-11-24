"""The scene renderer: the frame's draw items through a compile-time list of passes (app/render_pass.mojo).

`SceneRenderer` is `SceneRendererOf[DefaultPasses]`: the primitives (app/primitive_pass.mojo), the indexed meshes
(app/mesh_pass.mojo) and the skinned meshes (app/skin_draw.mojo), in that order, then the HUD. A game that wants other
passes names its own list, e.g. `SceneRendererOf[Then[DefaultPasses, MyPass]]`.

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
from wgpu import null_opaque
from wgpu import WGPUColor
from wgpu import WGPUTextureHandle
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.texture import Texture, TextureView
from hud import Hud
from app.mesh_pass import MeshPass, MeshRegistry, add_unit_cube, add_unit_sphere, unit_cube_arrays, RenderCaps
from app.skin_draw import SkinnedPass
from app.primitive_pass import PrimitivePass
from app.render_pass import RenderPass, Then, AuxTarget, NoAux
from app.post import PostEffect, NoPost, PostInputs, Stage, Copy, begin_load_pass
from app.shadow_pass import begin_depth_pass, record_atlas
from app.gpu_mesh import GpuMeshCache, cam_floats
from app.render_res import RenderResources, PointLight
from app.lights import SpotLight, DirLight, AreaLight, Environment, L_SUN_DIR
from app.cull import MeshBounds, ShadowReach, visible_items
from app.lens import coc_scale
from app.skin_pass import build_palette, rot_y
from app.textures import TextureArray, box_levels, checker_base
from app.debug_view import DEBUG_NONE, DEBUG_SKY, debug_recolor
from geometry.mat import Mat4

comptime DEPTH_FORMAT = WGPUTextureFormat.Depth32Float
comptime CLEAR = WGPUColor(0.55, 0.68, 0.85, 1.0)
comptime DefaultPasses = Then[PrimitivePass, Then[MeshPass, SkinnedPass]]
comptime SceneRenderer = SceneRendererOf[DefaultPasses]


struct SceneRendererOf[P: RenderPass, F: PostEffect = NoPost, A: AuxTarget = NoAux](Movable):
    var passes: Self.P
    var post: Self.F  # the post-processing stages (app/post.mojo); NoPost draws straight into the frame
    var post_time: Float32  # Frame.t.x of the stages: seconds, set by the host (0 keeps a still frame repeatable)
    var post_frame: Int  # Frame.t.y: counts draw() calls
    var post_seed: Float32  # Frame.t.z
    var post_user: SIMD[DType.float32, 4]  # Frame.user: four numbers of the host's, read by its styles
    var color_format: UInt32
    var scene: Optional[Texture]  # the passes' colour target while post is on
    var scene_view: Optional[TextureView]
    var aux_passes: Self.A  # the aux target's own pass list (app/render_pass.mojo Aux); NoAux draws nothing
    var aux: Optional[Texture]
    var aux_view: Optional[TextureView]
    var aux_depth: Optional[Texture]
    var aux_depth_view: Optional[TextureView]
    var kept: Optional[Texture]  # F.HISTORY: the stages draw here, and it is copied to the frame and to `prev`
    var kept_view: Optional[TextureView]
    var prev: Optional[Texture]
    var prev_view: Optional[TextureView]
    var blit: Optional[Stage[Copy]]
    var hud_depth: Optional[Texture]  # F.SCENE_W: a frame-size depth buffer for the HUD's pass (the scene's is smaller)
    var hud_depth_view: Optional[TextureView]
    var scene2: Optional[Texture]  # F.VIEWS == 2: the right eye's colour and depth
    var scene2_view: Optional[TextureView]
    var depth2: Optional[Texture]
    var depth2_view: Optional[TextureView]
    var eye_sep: Float32  # F.VIEWS == 2: the distance between the eyes, metres
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
    var cull: Bool  # drop the items that cannot change a pixel of the view before the passes see them (app/cull.mojo)
    var culled: Int  # how many the latest draw() dropped
    var cull_shadow_reach: Float64  # how far (m) a caster's sun shadow is followed when deciding to keep it
    var bounds: MeshBounds
    # the lens (app/lens.mojo's stages read these through the Frame uniform)
    var lens_focus: Float32  # the distance in focus, metres
    var lens_fstop: Float32  # the aperture as an f-number; 0 is a pinhole (everything sharp)
    var lens_sensor: Float32  # the sensor's height, metres (0.024: a 35 mm frame)
    var lens_max_coc: Float32  # the largest blur circle drawn, pixels across
    var shutter: Float32  # the part of the time between two frames the shutter is open, 0 .. 1 (0: no motion blur)
    var reduce_motion: Bool  # the player's reduce-motion switch (game/access.mojo): the lens stages then see no blur circle and a closed shutter
    var prev_cam: List[Float32]  # the previous draw()'s camera (cam_floats), empty before the first

    def __init__(out self, device: Device, color_format: UInt32, view: View, texture_layers: UInt32 = 2,
                 caps: RenderCaps = RenderCaps.default()) raises:
        caps.check()
        # layer 0 white, layer 1 the placeholder checker; a game that loads more textures asks for more layers
        var tex = TextureArray(device, texture_layers)
        tex.load_layer(device, UInt32(1), box_levels(checker_base()))
        self.res = RenderResources(device)
        self.passes = Self.P.create(device, color_format, DEPTH_FORMAT, tex, self.res, caps)  # before the move: they read the array's views
        self.post = Self.F.create(device, color_format)
        self.aux_passes = Self.A.create(device, color_format, DEPTH_FORMAT, tex, self.res, caps)
        self.aux = None
        self.aux_view = None
        self.aux_depth = None
        self.aux_depth_view = None
        self.kept = None
        self.kept_view = None
        self.prev = None
        self.prev_view = None
        self.blit = None
        self.hud_depth = None
        self.hud_depth_view = None
        self.scene2 = None
        self.scene2_view = None
        self.depth2 = None
        self.depth2_view = None
        self.eye_sep = 0.065
        comptime if Self.F.HISTORY:
            self.blit = Stage[Copy](device, color_format)
        self.post_time = 0.0
        self.post_frame = 0
        self.post_seed = 0.0
        self.post_user = SIMD[DType.float32, 4](0.0)
        self.color_format = color_format
        self.scene = None
        self.scene_view = None
        self.textures = tex^
        self.meshes = MeshRegistry()
        self.gpu = GpuMeshCache()
        self.cube = add_unit_cube(self.meshes)
        self.sphere = add_unit_sphere(self.meshes)
        self.res.unit_cube = self.cube
        self.res.unit_sphere = self.sphere
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
        self.cull = False
        self.culled = 0
        self.cull_shadow_reach = 100.0
        self.bounds = MeshBounds()
        self.lens_focus = 5.0
        self.lens_fstop = 0.0
        self.lens_sensor = 0.024
        self.lens_max_coc = 24.0
        self.shutter = 0.0
        self.reduce_motion = False
        self.prev_cam = List[Float32]()
        self.floor = List[DrawItem]()
        self.items = List[DrawItem]()
        self.depth = None
        self.depth_view = None
        self.depth_w = 0
        self.depth_h = 0

    def __init__(out self, *, deinit move: Self):
        self.passes = move.passes^
        self.post = move.post^
        self.post_time = move.post_time
        self.post_frame = move.post_frame
        self.post_seed = move.post_seed
        self.post_user = move.post_user
        self.color_format = move.color_format
        self.scene = move.scene^
        self.scene_view = move.scene_view^
        self.aux_passes = move.aux_passes^
        self.aux = move.aux^
        self.aux_view = move.aux_view^
        self.aux_depth = move.aux_depth^
        self.aux_depth_view = move.aux_depth_view^
        self.kept = move.kept^
        self.kept_view = move.kept_view^
        self.prev = move.prev^
        self.prev_view = move.prev_view^
        self.blit = move.blit^
        self.hud_depth = move.hud_depth^
        self.hud_depth_view = move.hud_depth_view^
        self.scene2 = move.scene2^
        self.scene2_view = move.scene2_view^
        self.depth2 = move.depth2^
        self.depth2_view = move.depth2_view^
        self.eye_sep = move.eye_sep
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
        self.cull = move.cull
        self.culled = move.culled
        self.cull_shadow_reach = move.cull_shadow_reach
        self.bounds = move.bounds^
        self.lens_focus = move.lens_focus
        self.lens_fstop = move.lens_fstop
        self.lens_sensor = move.lens_sensor
        self.lens_max_coc = move.lens_max_coc
        self.shutter = move.shutter
        self.reduce_motion = move.reduce_motion
        self.prev_cam = move.prev_cam^
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

    def set_spot_lights(mut self, device: Device, lights: List[SpotLight]) raises:
        """RenderResources.set_spot_lights: cones of light, each with a shadow if asked (app/lights.mojo)."""
        self.res.set_spot_lights(device, lights)

    def set_dir_lights(mut self, device: Device, lights: List[DirLight]) raises:
        self.res.set_dir_lights(device, lights)

    def set_area_lights(mut self, device: Device, lights: List[AreaLight]) raises:
        self.res.set_area_lights(device, lights)

    def set_sun(mut self, device: Device, to_sun: Vec3, color: Vec3, intensity: Float32) raises:
        """The sun's direction, colour and intensity (RenderResources.set_sun)."""
        self.res.set_sun(device, to_sun, color, intensity)

    def set_environment(mut self, device: Device, env: Environment) raises:
        """The ambient light and MatPbr's reflections from an environment (RenderResources.set_environment)."""
        self.res.set_environment(device, env)

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
        """The targets, made when the frame's size changes. With stages the scene's colour, depth and aux are F's
        scene size (the frame's unless SceneSize names one), and the stages are bound to them."""
        if not self.depth_view or self.depth_w != width or self.depth_h != height:
            self.depth_view = None
            var usage = WGPUTextureUsage.RENDER_ATTACHMENT
            var sw = width
            var sh = height
            comptime if Self.F.ON:  # the stages read depth
                usage = WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING
            comptime if Self.F.SCENE_W > 0:
                sw = UInt32(Self.F.SCENE_W)
                sh = UInt32(Self.F.SCENE_H)
            self.depth = device.create_texture(sw, sh, 1, DEPTH_FORMAT, usage, label="scene_depth")
            self.depth_view = self.depth.value().create_view_default()
            self.depth_w = width
            self.depth_h = height
            comptime if Self.F.ON:
                var both = WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING
                self.scene_view = None
                self.scene = device.create_texture(sw, sh, 1, self.color_format, both, label="scene_scene")
                self.scene_view = self.scene.value().create_view_default()
                comptime if Self.F.SCENE_W > 0:
                    self.hud_depth_view = None
                    self.hud_depth = device.create_texture(
                        width, height, 1, DEPTH_FORMAT, WGPUTextureUsage.RENDER_ATTACHMENT, label="scene_hud_depth",
                    )
                    self.hud_depth_view = self.hud_depth.value().create_view_default()
                else:
                    self.hud_depth_view = self.depth_view.value().clone()
                comptime if Self.A.ON:
                    self.aux_view = None
                    self.aux_depth_view = None
                    self.aux = device.create_texture(sw, sh, 1, self.color_format, both, label="scene_aux")
                    self.aux_view = self.aux.value().create_view_default()
                    self.aux_depth = device.create_texture(
                        sw, sh, 1, DEPTH_FORMAT, WGPUTextureUsage.RENDER_ATTACHMENT, label="scene_aux_depth",
                    )
                    self.aux_depth_view = self.aux_depth.value().create_view_default()
                else:
                    self.aux_view = self.scene_view.value().clone()
                comptime if Self.F.HISTORY:
                    self.kept_view = None
                    self.prev_view = None
                    self.kept = device.create_texture(width, height, 1, self.color_format, both, label="scene_kept")
                    self.kept_view = self.kept.value().create_view_default()
                    self.prev = device.create_texture(width, height, 1, self.color_format, both, label="scene_prev")
                    self.prev_view = self.prev.value().create_view_default()
                else:
                    self.prev_view = self.scene_view.value().clone()
                var inp = PostInputs(
                    self.scene_view.value(), self.scene_view.value(), self.depth_view.value(), self.aux_view.value(),
                    self.prev_view.value(),
                )
                comptime if Self.F.VIEWS == 2:
                    self.scene2_view = None
                    self.depth2_view = None
                    self.scene2 = device.create_texture(sw, sh, 1, self.color_format, both, label="scene_scene_right")
                    self.scene2_view = self.scene2.value().create_view_default()
                    self.depth2 = device.create_texture(sw, sh, 1, DEPTH_FORMAT, WGPUTextureUsage.RENDER_ATTACHMENT, label="scene_depth_right")
                    self.depth2_view = self.depth2.value().create_view_default()
                    inp = inp.with_src2(self.scene_view.value(), self.scene2_view.value())
                self.post.bind(device, self.color_format, width, height, inp)
                comptime if Self.F.HISTORY:
                    # the blit must not hold `prev` (it draws into it): every input but its source is the scene
                    var binp = PostInputs(
                        self.kept_view.value(), self.scene_view.value(), self.depth_view.value(), self.scene_view.value(),
                        self.scene_view.value(),
                    )
                    self.blit.value().bind(device, self.color_format, width, height, binp)

    def _post_frame(self, v: View, width: UInt32, height: UInt32) -> List[Float32]:
        var f = List[Float32]()
        for x in [Float32(width), Float32(height), Float32(1.0) / Float32(width), Float32(1.0) / Float32(height)]:
            f.append(x)
        for x in cam_floats(v):
            f.append(x)
        for x in [self.post_time, Float32(self.post_frame), self.post_seed, Float32(0.0)]:
            f.append(x)
        for i in range(4):
            f.append(self.post_user[i])
        f.append(self.lens_focus)
        f.append(Float32(0.0) if self.reduce_motion else coc_scale(v, self.lens_focus, self.lens_fstop, self.lens_sensor, Float32(height)))
        f.append(self.lens_max_coc)
        f.append(Float32(0.0) if self.reduce_motion else self.shutter)
        var now = cam_floats(v)
        for i in range(16):
            f.append(self.prev_cam[i] if len(self.prev_cam) == 16 else now[i])
        return f^

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
        self.culled = 0
        if self.cull:
            var sun = Vec3(Real(0.4), Real(1.0), Real(0.6), Real(0)) * Real(1.0 / 1.2328828)
            if self.res.rig[L_SUN_DIR + 3] > 0.5:
                sun = Vec3(Real(self.res.rig[L_SUN_DIR]), Real(self.res.rig[L_SUN_DIR + 1]), Real(self.res.rig[L_SUN_DIR + 2]), Real(0))
            var casting = List[Vec3]()
            for l in self.res.points:
                if l.shadow:
                    casting.append(Vec3(l.pos[0], l.pos[1], l.pos[2], Real(l.range)))
            for l in self.res.spots:
                if l.shadow:
                    casting.append(Vec3(l.pos[0], l.pos[1], l.pos[2], Real(l.range)))
            for l in self.res.dirs:
                if l.shadow:  # everything that can reach the light's box
                    casting.append(Vec3(l.centre[0], l.centre[1], l.centre[2], Real(l.half_extent * 1.5 + l.depth)))
            for l in self.res.areas:
                if l.shadow:
                    casting.append(Vec3(l.pos[0], l.pos[1], l.pos[2], Real(l.shadow_range)))
            var reach = ShadowReach(self.res.shadow_on, sun, self.cull_shadow_reach, casting^)
            var pad = 0.0
            comptime if Self.F.VIEWS == 2:
                pad = Float64(self.eye_sep) * 0.5
            var kept = visible_items(self.items, v, self.meshes, self.bounds, reach, pad)
            self.culled = len(self.items) - len(kept)
            self.items = kept^
        self.res.debug_sky(device, self.debug_view == DEBUG_SKY)
        hud.upload(device)
        self._depth_view(device, width, height)
        comptime if Self.F.VIEWS == 2:  # the right eye first, in its own command buffer; then v is the left eye
            var h = Real(self.eye_sep) * Real(0.5)
            var vr = v.copy()
            vr.eye = Vec3(v.eye[0] + v.right[0] * h, v.eye[1] + v.right[1] * h, v.eye[2] + v.right[2] * h, Real(0.0))
            v.eye = Vec3(v.eye[0] - v.right[0] * h, v.eye[1] - v.right[1] * h, v.eye[2] - v.right[2] * h, Real(0.0))
            self.res.write_camera(device, vr)
            self.passes.prepare(device, self.items, self.meshes, self.gpu, self.skin_palette, vr, self.res)
            var renc = device.create_command_encoder("right_eye")
            comptime if Self.P.SHADOW:
                if self.res.shadow_on:
                    var rsp = begin_depth_pass(renc, self.res.shadow_view)
                    self.passes.record_shadow(rsp, self.meshes, self.gpu)
                    rsp^.end()
                if self.res.tiles > 0:
                    record_atlas(self.passes, renc, self.res, self.meshes, self.gpu)
            var rpass2 = renc.begin_render_pass_clear_depth(
                self.scene2_view.value().clone(), self.depth2_view.value(), CLEAR, 1.0, "scene_pass_right",
            )
            self.passes.record_color(rpass2, self.meshes, self.gpu)
            rpass2^.end()
            var rcmd = renc^.finish()
            device.queue_submit(rcmd^)
        self.res.write_camera(device, v)
        self.passes.prepare(device, self.items, self.meshes, self.gpu, self.skin_palette, v, self.res)
        comptime if Self.F.ON:
            var pf = self._post_frame(v, width, height)
            self.post.update(device, pf)
            self.prev_cam = cam_floats(v)
            comptime if Self.F.HISTORY:
                self.blit.value().update(device, pf)
            comptime if Self.A.ON:
                self.aux_passes.prepare(device, self.items, self.meshes, self.gpu, self.skin_palette, v, self.res)
            self.post_frame += 1
        var enc = device.create_command_encoder("frame")
        comptime if Self.P.SHADOW:  # a shadow pass in the list: the depth pass first, in this command buffer
            if self.res.shadow_on:
                var srp = begin_depth_pass(enc, self.res.shadow_view)
                self.passes.record_shadow(srp, self.meshes, self.gpu)
                srp^.end()
            if self.res.tiles > 0:
                record_atlas(self.passes, enc, self.res, self.meshes, self.gpu)
        comptime if Self.F.ON:  # the passes into the scene target, the aux list into its own, then the stages
            var spass = enc.begin_render_pass_clear_depth(
                self.scene_view.value().clone(), self.depth_view.value(), CLEAR, 1.0, "scene_pass",
            )
            self.passes.record_color(spass, self.meshes, self.gpu)
            spass^.end()
            comptime if Self.A.ON:
                var apass = enc.begin_render_pass_clear_depth(
                    self.aux_view.value().clone(), self.aux_depth_view.value(), WGPUColor(0.5, 0.5, 1.0, 0.0), 1.0, "aux_pass",
                )
                self.aux_passes.record(apass, self.meshes, self.gpu)
                apass^.end()
            comptime if Self.F.HISTORY:  # into the kept frame, which is then copied to the frame and to `prev`
                self.post.record(enc, self.kept_view.value().clone())
                self.blit.value().record(enc, device.create_texture_view(target))
                self.blit.value().record(enc, self.prev_view.value().clone())
            else:
                self.post.record(enc, device.create_texture_view(target))
            # the HUD on top of the finished frame, not through the stages
            var hpass = begin_load_pass(device, enc, device.create_texture_view(target), self.hud_depth_view.value())
            hud.record(hpass)
            hpass^.end()
        else:
            var rpass = enc.begin_surface_clear_pass_depth(target, self.depth_view.value(), CLEAR, 1.0, "scene_pass")
            self.passes.record_color(rpass, self.meshes, self.gpu)
            hud.record(rpass)
            rpass^.end()
        var cmd = enc^.finish()
        device.queue_submit(cmd^)
