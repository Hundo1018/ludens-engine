"""Light colour by temperature, photometric units and the camera's exposure, and IES photometric files: the CPU side of
the lights' colour, brightness and shape (app/lights.mojo holds the light types, app/wgsl.mojo the shader side).

    kelvin_rgb(2700.0)                      # a warm white: linear Rec. 709 rgb of luminance 1
    var e = Exposure(16.0, 1.0 / 100.0, 100.0)  # f/16, 1/100 s, ISO 100: EV100 14.6
    e.scale()                               # display value per cd/m^2
    var ies = IesProfile.parse(text)        # an LM-63 file (TILT=NONE, type C photometry)
    ies.candela(theta, phi)                 # cd at an angle from the light's axis

Units of a light's `intensity` (the `units` field of each light type):
    UNITS_RELATIVE   what the renderer had before: colour times intensity is what a white matte surface facing the light
                     reflects (at the light for a point or spot light, at 1 m when it falls off by the inverse square)
    UNITS_CANDELA    luminous intensity (cd) of a point or spot light: the light on a surface 1 m away is that many lux
    UNITS_LUMEN      luminous flux (lm) of a point, spot or area light: spread over the sphere, the spot's cone or the
                     panel's hemisphere
    UNITS_LUX        illuminance (lx) of a directional light or the sun on a surface facing it
    UNITS_NIT        luminance (cd/m^2) of an area light's panel
The photometric units are turned into the renderer's value through the exposure: a white matte surface under E lux
reflects E / pi cd/m^2, and the camera turns L cd/m^2 into the display value L * Exposure.scale().
"""
from std.math import sqrt, exp, log2, pi, cos, sin, atan2, acos
from geometry.vec import Real, Vec3

comptime UNITS_RELATIVE = 0
comptime UNITS_CANDELA = 1
comptime UNITS_LUMEN = 2
comptime UNITS_LUX = 3
comptime UNITS_NIT = 4

# the IES table on the GPU (RenderResources.ies_tex): IES_THETA samples from 0 to 180 degrees (both ends) along a row,
# IES_PHI rows from 0 to 360 degrees (the last one wraps to the first), MAX_IES_PROFILES profiles one above the other
comptime IES_THETA = 128
comptime IES_PHI = 32
comptime MAX_IES_PROFILES = 8


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0))


# ---------------------------------------------------------------------------------------------------- colour temperature


def kelvin_xy(kelvin: Float64) raises -> Tuple[Float64, Float64]:
    """The CIE 1931 chromaticity (x, y) of a black body at `kelvin` (1667 .. 25000 K): the cubic splines of Kim et al.
    (2002), US patent 7024034, which follow the Planckian locus to within about 0.001 in x and y."""
    if not (kelvin >= 1667.0 and kelvin <= 25000.0):
        raise Error("photometry: a colour temperature is 1667 .. 25000 K, got " + String(kelvin))
    var t = kelvin
    var x: Float64
    if t <= 4000.0:
        x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
    else:
        x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
    var y: Float64
    if t <= 2222.0:
        y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
    elif t <= 4000.0:
        y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
    return (x, y)


def xy_rgb(x: Float64, y: Float64) -> Vec3:
    """Linear Rec. 709 (sRGB primaries, D65 white) rgb of the chromaticity (x, y) at luminance 1. A channel below 0
    (a colour outside the gamut) is cut to 0 and the luminance made 1 again."""
    var bx = x / y
    var bz = (1.0 - x - y) / y
    var r = max(3.2404542 * bx - 1.5371385 - 0.4985314 * bz, 0.0)
    var g = max(-0.9692660 * bx + 1.8760108 + 0.0415560 * bz, 0.0)
    var b = max(0.0556434 * bx - 0.2040259 + 1.0572252 * bz, 0.0)
    var lum = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    return _v(r / lum, g / lum, b / lum)


def kelvin_rgb(kelvin: Float64) raises -> Vec3:
    """The colour of a black body at `kelvin`, linear Rec. 709 rgb of luminance 1 (0.2126 r + 0.7152 g + 0.0722 b):
    multiplying a light's colour by it changes the hue, not the brightness. 6504 K is close to white (D65 lies just
    off the black-body curve); lower is warmer, higher bluer."""
    var xy = kelvin_xy(kelvin)
    return xy_rgb(xy[0], xy[1])


