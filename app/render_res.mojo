"""What every pass of the scene renderer binds and the host sets (plan 2.4a): the camera header, the sun's shadow map
and its uniform (light view-projection, on-flag, atmosphere), and the ambient-occlusion grid. One per renderer; the
mesh and skinned passes bind these buffers, a shadow pass renders into `shadow_tex`.

Everything here is off by default (identity light, shadow off, atmosphere off, AO off): a pass bound to it draws the
colour it drew before the option existed, bit for bit.
"""
from wgpu import WGPUBufferUsage
from wgpu import WGPUTextureFormat, WGPUTextureUsage
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
from app.lights import (
    SpotLight, DirLight, AreaLight, Environment, unit, spot_vp, point_face_vp, dir_vp, area_vp, area_size, ATLAS_SIZE, ATLAS_TILES,
    MAX_SPOT_LIGHTS, MAX_DIR_LIGHTS, MAX_AREA_LIGHTS, LIGHTS_FLOATS,
    L_POINTS, L_SUN_DIR, L_SUN_COLOR, L_AMB, L_SH, L_ENV_TOP, L_ENV_HOR, L_ENV_GND, L_PSHADOW, L_SPOTS, L_DIRS, L_AREAS, L_TILES,
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


comptime SHADOW_MAP_SIZE = 1024  # the shadow map, square; 4 MB of depth
comptime AO_MAX_CELLS = 16384  # the ambient-occlusion grid: up to 128 by 128 floats over the floor (64 KB)
comptime MAX_MESH_INSTANCES = 8192  # default: mesh and skinned instances per frame: 8192 x 24 floats = 768 KB
comptime DEFAULT_PRIMITIVE_INSTANCES = 8192  # default: primitive items per frame
comptime MAX_POINT_LIGHTS = 16  # app/wgsl.mojo POINT_LIGHTS_WGSL's array size
comptime LIGHTS_BYTES = LIGHTS_FLOATS * 4  # the `Lights` uniform (app/lights.mojo): the point lights first, as before
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
            UInt64(128), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="mesh_shadow_ubo",
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
                if next + 6 > ATLAS_TILES:
                    raise Error("renderer: the shadow atlas has " + String(ATLAS_TILES) + " tiles (a point light takes 6, a spot light 1)")
                self.rig[L_PSHADOW + i] = Float32(next + 1)
                for f in range(6):
                    var m = point_face_vp(self.points[i].pos, f, Float64(self.points[i].range))
                    for k in range(16):
                        self.rig[L_TILES + 16 * (next + f) + k] = m[k]
                next += 6
        for i in range(len(self.spots)):
            self.rig[L_SPOTS + 16 * i + 13] = 0.0
            if self.spots[i].shadow:
                if next + 1 > ATLAS_TILES:
                    raise Error("renderer: the shadow atlas has " + String(ATLAS_TILES) + " tiles (a point light takes 6, a spot light 1)")
                self.rig[L_SPOTS + 16 * i + 13] = Float32(next + 1)
                var m = spot_vp(self.spots[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        for i in range(len(self.dirs)):
            self.rig[L_DIRS + 8 * i + 3] = 0.0
            if self.dirs[i].shadow:
                if next + 1 > ATLAS_TILES:
                    raise Error("renderer: the shadow atlas has " + String(ATLAS_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_DIRS + 8 * i + 3] = Float32(next + 1)
                var m = dir_vp(self.dirs[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        for i in range(len(self.areas)):
            self.rig[L_AREAS + 16 * i + 3] = 0.0
            if self.areas[i].shadow:
                if next + 1 > ATLAS_TILES:
                    raise Error("renderer: the shadow atlas has " + String(ATLAS_TILES) + " tiles (a point light takes 6, the others 1)")
                self.rig[L_AREAS + 16 * i + 3] = Float32(next + 1)
                self.rig[L_AREAS + 16 * i + 7] = self.areas[i].shadow_range
                self.rig[L_AREAS + 16 * i + 11] = Float32(area_size(self.areas[i]))
                var m = area_vp(self.areas[i])
                for k in range(16):
                    self.rig[L_TILES + 16 * next + k] = m[k]
                next += 1
        self.tiles = next
        device.queue_write_data(self.lights, UInt64(0), self.rig)

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
        applied. The shadow map itself is rendered by the caller into shadow_tex. Off by default: the colour is then
        unchanged bit for bit."""
        if len(light_vp) != 16:
            raise Error("renderer: the light view-projection has 16 floats")
        var data = List[Float32]()
        for c in range(16):
            data.append(light_vp[c])
        data.append(Float32(1.0) if on else Float32(0.0))
        data.append(0.0)
        data.append(0.0)
        data.append(0.0)
        device.queue_write_data(self.shadow_ubo, UInt64(0), data)
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
