"""The lights a renderer's shaders read (app/wgsl.mojo POINT_LIGHTS_WGSL), on the CPU side: the light types, the layout
of the `Lights` uniform, the environment as order-2 spherical harmonics, and the view-projections of the shadow views.

    r.set_sun(device, dir, color, intensity)          # the sun's direction and colour (the default is fixed)
    r.set_shadow(device, sun_shadow_vp(dir, centre, half_extent, depth), True)
    r.set_environment(device, sky_environment(top, horizon, ground))   # ambient from the sky, reflections on MatPbr
    r.set_lights(device, [PointLight(pos, range, color, intensity, shadow=True)])
    r.set_spot_lights(device, [SpotLight(pos, dir, range, inner, outer, color, intensity, True)])
    r.set_dir_lights(device, [DirLight(dir, color, intensity)])
    r.set_area_lights(device, [AreaLight(centre, half_x, half_y, color, intensity)])

Units: a light's colour times intensity is what a white matte surface facing it reflects (at the light, for a point or
spot light; with the panel filling its view, for an area light; anywhere, for a directional light).

Colour temperature, photometric units and exposure (lm, cd, lx, nit), IES profiles and cookies: app/photometry.mojo and
the fields of each light type; the renderer's set_exposure, set_ies and set_cookie.

Shadows: the sun has its map (set_shadow). The others take tiles of the 4 x 4 shadow atlas when asked: a point light
six (a cube), a spot, directional or area light one; 16 tiles in all. Only items with a mesh cast, as for the sun.
"""
from std.math import sqrt, sin, cos, tan, pi
from geometry.vec import Real, Vec3
from app.photometry import UNITS_RELATIVE

comptime MAX_POINT_LIGHTS = 16
comptime MAX_SPOT_LIGHTS = 8
comptime MAX_DIR_LIGHTS = 4
comptime MAX_AREA_LIGHTS = 4
comptime ATLAS_TILES = 16  # 4 x 4
comptime ATLAS_SIZE = 2048  # the atlas, square: 512 per tile, 16 MB of depth

# float offsets into the uniform (the WGSL struct `Lights`)
comptime L_COUNT = 0
comptime L_POINTS = 4  # 16 x 8
comptime L_SUN_DIR = 132
comptime L_SUN_COLOR = 136
comptime L_AMB = 140
comptime L_SH = 144  # 9 x 4
comptime L_ENV_TOP = 180
comptime L_ENV_HOR = 184
comptime L_ENV_GND = 188
comptime L_PSHADOW = 192  # 16
comptime L_SPOTS = 208  # 8 x 16
comptime L_DIRS = 336  # 4 x 8
comptime L_AREAS = 368  # 4 x 16
comptime L_TILES = 432  # 16 x 16
comptime L_PROBE_ORG = 688  # the irradiance probe grid (app/irradiance.mojo): its first probe's position, w 1 when on
comptime L_PROBE_CELL = 692  # the spacing of the probes along x, y, z (m)
comptime L_PROBE_DIM = 696  # the probe counts along x, y, z
# per light, what app/photometry.mojo and the profiles add (IES table, cookies, the inverse-square falloff):
comptime L_PEXT = 700  # 16 x 8: the IES axis, IES slot + 1; the IES horizontal-0 direction, falloff (1 inverse square)
comptime L_SEXT = 828  # 8 x 12: IES slot + 1, cookie layer + 1, falloff; cookie right / tan(outer); cookie up / tan(outer)
comptime L_DEXT = 924  # 4 x 12: (0, cookie layer + 1, 0, 0); right / cookie size, u offset; up / cookie size, v offset
comptime L_SUNEXT = 972  # 12: the sun's, as a directional light's
comptime L_IES_SYM = 984  # 8: per IES slot, 1 when its profile is the same all round
comptime LIGHTS_FLOATS = 992
comptime LIGHTS_BYTES = LIGHTS_FLOATS * 4


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0))