def tinted(color: Vec3, kelvin: Float32) raises -> Vec3:
    """A light's colour with its temperature: colour * kelvin_rgb(kelvin), or the colour alone when kelvin is 0."""
    if kelvin == 0.0:
        return color
    var k = kelvin_rgb(Float64(kelvin))
    return Vec3(color[0] * k[0], color[1] * k[1], color[2] * k[2], Real(0))


# ---------------------------------------------------------------------------------------------------- exposure


struct Exposure(Copyable, ImplicitlyCopyable, Movable):
    """A camera's exposure: f-number, shutter time (s) and ISO. scale() turns a luminance (cd/m^2) into the display
    value the renderer works in (Lagarde and de Rousiers, Moving Frostbite to Physically Based Rendering, 2014: the
    saturation-based sensitivity, 78 / (100 * 0.65) = 1.2). The default, f/16 at 1/100 s and ISO 100 (the sunny 16
    rule), shows a white surface in 100 000 lx of sun at about 1.0."""

    var aperture: Float64
    var shutter: Float64
    var iso: Float64

    def __init__(out self, aperture: Float64 = 16.0, shutter: Float64 = 0.01, iso: Float64 = 100.0):
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso

    @staticmethod
    def from_ev100(ev100: Float64) -> Self:
        """The exposure of an EV100: f/1 at 2^-ev100 s, ISO 100."""
        return Self(1.0, 1.0 / (2.0 ** ev100), 100.0)

    def check(self) raises:
        if not (self.aperture > 0.0) or not (self.shutter > 0.0) or not (self.iso > 0.0):
            raise Error("photometry: an exposure needs f-number, shutter time and ISO above 0")

    def ev100(self) -> Float64:
        """log2(N^2 / t) - log2(S / 100)."""
        return log2(self.aperture * self.aperture / self.shutter) - log2(self.iso / 100.0)

    def scale(self) -> Float64:
        """The display value of 1 cd/m^2: 1 / (1.2 * 2^EV100)."""
        return 1.0 / (1.2 * 2.0 ** self.ev100())


def relative_from_candela(cd: Float64, e: Exposure) -> Float64:
    """The renderer's value of a point or spot light of `cd` candela that falls off by the inverse square: a white
    matte surface 1 m away facing it is lit by cd lux and reflects cd / pi cd/m^2."""
    return cd / pi * e.scale()


def relative_from_lux(lux: Float64, e: Exposure) -> Float64:
    """The renderer's value of a directional light of `lux`: a white matte surface facing it reflects lux / pi cd/m^2."""
    return lux / pi * e.scale()


def relative_from_nit(nit: Float64, e: Exposure) -> Float64:
    """The renderer's value of an area light whose panel has a luminance of `nit` cd/m^2: a white matte surface whose
    view the panel fills reflects the panel's luminance."""
    return nit * e.scale()


def spot_solid_angle(inner: Float64, outer: Float64) -> Float64:
    """The solid angle a spot light's cone covers, counting the edge by the shader's smoothstep: full inside `inner`
    radians, none beyond `outer`. The smoothstep over cos(angle) integrates to half its span, so the cone is
    2 pi (1 - (cos inner + cos outer) / 2) sr."""
    return 2.0 * pi * (1.0 - 0.5 * (cos(inner) + cos(outer)))


def candela_from_lumens_point(lumens: Float64) -> Float64:
    """A bare point light sends its flux evenly over 4 pi sr."""
    return lumens / (4.0 * pi)


def candela_from_lumens_spot(lumens: Float64, inner: Float64, outer: Float64) -> Float64:
    """A spot light sends its flux into its cone only (spot_solid_angle): a narrower cone at the same flux is brighter."""
    return lumens / spot_solid_angle(inner, outer)


def nit_from_lumens_area(lumens: Float64, area: Float64) -> Float64:
    """A panel of `area` m^2 that emits evenly by the cosine (Lambertian, one side) has a luminance of lm / (pi area)."""
    return lumens / (pi * area)


# ---------------------------------------------------------------------------------------------------- IES files


def _tokens(text: String) -> List[String]:
    """The numbers of an LM-63 file's body: separated by blanks, line ends or commas."""
    var out = List[String]()
    for w in text.replace(",", " ").split():
        out.append(String(w))
    return out^


