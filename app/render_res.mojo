"""What every pass of the scene renderer binds and the host sets (plan 2.4a): the camera header, the sun's shadow map
and its uniform (light view-projection, on-flag, atmosphere), and the ambient-occlusion grid. One per renderer; the
mesh and skinned passes bind these buffers, a shadow pass renders into `shadow_tex`.

Everything here is off by default (identity light, shadow off, atmosphere off, AO off): a pass bound to it draws the
colour it drew before the option existed, bit for bit.
"""
from wgpu import WGPUBufferUsage
from wgpu import WGPUTextureFormat, WGPUTextureUsage, WGPUOrigin3D, WGPUTextureAspect
from wgpu.buffer import Buffer
from wgpu import null_opaque
from wgpu import WGPUStringView, WGPUTextureViewDescriptor
from wgpu import raw_alloc
from wgpu.device import Device
from wgpu.sampler import Sampler
from wgpu.texture import Texture, TextureView
from game.camera_view import View
from std.math import cos
from geometry.vec import Real, Vec3
from app.gpu_mesh import cam_floats
from app.gpu_bytes import texture_bytes
from app.lights import (
    SpotLight, DirLight, AreaLight, Environment, unit, spot_vp, point_face_vp, dir_vp, area_vp, area_size, ATLAS_SIZE, MAX_TILES,
    MAX_SPOT_LIGHTS, MAX_DIR_LIGHTS, MAX_AREA_LIGHTS, LIGHTS_FLOATS, MAX_CASCADES, TILE_MIN,
    L_POINTS, L_SUN_DIR, L_SUN_COLOR, L_AMB, L_SH, L_ENV_TOP, L_ENV_HOR, L_ENV_GND, L_PSHADOW, L_SPOTS, L_DIRS, L_AREAS, L_TILES,
    L_TILE_RECT, L_PROBE_ORG, L_PROBE_CELL, L_PROBE_DIM, atlas_sizes, atlas_place, cascade_splits, cascade_sphere, cascade_vp,
)

comptime ENV_SIZE = 128  # the environment cube map's faces
comptime ENV_MIPS = 8  # 128 down to 1


def env_sub_view(tex: Texture, dimension: Int, mip: Int, mips: Int, layer: Int, layers: Int) raises -> TextureView:
    """A view of part of a layered texture: dimension 2 (one face as a 2D texture) or 4 (a cube)."""
    var d = raw_alloc[WGPUTextureViewDescriptor](1)
    d[unsafe_offset=0] = WGPUTextureViewDescriptor(
        null_opaque(), WGPUStringView.null_view(), UInt32(0), UInt32(dimension), UInt32(mip), UInt32(mips),
        UInt32(layer), UInt32(layers), UInt32(1), UInt64(0),
    )
    var v = tex.create_view(d)
    d.unsafe_free()
    return v^


comptime SHADOW_MAP_SIZE = 1024  # the sun's shadow map before set_sun_cascades, square; 4 MB of depth
comptime SHADOW_UBO_BYTES = 432  # the `Shadow` uniform (app/wgsl.mojo SHADOW_UBO_WGSL): 108 floats
comptime SHADOW_BIAS = Float32(0.003)  # a fixed box's depth bias (NDC), as before cascades
comptime AO_MAX_CELLS = 16384  # the ambient-occlusion grid: up to 128 by 128 floats over the floor (64 KB)
comptime MAX_MESH_INSTANCES = 8192  # default: mesh and skinned instances per frame: 8192 x 24 floats = 768 KB
comptime DEFAULT_PRIMITIVE_INSTANCES = 8192  # default: primitive items per frame
comptime MAX_POINT_LIGHTS = 16  # app/wgsl.mojo POINT_LIGHTS_WGSL's array size
comptime LIGHTS_BYTES = LIGHTS_FLOATS * 4  # the `Lights` uniform (app/lights.mojo): the point lights first, as before
comptime MAX_PROBES = 2048  # irradiance probes (app/irradiance.mojo), e.g. 16 x 8 x 16
comptime PROBE_BYTES = MAX_PROBES * 9 * 16  # 9 vec4 per probe: 288 KB, always bound to the mesh and skinned passes
comptime DEFAULT_PALETTE_MATRICES = 4096  # default: skinning matrices per frame (64 instances x 64 joints, 256 KB)


struct RenderCaps(Copyable, ImplicitlyCopyable, Movable):
    """Per-frame capacities, chosen when the renderer is made (ludens-engine#71): primitive items, mesh and skinned instances
    (each pass's instance buffer) and skinning matrices (the palette buffers of the skinned and the shadow pass). The
    buffers are sized from these; a frame past one raises in the pass that holds it."""

    var primitive_instances: Int
    var mesh_instances: Int
    var palette_matrices: Int
    var samples: Int  # 1, or 4 for MSAA (app/msaa.mojo): the sample count of every pipeline drawn into the scene's colour target

    def __init__(out self, primitive_instances: Int, mesh_instances: Int, palette_matrices: Int, samples: Int = 1):
        self.primitive_instances = primitive_instances
        self.mesh_instances = mesh_instances
        self.palette_matrices = palette_matrices
        self.samples = samples

    @staticmethod
    def default() -> Self:
        return Self(DEFAULT_PRIMITIVE_INSTANCES, MAX_MESH_INSTANCES, DEFAULT_PALETTE_MATRICES)

    def check(self) raises:
        if self.primitive_instances < 1 or self.mesh_instances < 1 or self.palette_matrices < 1:
            raise Error("RenderCaps: every capacity must be at least 1")
        if self.samples != 1 and self.samples != 4:
            raise Error("RenderCaps: samples is 1 or 4, the counts every WebGPU device supports for a renderable format")