def _dot(a: Vec3, b: Vec3) -> Float64:
    return Float64(a[0]) * Float64(b[0]) + Float64(a[1]) * Float64(b[1]) + Float64(a[2]) * Float64(b[2])


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0], Real(0))


def unit(a: Vec3) raises -> Vec3:
    var l = sqrt(_dot(a, a))
    if not (l > 1e-12):
        raise Error("lights: a direction must not be zero")
    return _v(Float64(a[0]) / l, Float64(a[1]) / l, Float64(a[2]) / l)


struct PointLight(Copyable, ImplicitlyCopyable, Movable):
    """A point light: position (m), range (m; no light beyond it), colour (linear 0..1 per channel) and intensity (in
    `units`, app/photometry.mojo). With `shadow` it takes six tiles of the shadow atlas.

    Falloff: (1 - (d / range)^2)^2, or with `inverse_square` (and always in photometric units) 1 / d^2 times
    (1 - (d / range)^4)^2, the window that brings it to 0 at the range.
    `kelvin` (1667 .. 25000, 0 off) multiplies the colour by a black body's (photometry.kelvin_rgb, luminance 1).
    `ies` is a slot of the renderer's IES table (set_ies) or -1: the profile's vertical 0 points along `axis`, its
    horizontal 0 along the axis's right vector (lights._basis) turned by `spin` radians about the axis. With a profile,
    the intensity is the light's at the profile's peak."""

    var pos: Vec3
    var range: Float32
    var color: Vec3
    var intensity: Float32
    var shadow: Bool
    var kelvin: Float32
    var units: Int
    var inverse_square: Bool
    var ies: Int
    var axis: Vec3
    var spin: Float32

    def __init__(
        out self, pos: Vec3, range: Float32, color: Vec3, intensity: Float32, shadow: Bool = False,
        kelvin: Float32 = 0.0, units: Int = UNITS_RELATIVE, inverse_square: Bool = False, ies: Int = -1,
        axis: Vec3 = Vec3(0, -1, 0, 0), spin: Float32 = 0.0,
    ):
        self.pos = pos
        self.range = range
        self.color = color
        self.intensity = intensity
        self.shadow = shadow
        self.kelvin = kelvin
        self.units = units
        self.inverse_square = inverse_square
        self.ies = ies
        self.axis = axis
        self.spin = spin


struct SpotLight(Copyable, ImplicitlyCopyable, Movable):
    """A cone of light from `pos` along `dir`: full inside `inner` radians of the axis, none beyond `outer`, falling
    off with distance like a point light (nothing beyond `range`; `inverse_square` as PointLight's).

    `kelvin`, `units` and `ies` as PointLight's, with `dir` as the IES axis. `cookie` is a layer of the renderer's
    cookie array (set_cookie) or -1: the picture is projected along the cone, its edges at `outer` radians off the
    axis, its top toward the axis's up vector (lights._basis), both turned by `spin` radians about the axis; the
    light is multiplied by the picture's colour (linear; sRGB in the texture)."""

    var pos: Vec3
    var dir: Vec3
    var range: Float32
    var inner: Float32
    var outer: Float32
    var color: Vec3
    var intensity: Float32
    var shadow: Bool
    var kelvin: Float32
    var units: Int
    var inverse_square: Bool
    var ies: Int
    var cookie: Int
    var spin: Float32

    def __init__(
        out self, pos: Vec3, dir: Vec3, range: Float32, inner: Float32, outer: Float32, color: Vec3,
        intensity: Float32, shadow: Bool = False, kelvin: Float32 = 0.0, units: Int = UNITS_RELATIVE,
        inverse_square: Bool = False, ies: Int = -1, cookie: Int = -1, spin: Float32 = 0.0,
    ):
        self.pos = pos
        self.dir = dir
        self.range = range
        self.inner = inner
        self.outer = outer
        self.color = color
        self.intensity = intensity
        self.shadow = shadow
        self.kelvin = kelvin
        self.units = units
        self.inverse_square = inverse_square
        self.ies = ies
        self.cookie = cookie
        self.spin = spin