struct IesProfile(Copyable, Movable):
    """An IES LM-63 photometric file (LM-63-1995 and -2002; TILT=NONE; type C photometry, the one luminaires for
    buildings and streets use). Angles in degrees as in the file: vertical 0 is straight down the light's axis, 180
    straight up; horizontal 0 .. 360 around the axis. `cd[h * nv + v]` is the candela at horizontal angle h and
    vertical angle v, with the file's multiplier and ballast factor applied.

    Horizontal symmetry by the file's last horizontal angle: 0 the same all round, 90 each quadrant a mirror of the
    first, 180 the two halves mirrors of each other about the 0-180 plane, 360 none. A file from 90 to 270 is mirrored
    about the 90-270 plane. Outside its vertical range the light sends nothing."""

    var vert: List[Float64]
    var horiz: List[Float64]
    var cd: List[Float64]
    var lamp_lumens: Float64  # lumens per lamp times lamps as the file gives it; -1 for absolute photometry

    def __init__(out self, var vert: List[Float64], var horiz: List[Float64], var cd: List[Float64], lamp_lumens: Float64):
        self.vert = vert^
        self.horiz = horiz^
        self.cd = cd^
        self.lamp_lumens = lamp_lumens

    @staticmethod
    def parse(text: String) raises -> Self:
        """Read an LM-63 file's text. Raises on what it cannot read: no TILT line, TILT other than NONE, photometry
        other than type C, too few numbers, angles out of order or range."""
        var at = text.find("TILT=")
        if at < 0:
            raise Error("ies: no TILT= line")
        var rest = String(text[byte=at + 5 :])
        var nl = rest.find("\n")
        if nl < 0:
            raise Error("ies: nothing after the TILT line")
        var tilt = String(String(rest[byte=:nl]).strip())
        if tilt != "NONE":
            raise Error("ies: only TILT=NONE is read, got TILT=" + tilt)
        var t = _tokens(String(rest[byte=nl + 1 :]))
        if len(t) < 13:
            raise Error("ies: the photometric header has 13 numbers, got " + String(len(t)))
        var lamps = atof(t[0])
        var lumens = atof(t[1])
        var mult = atof(t[2])
        var nv = Int(atol(t[3]))
        var nh = Int(atol(t[4]))
        var ptype = Int(atol(t[5]))
        var ballast = atof(t[10])
        var factor = atof(t[11])
        if ptype != 1:
            raise Error("ies: only type C photometry (1) is read, got type " + String(ptype))
        if nv < 2 or nh < 1:
            raise Error("ies: at least two vertical angles and one horizontal")
        if len(t) < 13 + nv + nh + nv * nh:
            raise Error("ies: the file ends inside its angle or candela lists")
        var k = 13
        var vert = List[Float64]()
        for _ in range(nv):
            vert.append(atof(t[k]))
            k += 1
        var horiz = List[Float64]()
        for _ in range(nh):
            horiz.append(atof(t[k]))
            k += 1
        for i in range(1, nv):
            if not (vert[i] > vert[i - 1]):
                raise Error("ies: vertical angles must rise")
        for i in range(1, nh):
            if not (horiz[i] > horiz[i - 1]):
                raise Error("ies: horizontal angles must rise")
        if vert[0] < 0.0 or vert[nv - 1] > 180.0 or horiz[0] < 0.0 or horiz[nh - 1] > 360.0:
            raise Error("ies: angles out of range (vertical 0 .. 180, horizontal 0 .. 360)")
        var scale = mult * ballast * (factor if factor > 0.0 else 1.0)
        var cd = List[Float64]()
        for _ in range(nv * nh):
            cd.append(max(atof(t[k]) * scale, 0.0))
            k += 1
        return Self(vert^, horiz^, cd^, lamps * lumens if lumens > 0.0 else -1.0)

    def peak(self) -> Float64:
        """The largest candela in the table."""
        var m = 0.0
        for v in self.cd:
            m = max(m, v)
        return m

    def _fold(self, phi_deg: Float64) -> Float64:
        """A horizontal angle (any) moved into the range the file covers, by its symmetry."""
        var p = phi_deg - 360.0 * Float64(Int(phi_deg / 360.0))
        if p < 0.0:
            p += 360.0
        var first = self.horiz[0]
        var last = self.horiz[len(self.horiz) - 1]
        if len(self.horiz) == 1:
            return first
        if first >= 90.0 - 1e-6 and last <= 270.0 + 1e-6:  # about the 90-270 plane
            if p < 90.0:
                return 180.0 - p
            if p > 270.0:
                return 540.0 - p
            return p
        if last <= 90.0 + 1e-6:  # quadrants
            p = p - 180.0 * Float64(Int(p / 180.0))
            return 180.0 - p if p > 90.0 else p
        if last <= 180.0 + 1e-6:  # halves
            return 360.0 - p if p > 180.0 else p
        return p

    def _column(self, h: Int, theta_deg: Float64) -> Float64:
        var nv = len(self.vert)
        if theta_deg < self.vert[0] - 1e-9 or theta_deg > self.vert[nv - 1] + 1e-9:
            return 0.0
        var i = 0
        while i < nv - 2 and self.vert[i + 1] < theta_deg:
            i += 1
        var f = min(max((theta_deg - self.vert[i]) / (self.vert[i + 1] - self.vert[i]), 0.0), 1.0)
        return self.cd[h * nv + i] * (1.0 - f) + self.cd[h * nv + i + 1] * f

    def candela(self, theta: Float64, phi: Float64) -> Float64:
        """The candela at `theta` radians from the light's axis and `phi` radians around it, linear between the file's
        angles."""
        var th = theta * 180.0 / pi
        var p = self._fold(phi * 180.0 / pi)
        var nh = len(self.horiz)
        if nh == 1:
            return self._column(0, th)
        var j = 0
        while j < nh - 2 and self.horiz[j + 1] < p:
            j += 1
        var f = min(max((p - self.horiz[j]) / (self.horiz[j + 1] - self.horiz[j]), 0.0), 1.0)
        return self._column(j, th) * (1.0 - f) + self._column(j + 1, th) * f

    def lumens(self, steps: Int = 360) -> Float64:
        """The flux the table sends out: the candela integrated over the sphere (midpoint rule on steps x 2 steps cells)."""
        var s = 0.0
        var dth = pi / Float64(steps)
        var dph = pi / Float64(steps)
        for i in range(steps):
            var th = (Float64(i) + 0.5) * dth
            var ring = 0.0
            for j in range(2 * steps):
                ring += self.candela(th, (Float64(j) + 0.5) * dph)
            s += ring * sin(th) * dth * dph
        return s

    def bake(self) -> List[Float32]:
        """The table the shader reads: IES_PHI rows of IES_THETA samples, candela over the peak (0 .. 1). Row j is the
        horizontal angle j / IES_PHI turns, sample i the vertical angle i / (IES_THETA - 1) half turns."""
        var peak = max(self.peak(), 1e-12)
        var out = List[Float32]()
        for j in range(IES_PHI):
            var ph = Float64(j) / Float64(IES_PHI) * 2.0 * pi
            for i in range(IES_THETA):
                var th = Float64(i) / Float64(IES_THETA - 1) * pi
                out.append(Float32(self.candela(th, ph) / peak))
        return out^


def baked_lookup(table: List[Float32], theta: Float64, phi: Float64) -> Float64:
    """What the shader reads from a baked table (IesProfile.bake) at `theta` and `phi` radians: bilinear, the
    horizontal angle wrapping round (app/wgsl.mojo LIGHT_TEX_WGSL ies_at). For tests."""
    var u = min(max(theta / pi, 0.0), 1.0) * Float64(IES_THETA - 1)
    var p = phi / (2.0 * pi)
    p = p - Float64(Int(p))
    if p < 0.0:
        p += 1.0
    var v = p * Float64(IES_PHI)
    var i0 = min(Int(u), IES_THETA - 2)
    var fu = u - Float64(i0)
    var j0 = min(Int(v), IES_PHI - 1)
    var fv = v - Float64(j0)
    var j1 = (j0 + 1) % IES_PHI
    var a = Float64(table[j0 * IES_THETA + i0]) * (1.0 - fu) + Float64(table[j0 * IES_THETA + i0 + 1]) * fu
    var b = Float64(table[j1 * IES_THETA + i0]) * (1.0 - fu) + Float64(table[j1 * IES_THETA + i0 + 1]) * fu
    return a * (1.0 - fv) + b * fv