struct PointLight(Copyable, ImplicitlyCopyable, Movable):
    """A point light: position (m), range (m; no light beyond it, falling off as (1 - (d / range)^2)^2), colour (linear
    0..1 per channel) and intensity (a multiplier on the colour, at the light). With `shadow` it takes six tiles of the
    shadow atlas (app/lights.mojo)."""

    var pos: Vec3
    var range: Float32
    var color: Vec3
    var intensity: Float32
    var shadow: Bool

    def __init__(out self, pos: Vec3, range: Float32, color: Vec3, intensity: Float32, shadow: Bool = False):
        self.pos = pos
        self.range = range
        self.color = color
        self.intensity = intensity
        self.shadow = shadow


struct RenderResources(Movable):
    var camera: Buffer  # the camera header (64 bytes, app/gpu_mesh.mojo cam_floats), written once per frame
    var shadow_tex: Texture  # the shadow map: a shadow pass renders depth into it (shadow_target())
    var shadow_view: TextureView
    var shadow_sampler: Sampler  # comparison sampler, LessEqual
    var shadow_ubo: Buffer  # light view-projection (64 bytes), params (16 bytes; params.x 1 turns the shadow on), atmosphere (48 bytes)
    var ao_cells: Buffer  # the AO grid: AO_MAX_CELLS floats, all 1 (open) until set_ao
    var ao_ubo: Buffer  # AO extent, dims and the on-flag (48 bytes)
    var lights: Buffer  # the point lights (LIGHTS_BYTES): count, then MAX_POINT_LIGHTS records; none until set_lights
    var atmo_fog: Bool  # the flags of the latest set_atmosphere, restored after a DEBUG_SKY frame (debug_sky)
    var atmo_linear: Bool
    var sky_overridden: Bool
    var light_vp: List[Float32]  # the latest set_shadow's light view-projection (a shadow pass in the pass list draws with it)
    var shadow_on: Bool  # the latest set_shadow's on-flag
    var rig: List[Float32]  # the `Lights` uniform as last written (LIGHTS_FLOATS)
    var points: List[PointLight]  # the lights as last set: the atlas tiles are assigned from these
    var spots: List[SpotLight]
    var dirs: List[DirLight]
    var areas: List[AreaLight]
    var atlas_tex: Texture  # the spot and point lights' shadow atlas: 4 x 4 tiles of depth
    var atlas_view: TextureView
    var tiles: Int  # atlas tiles in use this frame; a shadow pass draws tile k with tile_vp(k)
    var env_tex: Texture  # the environment cube map MatPbr reflects (app/env_probe.mojo fills it): 6 faces, ENV_MIPS mips
    var env_view: TextureView
    var unit_cube: Int  # the mesh ids of the renderer's unit cube and sphere (boxes and spheres drawn as meshes)
    var unit_sphere: Int
    var probes: Buffer  # the irradiance probes' harmonics (PROBE_BYTES), read while the grid is on (set_probes)
    var gen: Int  # counts the times a bound texture was made again (shadow map, atlas): the passes rebuild their groups
    var shadow_size: Int  # the sun's shadow map, texels across (SHADOW_MAP_SIZE, or 2 x the cascade size with cascades)
    var atlas_size: Int  # the atlas, texels across (ATLAS_SIZE until set_shadow_atlas)
    var sun_count: Int  # cascades drawn into the sun's map: 1 for a fixed box (set_shadow)
    var sun_res: Int  # a cascade's texels across
    var sun_vps: List[Float32]  # 16 floats per cascade, this frame's
    var casc_count: Int  # set_sun_cascades: 0 for a fixed box
    var casc_distance: Float64
    var casc_lambda: Float64
    var casc_blend: Float64
    var casc_reach: Float64
    var tile_sizes: List[Int]  # per light with a shadow (points, spots, dirs, areas in that order): its tiles' size
    var tile_px: List[Int]  # per tile: x, y, size in texels
    # the screen-space mask (app/contact_shadows.mojo): scene-sized while a user needs it, 1 x 1 white otherwise
    var screen_users: Int  # bit 0 contact shadows, bit 1 ambient occlusion: which effects read `screen_mask`
    var screen_w: Int  # the size the scene depth and mask were made for; 0 while the mask is the 1 x 1 white one
    var screen_h: Int
    var screen_mask: Texture  # RGBA8Unorm: R the sun's contact shadow, G ambient occlusion (1 lit / open), B, A 1
    var screen_mask_view: TextureView
    var scene_depth: Optional[Texture]  # Depth32Float, single-sample: the frame's meshes drawn from the camera (contact shadows)
    var scene_depth_view: Optional[TextureView]
    var contact_on: Bool
    var contact_distance: Float64  # metres a ray follows toward the sun
    var contact_steps: Int
    var contact_thickness: Float64  # metres: a surface further in front of the ray than this is not an occluder
    var contact_strength: Float64

    def texture_bytes(self) raises -> Int:
        """Size of the textures this struct creates: the shadow atlas, the environment cube and the shadow map (sizes are
        constants, not read back: app/gpu_bytes.mojo)."""
        return (
            texture_bytes(self.atlas_size, self.atlas_size, 1, 1, WGPUTextureFormat.Depth32Float)
            + texture_bytes(ENV_SIZE, ENV_SIZE, 6, ENV_MIPS, WGPUTextureFormat.RGBA8Unorm)
            + texture_bytes(self.shadow_size, self.shadow_size, 1, 1, WGPUTextureFormat.Depth32Float)
            + texture_bytes(max(self.screen_w, 1), max(self.screen_h, 1), 1, 1, WGPUTextureFormat.RGBA8Unorm)
            + (texture_bytes(self.screen_w, self.screen_h, 1, 1, WGPUTextureFormat.Depth32Float) if self.screen_w > 0 else 0)
        )

    def __init__(out self, device: Device) raises:
        self.light_vp = List[Float32]()
        self.shadow_on = False
        self.lights = device.create_buffer(UInt64(LIGHTS_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="lights")
        self.rig = List[Float32](length=LIGHTS_FLOATS, fill=Float32(0))
        for c in range(3):
            self.rig[L_SUN_COLOR + c] = 0.6
        device.queue_write_data(self.lights, UInt64(0), self.rig)
        self.points = List[PointLight]()
        self.spots = List[SpotLight]()
        self.dirs = List[DirLight]()
        self.areas = List[AreaLight]()
        self.tiles = 0
        self.gen = 0
        self.shadow_size = SHADOW_MAP_SIZE
        self.atlas_size = ATLAS_SIZE
        self.sun_count = 1
        self.sun_res = SHADOW_MAP_SIZE
        self.sun_vps = List[Float32]()
        self.casc_count = 0
        self.casc_distance = 100.0
        self.casc_lambda = 0.75
        self.casc_blend = 0.1
        self.casc_reach = 50.0
        self.tile_sizes = List[Int]()
        self.tile_px = List[Int]()
        self.screen_users = 0
        self.screen_w = 0
        self.screen_h = 0
        self.scene_depth = None
        self.scene_depth_view = None
        self.contact_on = False
        self.contact_distance = 0.6
        self.contact_steps = 16
        self.contact_thickness = 0.3
        self.contact_strength = 1.0
        self.screen_mask = device.create_texture(
            UInt32(1), UInt32(1), UInt32(1), WGPUTextureFormat.RGBA8Unorm,
            WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.STORAGE_BINDING | WGPUTextureUsage.COPY_DST,
            dimension=2, mip_level_count=1, label="screen_mask",
        )
        self.screen_mask_view = self.screen_mask.create_view_default()
        device.queue_write_texture(
            self.screen_mask, UInt32(0), WGPUOrigin3D(UInt32(0), UInt32(0), UInt32(0)), WGPUTextureAspect.All,
            List[UInt8](length=4, fill=UInt8(255)), UInt32(4), UInt32(1), UInt32(1), UInt32(1), UInt32(1),
        )
        self.atlas_tex = device.create_texture(
            UInt32(ATLAS_SIZE), UInt32(ATLAS_SIZE), UInt32(1), WGPUTextureFormat.Depth32Float,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=1, label="shadow_atlas",
        )
        self.atlas_view = self.atlas_tex.create_view_default()
        self.env_tex = device.create_texture(
            UInt32(ENV_SIZE), UInt32(ENV_SIZE), UInt32(6), WGPUTextureFormat.RGBA8Unorm,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=UInt32(ENV_MIPS), label="env_cube",
        )
        self.env_view = env_sub_view(self.env_tex, 4, 0, ENV_MIPS, 0, 6)
        self.unit_cube = 0
        self.unit_sphere = 1
        self.probes = device.create_buffer(UInt64(PROBE_BYTES), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="probes")
        device.queue_write_data(self.probes, UInt64(0), List[Float32](length=PROBE_BYTES // 4, fill=Float32(0)))
        self.camera = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_cam")
        # shadow resources, always bound; with the shadow off the sampled value is ignored (factor 1.0)
        self.shadow_tex = device.create_texture(
            UInt32(SHADOW_MAP_SIZE), UInt32(SHADOW_MAP_SIZE), UInt32(1), WGPUTextureFormat.Depth32Float,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=1, label="mesh_shadow_map",
        )
        self.shadow_view = self.shadow_tex.create_view_default()
        self.atmo_fog = False
        self.atmo_linear = False
        self.sky_overridden = False
        self.shadow_sampler = device.create_sampler(mag_filter=1, min_filter=1, mipmap_filter=1, compare=UInt32(4), label="mesh_shadow_cmp")
        self.shadow_ubo = device.create_buffer(
            UInt64(SHADOW_UBO_BYTES), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_shadow_ubo",
        )
        var off = List[Float32]()  # identity light matrix, shadow off
        for c in range(16):
            off.append(Float32(1.0) if c % 5 == 0 else Float32(0.0))
        for c in range(16):  # params, then the atmosphere's three vec4: all off
            off.append(0.0)
        device.queue_write_data(self.shadow_ubo, UInt64(0), off)

        self.ao_cells = device.create_buffer(
            UInt64(AO_MAX_CELLS * 4), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="mesh_ao_cells",
        )
        self.ao_ubo = device.create_buffer(UInt64(48), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_ao_ubo")
        var ones = List[Float32]()
        for _ in range(AO_MAX_CELLS):
            ones.append(1.0)
        device.queue_write_data(self.ao_cells, UInt64(0), ones)
        var ao_off = List[Float32]()  # AO off: extent, dims and params all zero, the factor is 1
        for _ in range(12):
            ao_off.append(0.0)
        device.queue_write_data(self.ao_ubo, UInt64(0), ao_off)
        var ident = List[Float32]()
        for c in range(16):
            ident.append(Float32(1.0) if c % 5 == 0 else Float32(0.0))
        self._write_sun(device, ident, 1, False)

    def _put3(mut self, at: Int, v: Vec3, w: Float32):
        for c in range(3):
            self.rig[at + c] = Float32(v[c])
        self.rig[at + 3] = w

    def _upload(mut self, device: Device) raises:
        """Assign the atlas tiles (point lights first, six each; then spot lights) and write the uniform."""
        var next = 0
        for i in range(16):
            self.rig[L_PSHADOW + i] = 0.0
        for i in range(len(self.points)):
            if self.points[i].shadow:
                if next + 6 > MAX_TILES:
                    raise Error("renderer: the shadow atlas has " + String(MAX_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_PSHADOW + i] = Float32(next + 1)
                for f in range(6):
                    var m = point_face_vp(self.points[i].pos, f, Float64(self.points[i].range))
                    for k in range(16):
                        self.rig[L_TILES + 16 * (next + f) + k] = m[k]
                next += 6
        for i in range(len(self.spots)):
            self.rig[L_SPOTS + 16 * i + 13] = 0.0
            if self.spots[i].shadow:
                if next + 1 > MAX_TILES:
                    raise Error("renderer: the shadow atlas has " + String(MAX_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_SPOTS + 16 * i + 13] = Float32(next + 1)
                var m = spot_vp(self.spots[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        for i in range(len(self.dirs)):
            self.rig[L_DIRS + 8 * i + 3] = 0.0
            if self.dirs[i].shadow:
                if next + 1 > MAX_TILES:
                    raise Error("renderer: the shadow atlas has " + String(MAX_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_DIRS + 8 * i + 3] = Float32(next + 1)
                var m = dir_vp(self.dirs[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        for i in range(len(self.areas)):
            self.rig[L_AREAS + 16 * i + 3] = 0.0
            if self.areas[i].shadow:
                if next + 1 > MAX_TILES:
                    raise Error("renderer: the shadow atlas has " + String(MAX_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_AREAS + 16 * i + 3] = Float32(next + 1)
                self.rig[L_AREAS + 16 * i + 7] = self.areas[i].shadow_range
                self.rig[L_AREAS + 16 * i + 11] = Float32(area_size(self.areas[i]))
                var m = area_vp(self.areas[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        self.tiles = next
        self._fit_tiles(List[Float64]())
        device.queue_write_data(self.lights, UInt64(0), self.rig)

    def _shadow_lights(self) -> List[Int]:
        """Per light with a shadow, in tile order: its kind (0 point, 1 spot, 2 directional, 3 area) and index."""
        var out = List[Int]()
        for i in range(len(self.points)):
            if self.points[i].shadow:
                out.append(0); out.append(i)
        for i in range(len(self.spots)):
            if self.spots[i].shadow:
                out.append(1); out.append(i)
        for i in range(len(self.dirs)):
            if self.dirs[i].shadow:
                out.append(2); out.append(i)
        for i in range(len(self.areas)):
            if self.areas[i].shadow:
                out.append(3); out.append(i)
        return out^

    def _fit_tiles(mut self, scores: List[Float64]) raises:
        """Size and place the atlas tiles (app/lights.mojo atlas_sizes, atlas_place) and write their squares into the
        rig. `scores` per light with a shadow (empty: the order they were set in, later lights halved first)."""
        var who = self._shadow_lights()
        var n = len(who) // 2
        var faces = List[Int]()
        var sc = List[Float64]()
        for j in range(n):
            faces.append(6 if who[2 * j] == 0 else 1)
            sc.append(scores[j] if len(scores) == n else Float64(j))
        self.tile_sizes = atlas_sizes(faces, sc, self.atlas_size)
        var per_tile = List[Int]()
        for j in range(n):
            for _ in range(faces[j]):
                per_tile.append(self.tile_sizes[j])
        var at = atlas_place(per_tile, self.atlas_size)
        self.tile_px = List[Int]()
        var a = Float32(self.atlas_size)
        for k in range(len(per_tile)):
            self.tile_px.append(at[2 * k])
            self.tile_px.append(at[2 * k + 1])
            self.tile_px.append(per_tile[k])
            self.rig[L_TILE_RECT + 4 * k] = Float32(at[2 * k]) / a
            self.rig[L_TILE_RECT + 4 * k + 1] = Float32(at[2 * k + 1]) / a
            self.rig[L_TILE_RECT + 4 * k + 2] = Float32(per_tile[k]) / a
            self.rig[L_TILE_RECT + 4 * k + 3] = Float32(per_tile[k])

    def frame_shadows(mut self, device: Device, view: View) raises:
        """Per frame, before the passes prepare: the sun's cascades for this view (set_sun_cascades), and the atlas
        tiles sized by how near each light is to the camera (distance over range)."""
        if self.casc_count > 0:
            self._cascades(device, view)
        var who = self._shadow_lights()
        var n = len(who) // 2
        if n == 0:
            return
        var scores = List[Float64]()
        for j in range(n):
            var kind = who[2 * j]
            var i = who[2 * j + 1]
            var pos = Vec3(0, 0, 0, 0)
            var reach = 1.0
            if kind == 0:
                pos = self.points[i].pos
                reach = Float64(self.points[i].range)
            elif kind == 1:
                pos = self.spots[i].pos
                reach = Float64(self.spots[i].range)
            elif kind == 2:
                pos = self.dirs[i].centre
                reach = Float64(self.dirs[i].half_extent)
            else:
                pos = self.areas[i].pos
                reach = Float64(self.areas[i].shadow_range)
            var d = pos - view.eye
            var dist = (Float64(d[0]) * Float64(d[0]) + Float64(d[1]) * Float64(d[1]) + Float64(d[2]) * Float64(d[2])) ** 0.5
            scores.append(dist / max(reach, 1e-6))
        var before = self.tile_px.copy()
        self._fit_tiles(scores)
        var same = len(before) == len(self.tile_px)
        if same:
            for k in range(len(before)):
                if before[k] != self.tile_px[k]:
                    same = False
                    break
        if not same:
            var rect = List[Float32]()
            for k in range(4 * self.tiles):
                rect.append(self.rig[L_TILE_RECT + k])
            device.queue_write_data(self.lights, UInt64(L_TILE_RECT * 4), rect)

    def tile_place(self, k: Int) -> Tuple[Int, Int, Int]:
        """Tile k's square in the atlas: x, y and size in texels (the shadow pass's viewport)."""
        return (self.tile_px[3 * k], self.tile_px[3 * k + 1], self.tile_px[3 * k + 2])

    def ensure_screen(mut self, device: Device, w: Int, h: Int) raises:
        """Make the scene depth and the screen mask `w` by `h` while an effect needs them (screen_users), or the 1 x 1 white
        mask and no depth when none does. Counts gen when it makes them anew. The renderer calls it every draw."""
        var want_w = w if self.screen_users != 0 else 0
        var want_h = h if self.screen_users != 0 else 0
        if want_w == self.screen_w and want_h == self.screen_h:
            return
        self.screen_w = want_w
        self.screen_h = want_h
        if want_w == 0:
            self.scene_depth_view = None
            self.scene_depth = None
            self.screen_mask = device.create_texture(
                UInt32(1), UInt32(1), UInt32(1), WGPUTextureFormat.RGBA8Unorm,
                WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.STORAGE_BINDING | WGPUTextureUsage.COPY_DST,
                dimension=2, mip_level_count=1, label="screen_mask",
            )
            self.screen_mask_view = self.screen_mask.create_view_default()
            device.queue_write_texture(
                self.screen_mask, UInt32(0), WGPUOrigin3D(UInt32(0), UInt32(0), UInt32(0)), WGPUTextureAspect.All,
                List[UInt8](length=4, fill=UInt8(255)), UInt32(4), UInt32(1), UInt32(1), UInt32(1), UInt32(1),
            )
        else:
            self.scene_depth_view = None
            self.scene_depth = device.create_texture(
                UInt32(want_w), UInt32(want_h), UInt32(1), WGPUTextureFormat.Depth32Float,
                WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
                dimension=2, mip_level_count=1, label="scene_depth_prepass",
            )
            self.scene_depth_view = self.scene_depth.value().create_view_default()
            self.screen_mask = device.create_texture(
                UInt32(want_w), UInt32(want_h), UInt32(1), WGPUTextureFormat.RGBA8Unorm,
                WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.STORAGE_BINDING | WGPUTextureUsage.COPY_DST,
                dimension=2, mip_level_count=1, label="screen_mask",
            )
            self.screen_mask_view = self.screen_mask.create_view_default()
            # white until a pass fills it: a frame that never runs the compute (Stereo) sees no shadow and full ambient light
            device.queue_write_texture(
                self.screen_mask, UInt32(0), WGPUOrigin3D(UInt32(0), UInt32(0), UInt32(0)), WGPUTextureAspect.All,
                List[UInt8](length=want_w * want_h * 4, fill=UInt8(255)), UInt32(want_w * 4), UInt32(want_h),
                UInt32(want_w), UInt32(want_h), UInt32(1),
            )
        self.gen += 1

    def set_contact_shadows(
        mut self, device: Device, on: Bool, distance: Float64 = 0.6, steps: Int = 16, thickness: Float64 = 0.3,
        strength: Float64 = 1.0,
    ) raises:
        """Contact shadows (app/contact_shadows.mojo): the sun's shadow over its first `distance` metres, found by marching
        `steps` samples of the frame's depth toward the sun; a surface up to `thickness` metres in front of a sample hides
        it, and `strength` (0 .. 1) is how dark the shadow gets. Needs a ShadowPass in the pass list (it draws the depth). Off by
        default: the colour is then unchanged bit for bit, and no texture is made."""
        if not (distance > 0.0) or steps < 1 or steps > 64 or not (thickness > 0.0) or not (strength >= 0.0 and strength <= 1.0):
            raise Error("renderer: contact shadows need distance > 0, 1 .. 64 steps, thickness > 0 and 0 <= strength <= 1")
        self.contact_on = on
        self.contact_distance = distance
        self.contact_steps = steps
        self.contact_thickness = thickness
        self.contact_strength = strength
        self.screen_users = (self.screen_users | 1) if on else (self.screen_users & ~1)
        device.queue_write_data(self.shadow_ubo, UInt64(424), [Float32(self.screen_users)])

    def set_shadow_atlas(mut self, device: Device, size: Int) raises:
        """Make the atlas `size` texels across (a power of two, 1024 .. 8192; 2048 by default): tiles start at 512 and
        are halved for the least important lights until all fit, so a larger atlas keeps more of them at 512."""
        if size < 1024 or size > 8192 or (size & (size - 1)) != 0:
            raise Error("renderer: the shadow atlas is a power of two from 1024 to 8192 texels")
        if size == self.atlas_size:
            return
        self.atlas_size = size
        self.atlas_tex = device.create_texture(
            UInt32(size), UInt32(size), UInt32(1), WGPUTextureFormat.Depth32Float,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=1, label="shadow_atlas",
        )
        self.atlas_view = self.atlas_tex.create_view_default()
        self.gen += 1
        self._upload(device)

    def _sun_map(mut self, device: Device, size: Int) raises:
        if size == self.shadow_size:
            return
        self.shadow_size = size
        self.shadow_tex = device.create_texture(
            UInt32(size), UInt32(size), UInt32(1), WGPUTextureFormat.Depth32Float,
            WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            dimension=2, mip_level_count=1, label="mesh_shadow_map",
        )
        self.shadow_view = self.shadow_tex.create_view_default()
        self.gen += 1

    def _write_sun(mut self, device: Device, vps: List[Float32], count: Int, on: Bool, splits: List[Float64] = List[Float64](),
                   bias: List[Float32] = List[Float32]()) raises:
        """The `Shadow` uniform's sun part: cascade 0 as `vp`, the flags, then every cascade, the splits, biases and
        sizes. The atmosphere (floats 20 .. 31) is left as it is."""
        self.sun_vps = vps.copy()
        self.sun_count = count
        var head = List[Float32]()
        for k in range(16):
            head.append(vps[k])
        head.append(Float32(1.0) if on else Float32(0.0))
        head.append(Float32(count))
        head.append(Float32(self.casc_blend) if self.casc_count > 0 else Float32(0.0))
        head.append(0.0)
        device.queue_write_data(self.shadow_ubo, UInt64(0), head)
        var tail = List[Float32](length=76, fill=Float32(0))
        tail[74] = Float32(self.screen_users)  # info.z: which screen-space effects read the mask
        for k in range(16 * count):
            tail[k] = vps[k]
        for i in range(MAX_CASCADES):
            tail[64 + i] = Float32(splits[i + 1]) if i < count and len(splits) > count else Float32(1e30)
            tail[68 + i] = bias[i] if i < len(bias) else SHADOW_BIAS
        tail[72] = Float32(self.sun_res) / Float32(self.shadow_size)
        tail[73] = Float32(self.sun_res)
        device.queue_write_data(self.shadow_ubo, UInt64(128), tail)

    def set_sun_cascades(
        mut self, device: Device, count: Int = 4, distance: Float64 = 100.0, split_lambda: Float64 = 0.75,
        blend: Float64 = 0.1, reach: Float64 = 50.0, resolution: Int = 1024,
    ) raises:
        """The sun's shadow in `count` cascades along the view (1 .. 4), out to `distance` metres (or the view's far
        plane, if nearer): split by the practical scheme (`split_lambda` 0 even, 1 logarithmic), each `resolution`
        texels across (a 2 x 2 map for more than one), blending into the next over the last `blend` of its range, and
        catching casters up to `reach` metres toward the sun beyond it. The sun's direction is set_sun's. Replaces a
        box from set_shadow; set_shadow returns to one. The renderer recomputes the cascades every frame from its view."""
        if count < 1 or count > MAX_CASCADES:
            raise Error("renderer: the sun has 1 .. " + String(MAX_CASCADES) + " cascades")
        if not (distance > 0.0) or not (split_lambda >= 0.0 and split_lambda <= 1.0) or not (blend >= 0.0 and blend < 0.5) or not (reach >= 0.0):
            raise Error("renderer: cascades need distance > 0, 0 <= split_lambda <= 1, 0 <= blend < 0.5 and reach >= 0")
        if resolution < 256 or resolution > 4096 or (resolution & (resolution - 1)) != 0:
            raise Error("renderer: a cascade is a power of two from 256 to 4096 texels")
        self.casc_count = count
        self.casc_distance = distance
        self.casc_lambda = split_lambda
        self.casc_blend = blend
        self.casc_reach = reach
        self.sun_res = resolution
        self._sun_map(device, resolution if count == 1 else 2 * resolution)
        self.shadow_on = True

    def _cascades(mut self, device: Device, view: View) raises:
        var to_sun = Vec3(Real(0.4), Real(1.0), Real(0.6), Real(0))
        if self.rig[L_SUN_DIR + 3] > 0.5:
            to_sun = Vec3(Real(self.rig[L_SUN_DIR]), Real(self.rig[L_SUN_DIR + 1]), Real(self.rig[L_SUN_DIR + 2]), Real(0))
        var near = max(Float64(view.near), 0.01)
        var far = min(Float64(view.far), self.casc_distance)
        var splits = cascade_splits(near, max(far, near * 2.0), self.casc_count, self.casc_lambda)
        var vps = List[Float32]()
        var bias = List[Float32]()
        for i in range(self.casc_count):
            var z0 = splits[i]
            if i > 0:  # the blend band of the cascade before reaches into this one
                z0 = splits[i] - self.casc_blend * (splits[i] - splits[i - 1])
            var sph = cascade_sphere(view.eye, view.fwd, Float64(view.sx), Float64(view.sy), view.ortho, z0, splits[i + 1])
            var m = cascade_vp(to_sun, sph[0], sph[1], self.sun_res, self.casc_reach)
            for k in range(16):
                vps.append(m[k])
            # three texels of this cascade as depth: zs = 1 / (2 r + reach) (cascade_vp)
            var r = Float64(Int(sph[1] * 16.0) + 1) / 16.0
            bias.append(Float32(3.0 * 2.0 * r / Float64(self.sun_res) / (2.0 * r + self.casc_reach)))
        self._write_sun(device, vps, self.casc_count, self.shadow_on, splits, bias)

    def sun_vp(self, i: Int) -> List[Float32]:
        """Cascade i's view-projection (16 floats; cascade 0 is set_shadow's box without cascades)."""
        var m = List[Float32]()
        for k in range(16):
            m.append(self.sun_vps[16 * i + k])
        return m^

    def sun_place(self, i: Int) -> Tuple[Int, Int, Int]:
        """Cascade i's square in the sun's map: x, y, size in texels."""
        return ((i % 2) * self.sun_res, (i // 2) * self.sun_res, self.sun_res)

    def tile_vp(self, k: Int) -> List[Float32]:
        """The view-projection of atlas tile k (16 floats)."""
        var m = List[Float32]()
        for i in range(16):
            m.append(self.rig[L_TILES + 16 * k + i])
        return m^

    def set_lights(mut self, device: Device, lights: List[PointLight]) raises:
        """Replace the point lights (at most MAX_POINT_LIGHTS; an empty list turns them off). They light the
        primitives, the meshes and the skinned meshes per pixel, on top of the sun."""
        if len(lights) > MAX_POINT_LIGHTS:
            raise Error("renderer: at most " + String(MAX_POINT_LIGHTS) + " point lights, got " + String(len(lights)))
        for i in range(len(lights)):
            if not (lights[i].range > 0) or not (lights[i].intensity >= 0):
                raise Error("renderer: a point light needs range > 0 and intensity >= 0")
        for i in range(8 * MAX_POINT_LIGHTS):
            self.rig[L_POINTS + i] = 0.0
        self.rig[0] = Float32(len(lights))
        self.points = lights.copy()
        for i in range(len(lights)):
            self._put3(L_POINTS + 8 * i, lights[i].pos, lights[i].range)
            self._put3(L_POINTS + 8 * i + 4, lights[i].color, lights[i].intensity)
        self._upload(device)

    def set_spot_lights(mut self, device: Device, lights: List[SpotLight]) raises:
        """Replace the spot lights (at most MAX_SPOT_LIGHTS)."""
        if len(lights) > MAX_SPOT_LIGHTS:
            raise Error("renderer: at most " + String(MAX_SPOT_LIGHTS) + " spot lights, got " + String(len(lights)))
        for i in range(len(lights)):
            ref l = lights[i]
            if not (l.range > 0) or not (l.intensity >= 0) or not (l.inner >= 0) or not (l.outer > l.inner) or not (l.outer < 1.5):
                raise Error("renderer: a spot light needs range > 0, intensity >= 0 and 0 <= inner < outer < 1.5 rad")
        self.rig[1] = Float32(len(lights))
        self.spots = lights.copy()
        for i in range(len(lights)):
            var o = L_SPOTS + 16 * i
            self._put3(o, lights[i].pos, lights[i].range)
            self._put3(o + 4, lights[i].color, lights[i].intensity)
            self._put3(o + 8, unit(lights[i].dir), Float32(cos(lights[i].outer)))
            self.rig[o + 12] = Float32(cos(lights[i].inner))
        self._upload(device)

    def set_dir_lights(mut self, device: Device, lights: List[DirLight]) raises:
        """Replace the directional lights other than the sun (at most MAX_DIR_LIGHTS)."""
        if len(lights) > MAX_DIR_LIGHTS:
            raise Error("renderer: at most " + String(MAX_DIR_LIGHTS) + " directional lights, got " + String(len(lights)))
        self.rig[2] = Float32(len(lights))
        self.dirs = lights.copy()
        for i in range(len(lights)):
            if not (lights[i].intensity >= 0) or not (lights[i].half_extent > 0) or not (lights[i].depth > 0):
                raise Error("renderer: a directional light needs intensity >= 0 and a shadow box of positive size")
            self._put3(L_DIRS + 8 * i, unit(lights[i].dir), 0.0)
            self._put3(L_DIRS + 8 * i + 4, lights[i].color, lights[i].intensity)
        self._upload(device)

    def set_area_lights(mut self, device: Device, lights: List[AreaLight]) raises:
        """Replace the rectangular area lights (at most MAX_AREA_LIGHTS)."""
        if len(lights) > MAX_AREA_LIGHTS:
            raise Error("renderer: at most " + String(MAX_AREA_LIGHTS) + " area lights, got " + String(len(lights)))
        self.rig[3] = Float32(len(lights))
        self.areas = lights.copy()
        for i in range(len(lights)):
            if not (lights[i].intensity >= 0) or not (lights[i].shadow_range > 0.1):
                raise Error("renderer: an area light needs intensity >= 0 and shadow_range > 0.1")
            _ = unit(lights[i].ex)
            _ = unit(lights[i].ey)
            var o = L_AREAS + 16 * i
            self._put3(o, lights[i].pos, 0.0)
            self._put3(o + 4, lights[i].ex, 0.0)
            self._put3(o + 8, lights[i].ey, 0.0)
            self._put3(o + 12, lights[i].color, lights[i].intensity)
        self._upload(device)

    def set_sun(mut self, device: Device, to_sun: Vec3, color: Vec3, intensity: Float32) raises:
        """The sun's direction (toward it), colour and intensity, in place of the fixed (0.4, 1.0, 0.6) white at 0.6.
        The shadow map follows only if set_shadow is given a matching view (app/lights.mojo sun_shadow_vp)."""
        if not (intensity >= 0):
            raise Error("renderer: the sun's intensity must be >= 0")
        self._put3(L_SUN_DIR, unit(to_sun), 1.0)
        self._put3(L_SUN_COLOR, color * Real(intensity), 0.0)
        self._upload(device)

    def reset_sun(mut self, device: Device) raises:
        """The fixed sun again."""
        self._put3(L_SUN_DIR, Vec3(0, 0, 0, 0), 0.0)
        self._put3(L_SUN_COLOR, Vec3(Real(0.6), Real(0.6), Real(0.6), Real(0)), 0.0)
        self._upload(device)

    def set_environment(mut self, device: Device, env: Environment) raises:
        """The ambient light from an environment (app/lights.mojo: uniform_environment, sky_environment,
        equirect_environment) in place of the fixed 0.4, and the reflections of MatPbr. From here on the sun's shadow
        darkens the sun's light only: the ambient and the point lights are no longer inside it."""
        if len(env.sh) != 27:
            raise Error("renderer: an environment has 27 spherical-harmonic floats")
        for k in range(9):
            for c in range(3):
                self.rig[L_SH + 4 * k + c] = env.sh[3 * k + c]
        self._put3(L_ENV_TOP, env.top, 0.0)
        self._put3(L_ENV_HOR, env.horizon, 0.0)
        self._put3(L_ENV_GND, env.ground, 0.0)
        self.rig[L_AMB + 3] = 1.0
        self._upload(device)

    def set_probes(
        mut self, device: Device, origin: Vec3, cell: Vec3, nx: Int, ny: Int, nz: Int, sh: List[Float32],
    ) raises:
        """The ambient from a grid of irradiance probes (app/irradiance.mojo ProbeGrid) in place of the environment's
        one set of harmonics: nx * ny * nz probes from `origin`, `cell` metres apart, 27 floats each (9 coefficients,
        rgb) in the order x fastest, then y, then z. Like set_environment it turns the ambient on (the sun's shadow then
        darkens the sun only). Reflections still use the environment."""
        var n = nx * ny * nz
        if nx < 1 or ny < 1 or nz < 1 or n > MAX_PROBES:
            raise Error("renderer: a probe grid has 1 .. " + String(MAX_PROBES) + " probes")
        if len(sh) != 27 * n:
            raise Error("renderer: a probe grid has 27 harmonic floats per probe")
        for a in range(3):
            if not (Float64(cell[a]) > 0.0):
                raise Error("renderer: the probes' spacing is above 0 on every axis")
        var data = List[Float32]()
        for i in range(n):
            for k in range(9):
                for c in range(3):
                    data.append(sh[27 * i + 3 * k + c])
                data.append(0.0)
        device.queue_write_data(self.probes, UInt64(0), data)
        self._put3(L_PROBE_ORG, origin, 1.0)
        self._put3(L_PROBE_CELL, cell, 0.0)
        self.rig[L_PROBE_DIM] = Float32(nx)
        self.rig[L_PROBE_DIM + 1] = Float32(ny)
        self.rig[L_PROBE_DIM + 2] = Float32(nz)
        self.rig[L_AMB + 3] = 1.0
        self._upload(device)

    def clear_probes(mut self, device: Device) raises:
        """Back to the environment's harmonics for the ambient."""
        self.rig[L_PROBE_ORG + 3] = 0.0
        self._upload(device)

    def use_env_cube(mut self, device: Device, on: Bool) raises:
        """Whether MatPbr reflects the cube map (EnvProbe.finish turns it on; set_environment turns it off)."""
        self.rig[L_ENV_TOP + 3] = Float32(1.0) if on else Float32(0.0)
        self.rig[L_ENV_HOR + 3] = Float32(ENV_MIPS - 3)  # the blurriest mip read: 4 x 4 texels a face
        self._upload(device)

    def reset_environment(mut self, device: Device) raises:
        """The fixed 0.4 ambient again."""
        self.rig[L_AMB + 3] = 0.0
        self._upload(device)

    def atlas_target(self) raises -> TextureView:
        return self.atlas_tex.create_view_default()

    def write_camera(self, device: Device, v: View) raises:
        """The camera header for this frame (every pass that binds `camera` reads it)."""
        device.queue_write_data(self.camera, UInt64(0), cam_floats(v))

    def shadow_target(self) raises -> TextureView:
        """A view of the shadow map to render depth into (ShadowPass.draw's depth_view)."""
        return self.shadow_tex.create_view_default()

    def set_shadow(mut self, device: Device, light_vp: List[Float32], on: Bool) raises:
        """Set the light's view-projection (16 floats, column-major, NDC z in [0, 1]) and whether the shadow factor is
        applied: one fixed box (cascades off). The renderer's shadow pass draws it into the map (or the caller does,
        into shadow_target()). Off by default: the colour is then unchanged bit for bit."""
        if len(light_vp) != 16:
            raise Error("renderer: the light view-projection has 16 floats")
        self.casc_count = 0
        self.sun_res = self.shadow_size if self.shadow_size == SHADOW_MAP_SIZE else self.shadow_size // 2
        self._write_sun(device, light_vp, 1, on)
        self.light_vp = light_vp.copy()
        self.shadow_on = on

    def set_atmosphere(mut self, device: Device, sky_top: Vec3, sky_horizon: Vec3, fog_density: Float32, exposure: Float32,
                       fog: Bool, linear: Bool, sky_curve: Float32 = 0.5) raises:
        """The atmosphere for this pass and the skinned pass (they share the uniform): the sky's colours (sRGB, as the
        draw items' colours), fog toward the horizon colour with this density per metre, and the linear workflow with
        ACES tone mapping at this exposure. sky_curve shapes the sky's gradient (pow of the view's up component; below 1
        the colour leaves the horizon sooner). Both off by default: the colour is then unchanged bit for bit."""
        if not (fog_density >= 0) or not (exposure > 0) or not (sky_curve > 0):
            raise Error("renderer: the fog density must be >= 0 and the exposure > 0")
        var data = List[Float32]()
        data.append(Float32(sky_top[0])); data.append(Float32(sky_top[1])); data.append(Float32(sky_top[2]))
        data.append(Float32(1.0) if linear else Float32(0.0))
        data.append(Float32(sky_horizon[0])); data.append(Float32(sky_horizon[1])); data.append(Float32(sky_horizon[2]))
        data.append(0.0)
        data.append(Float32(1.0) if fog else Float32(0.0))
        data.append(fog_density)
        data.append(exposure)
        data.append(sky_curve)
        device.queue_write_data(self.shadow_ubo, UInt64(80), data)
        self.atmo_fog = fog
        self.atmo_linear = linear
        self.sky_overridden = False

    def set_fog_linear(mut self, device: Device, fog: Bool, linear: Bool) raises:
        """Override the atmosphere's fog and linear-workflow flags for the next draw, leaving its colours and density
        (the sky mask of app/debug_view.mojo turns both off)."""
        var lin = List[Float32]()
        lin.append(Float32(1.0) if linear else Float32(0.0))
        device.queue_write_data(self.shadow_ubo, UInt64(92), lin)
        var f = List[Float32]()
        f.append(Float32(1.0) if fog else Float32(0.0))
        device.queue_write_data(self.shadow_ubo, UInt64(112), f)

    def debug_sky(mut self, device: Device, on: Bool) raises:
        """For app/debug_view.mojo's DEBUG_SKY: with `on`, fog and the linear workflow off for this draw; on the first
        draw without it, the flags of the latest set_atmosphere back (a host that sets the atmosphere once keeps it)."""
        if on:
            self.set_fog_linear(device, False, False)
            self.sky_overridden = True
        elif self.sky_overridden:
            self.set_fog_linear(device, self.atmo_fog, self.atmo_linear)
            self.sky_overridden = False

    def set_ao(mut self, device: Device, cells: List[Float32], nx: Int, ny: Int, x0: Float32, z0: Float32,
               sx: Float32, sz: Float32, on: Bool) raises:
        """Set the ambient-occlusion grid: nx by ny cells (row-major by z, 1 open, 0 occluded) over the floor rectangle
        (x0, z0) to (x0 + sx, z0 + sz) in metres, and whether it multiplies the lit colour. Off by default: the colour is
        then unchanged bit for bit. The grid is uploaded whole; a grid larger than AO_MAX_CELLS is refused."""
        if nx < 1 or ny < 1 or nx * ny > AO_MAX_CELLS or len(cells) != nx * ny:
            raise Error("renderer: the AO grid needs nx * ny cells, at most AO_MAX_CELLS, one per cell")
        if sx <= 0.0 or sz <= 0.0:
            raise Error("renderer: the AO grid's extent must be positive")
        device.queue_write_data(self.ao_cells, UInt64(0), cells)
        var u = List[Float32]()
        u.append(x0); u.append(z0); u.append(sx); u.append(sz)
        u.append(Float32(nx)); u.append(Float32(ny)); u.append(0.0); u.append(0.0)
        u.append(Float32(1.0) if on else Float32(0.0)); u.append(0.0); u.append(0.0); u.append(0.0)
        device.queue_write_data(self.ao_ubo, UInt64(0), u)