struct DirLight(Copyable, ImplicitlyCopyable, Movable):
    """Light from one direction everywhere (`dir` points toward the light). With `shadow` it takes one tile of the
    atlas: a box of 2 half_extent across around `centre`, seen from `depth` metres toward the light (as
    sun_shadow_vp); nothing outside the box is shadowed.

    `kelvin` and `units` (UNITS_RELATIVE or UNITS_LUX) as PointLight's. `cookie` is a layer of the cookie array or -1:
    the picture is projected along the light, one repeat every `cookie_size` metres across the light's right and up
    vectors (the axes of its shadow view, lights._basis of -dir), shifted by (cookie_u, cookie_v) repeats (move them
    each frame for drifting cloud shadows)."""

    var dir: Vec3
    var color: Vec3
    var intensity: Float32
    var shadow: Bool
    var centre: Vec3
    var half_extent: Float32
    var depth: Float32
    var kelvin: Float32
    var units: Int
    var cookie: Int
    var cookie_size: Float32
    var cookie_u: Float32
    var cookie_v: Float32

    def __init__(
        out self, dir: Vec3, color: Vec3, intensity: Float32, shadow: Bool = False,
        centre: Vec3 = Vec3(0, 0, 0, 0), half_extent: Float32 = 20.0, depth: Float32 = 40.0,
        kelvin: Float32 = 0.0, units: Int = UNITS_RELATIVE, cookie: Int = -1, cookie_size: Float32 = 10.0,
        cookie_u: Float32 = 0.0, cookie_v: Float32 = 0.0,
    ):
        self.dir = dir
        self.color = color
        self.intensity = intensity
        self.shadow = shadow
        self.centre = centre
        self.half_extent = half_extent
        self.depth = depth
        self.kelvin = kelvin
        self.units = units
        self.cookie = cookie
        self.cookie_size = cookie_size
        self.cookie_u = cookie_u
        self.cookie_v = cookie_v


struct AreaLight(Copyable, ImplicitlyCopyable, Movable):
    """A rectangular panel: centre `pos`, half-edges `ex` and `ey` (perpendicular), emitting from the side
    cross(ex, ey) points to, evenly and by the cosine of its normal. With `shadow` it takes one tile of the atlas: a
    view from its centre along its normal, 120 degrees across and `shadow_range` metres deep; the shadow's edge is as
    soft as the panel is large. `kelvin` and `units` (UNITS_RELATIVE, UNITS_NIT or UNITS_LUMEN) as PointLight's."""

    var pos: Vec3
    var ex: Vec3
    var ey: Vec3
    var color: Vec3
    var intensity: Float32
    var shadow: Bool
    var shadow_range: Float32
    var kelvin: Float32
    var units: Int

    def __init__(
        out self, pos: Vec3, ex: Vec3, ey: Vec3, color: Vec3, intensity: Float32, shadow: Bool = False,
        shadow_range: Float32 = 30.0, kelvin: Float32 = 0.0, units: Int = UNITS_RELATIVE,
    ):
        self.pos = pos
        self.ex = ex
        self.ey = ey
        self.color = color
        self.intensity = intensity
        self.shadow = shadow
        self.shadow_range = shadow_range
        self.kelvin = kelvin
        self.units = units


struct Environment(Copyable, Movable):
    """What surrounds the scene: `sh`, its radiance as 9 spherical-harmonic coefficients per channel (27 floats,
    coefficient-major: sh[3 * i + c]), which gives the ambient light on a surface by its normal; and three colours
    (zenith, horizon, nadir) for what a smooth MatPbr surface reflects."""

    var sh: List[Float32]
    var top: Vec3
    var horizon: Vec3
    var ground: Vec3

    def __init__(out self, var sh: List[Float32], top: Vec3, horizon: Vec3, ground: Vec3):
        self.sh = sh^
        self.top = top
        self.horizon = horizon
        self.ground = ground


def sh_basis(x: Float64, y: Float64, z: Float64) -> List[Float64]:
    """The nine real spherical harmonics of order 0 .. 2 at a unit direction, in the order the shader reads them."""
    return [
        0.282095, 0.488603 * y, 0.488603 * z, 0.488603 * x, 1.092548 * x * y, 1.092548 * y * z,
        0.315392 * (3.0 * z * z - 1.0), 1.092548 * x * z, 0.546274 * (x * x - y * y),
    ]


def sky_color(top: Vec3, horizon: Vec3, ground: Vec3, y: Float64) -> Vec3:
    """The gradient both sky_environment and the shader's reflection use: by the square root of the direction's height,
    from the horizon colour to the zenith's above and to the nadir's below."""
    var up = Real(sqrt(max(y, 0.0)))
    var down = Real(sqrt(max(-y, 0.0)))
    var a = horizon + (top - horizon) * up
    return a + (ground - a) * down


def uniform_environment(color: Vec3) -> Environment:
    """The same radiance from every direction: a flat ambient of `color`."""
    var sh = List[Float32](length=27, fill=Float32(0))
    for c in range(3):
        sh[c] = Float32(Float64(color[c]) * 0.282095 * 4.0 * pi)
    return Environment(sh^, color, color, color)


def sky_environment(top: Vec3, horizon: Vec3, ground: Vec3, steps: Int = 48) -> Environment:
    """The environment of a sky gradient (sky_color), integrated over the sphere on steps x 2 steps cells."""
    var sh = List[Float64](length=27, fill=0.0)
    for i in range(steps):
        var th = (Float64(i) + 0.5) / Float64(steps) * pi  # from +y
        # the cell's solid angle, exactly: a band between two polar angles, cut in 2 steps
        var dw = (cos(Float64(i) / Float64(steps) * pi) - cos(Float64(i + 1) / Float64(steps) * pi)) * (pi / Float64(steps))
        for j in range(2 * steps):
            var ph = (Float64(j) + 0.5) / Float64(steps) * pi
            var x = sin(th) * cos(ph)
            var y = cos(th)
            var z = sin(th) * sin(ph)
            var col = sky_color(top, horizon, ground, y)
            var b = sh_basis(x, y, z)
            for k in range(9):
                for c in range(3):
                    sh[3 * k + c] += Float64(col[c]) * b[k] * dw
    var out = List[Float32]()
    for v in sh:
        out.append(Float32(v))
    return Environment(out^, top, horizon, ground)


def equirect_environment(pixels: List[Float32], width: Int, height: Int) raises -> Environment:
    """The environment of an equirectangular picture: width x height pixels of linear rgb (3 floats each), row 0 at
    the zenith, column 0 toward +x turning toward +z. The reflection colours are the mean of the top row, the middle
    row and the bottom row."""
    if width < 1 or height < 1 or len(pixels) != width * height * 3:
        raise Error("lights: an equirectangular environment is width * height * 3 floats")
    var sh = List[Float64](length=27, fill=0.0)
    for i in range(height):
        var th = (Float64(i) + 0.5) / Float64(height) * pi
        var dw = (cos(Float64(i) / Float64(height) * pi) - cos(Float64(i + 1) / Float64(height) * pi)) * (2.0 * pi / Float64(width))
        for j in range(width):
            var ph = (Float64(j) + 0.5) / Float64(width) * 2.0 * pi
            var b = sh_basis(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
            for k in range(9):
                for c in range(3):
                    sh[3 * k + c] += Float64(pixels[(i * width + j) * 3 + c]) * b[k] * dw
    var rows = [0, height // 2, height - 1]
    var mean = List[Vec3]()
    for r in rows:
        var m = [0.0, 0.0, 0.0]
        for j in range(width):
            for c in range(3):
                m[c] += Float64(pixels[(r * width + j) * 3 + c]) / Float64(width)
        mean.append(_v(m[0], m[1], m[2]))
    var out = List[Float32]()
    for v in sh:
        out.append(Float32(v))
    return Environment(out^, mean[0], mean[1], mean[2])


def sh_lit(sh: List[Float32], n: Vec3) -> Vec3:
    """What a white matte surface facing n reflects under the environment: its irradiance over pi (the shader's
    sh_lit, in Float64)."""
    var x = Float64(n[0])
    var y = Float64(n[1])
    var z = Float64(n[2])
    var o = [0.0, 0.0, 0.0]
    for c in range(3):
        var e = (
            0.429043 * Float64(sh[24 + c]) * (x * x - y * y) + 0.743125 * Float64(sh[18 + c]) * z * z
            + 0.886227 * Float64(sh[c]) - 0.247708 * Float64(sh[18 + c])
            + 2.0 * 0.429043 * (Float64(sh[12 + c]) * x * y + Float64(sh[21 + c]) * x * z + Float64(sh[15 + c]) * y * z)
            + 2.0 * 0.511664 * (Float64(sh[9 + c]) * x + Float64(sh[3 + c]) * y + Float64(sh[6 + c]) * z)
        )
        o[c] = max(e, 0.0) / pi
    return _v(o[0], o[1], o[2])


def basis(fwd: Vec3) raises -> Tuple[Vec3, Vec3]:
    """The right and up vectors of a view along `fwd` (made unit): the frame the shadow views, the IES horizontal
    angle and the cookies are measured in."""
    return _basis(unit(fwd))


def spun(fwd: Vec3, spin: Float64) raises -> Tuple[Vec3, Vec3]:
    """basis(fwd) turned by `spin` radians about fwd (from right toward up)."""
    var b = basis(fwd)
    var c = Real(cos(spin))
    var s = Real(sin(spin))
    return (b[0] * c + b[1] * s, b[1] * c - b[0] * s)


def _basis(fwd: Vec3) raises -> Tuple[Vec3, Vec3]:
    """A right and an up vector for a view along the unit vector fwd (world y up, z when fwd is vertical)."""
    var hint = _v(0, 0, 1) if abs(Float64(fwd[1])) > 0.99 else _v(0, 1, 0)
    var right = unit(_cross(fwd, hint))
    return (right, _cross(right, fwd))


def _mat(right: Vec3, up: Vec3, fwd: Vec3, eye: Vec3, sx: Float64, sy: Float64, zs: Float64, zo: Float64, persp: Bool) -> List[Float32]:
    """Column-major clip = M * world with x = sx * (d . right), y = sy * (d . up), z = zs * (d . fwd) + zo and
    w = d . fwd (perspective) or 1, d = world - eye."""
    var rows = List[Float64]()
    for r in range(4):
        var axis = right if r == 0 else (up if r == 1 else fwd)
        var k = sx if r == 0 else (sy if r == 1 else (zs if r == 2 else (1.0 if persp else 0.0)))
        for c in range(3):
            rows.append(k * Float64(axis[c]))
        var off = -k * _dot(axis, eye)
        if r == 2:
            off += zo
        if r == 3 and not persp:
            off = 1.0
        rows.append(off)
    var m = List[Float32]()
    for c in range(4):
        for r in range(4):
            m.append(Float32(rows[r * 4 + c]))
    return m^


def perspective_vp(eye: Vec3, fwd: Vec3, tan_half: Float64, near: Float64, far: Float64) raises -> List[Float32]:
    """A square perspective view from `eye` along `fwd`: 16 floats, column-major, NDC z in [0, 1]."""
    var f = unit(fwd)
    var b = _basis(f)
    var zs = far / (far - near)
    return _mat(b[0], b[1], f, eye, 1.0 / tan_half, 1.0 / tan_half, zs, -near * zs, True)


def sun_shadow_vp(to_sun: Vec3, centre: Vec3, half_extent: Float64, depth: Float64) raises -> List[Float32]:
    """The sun's orthographic view-projection for set_shadow: a box of 2 half_extent across around `centre`, seen from
    `depth` metres toward the sun and reaching as far behind the centre."""
    var d = unit(to_sun)
    var f = _v(-Float64(d[0]), -Float64(d[1]), -Float64(d[2]))
    var b = _basis(f)
    var eye = centre + d * Real(depth)
    return _mat(b[0], b[1], f, eye, 1.0 / half_extent, 1.0 / half_extent, 1.0 / (2.0 * depth), 0.0, False)


def spot_vp(l: SpotLight) raises -> List[Float32]:
    """The view a spot light's shadow tile is drawn from: its cone and two degrees more."""
    var half = min(Float64(l.outer) + 0.035, 1.48)
    return perspective_vp(l.pos, l.dir, tan(half), 0.05, Float64(l.range))


def point_face_vp(pos: Vec3, face: Int, range: Float64) raises -> List[Float32]:
    """Face 0 .. 5 (+x, -x, +y, -y, +z, -z) of a point light's shadow cube: 90 degrees across."""
    var axes = [_v(1, 0, 0), _v(-1, 0, 0), _v(0, 1, 0), _v(0, -1, 0), _v(0, 0, 1), _v(0, 0, -1)]
    return perspective_vp(pos, axes[face], 1.0, 0.05, range)


def dir_vp(l: DirLight) raises -> List[Float32]:
    """The parallel view a directional light's shadow tile is drawn from."""
    return sun_shadow_vp(l.dir, l.centre, Float64(l.half_extent), Float64(l.depth))


def area_vp(l: AreaLight) raises -> List[Float32]:
    """The view an area light's shadow tile is drawn from: its centre, along its normal, 120 degrees across."""
    return perspective_vp(l.pos, _cross(l.ex, l.ey), 1.7320508, 0.05, Float64(l.shadow_range))


def area_size(l: AreaLight) -> Float64:
    """The panel's size for the softness of its shadow: the mean of its two edges."""
    return sqrt(_dot(l.ex, l.ex)) + sqrt(_dot(l.ey, l.ey))


def apply_vp(m: List[Float32], p: Vec3) -> Tuple[Float64, Float64, Float64, Float64]:
    """clip = M * (p, 1), for tests."""
    var o = [0.0, 0.0, 0.0, 0.0]
    for r in range(4):
        o[r] = Float64(m[r]) * Float64(p[0]) + Float64(m[4 + r]) * Float64(p[1]) + Float64(m[8 + r]) * Float64(p[2]) + Float64(m[12 + r])
    return (o[0], o[1], o[2], o[3])


def rect_form_factor(half_a: Float64, half_b: Float64, dist: Float64) -> Float64:
    """The fraction of what a rectangle (2 half_a by 2 half_b) emits by the cosine that reaches a small surface
    parallel to it, `dist` under its centre (the closed form; four corner terms). For checking AreaLight."""
    from std.math import atan
    var a = half_a / dist
    var b = half_b / dist
    var ra = sqrt(1.0 + a * a)
    var rb = sqrt(1.0 + b * b)
    return 4.0 / (2.0 * pi) * (a / ra * atan(b / ra) + b / rb * atan(a / rb))


def area_taps_factor(half_a: Float64, half_b: Float64, dist: Float64) -> Float64:
    """The same quantity as the shader computes it: 3 x 3 Gauss-Legendre points, each capped at its share."""
    var s = 0.0
    for t in range(9):
        var i = t % 3
        var j = t // 3
        var w = (0.88888889 if i == 1 else 0.55555556) * (0.88888889 if j == 1 else 0.55555556)
        var x = (Float64(i) - 1.0) * 0.77459667 * half_a
        var z = (Float64(j) - 1.0) * 0.77459667 * half_b
        var d2 = x * x + z * z + dist * dist
        var cosine = dist / sqrt(d2)
        s += min(cosine * w * half_a * half_b / (pi * d2), w * 0.25) * cosine
    return s
