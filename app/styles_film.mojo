"""Pipelines after film, photographic and imaging processes. What the process records is in the pipeline: an exposure
that lasts many frames, two records made side by side, a second eye, a band the eye does not see drawn by its own
pass, rays that are not stopped by the first surface they meet."""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.post import Style, Stage, ThenPost, Join, Scaled, History, SceneSize, Stereo, Copy
from app.render_pass import Then
from app.shadow_pass import ShadowPass
from app.mesh_pass import MeshPassOf
from app.material import Material
from app.gpu_blend import BLEND_ADD
from app.gbuffer import MatNothing
from app.styles_material import MatSkyDark
from app.styles_display import MatHidden, MatBlackSky
from app.styles_util import Blur13, BrightPass, StreakH


# ---------------------------------------------------------------- 39. daguerreotype
struct LongExposure(Style):
    comptime NAME: StaticString = "daguerreotype"
    comptime AFTER: StaticString = "daguerreotypes: one warm tone on a silvered plate, exposures of many seconds"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let g = pow(luma(blur9(uv, 1.0)), 0.9);
  var c = mix(vec3<f32>(0.10, 0.06, 0.03), vec3<f32>(0.98, 0.90, 0.72), g) * vignette(uv, 2.0);
  let scratch = step(0.997, hash21(vec2<f32>(floor(px.x), 10.0))) * step(0.3, vnoise(vec2<f32>(px.x, px.y * 0.01)));
  c = c * (0.92 + 0.16 * vnoise(px * 0.7)) + scratch * 0.2 - step(0.9992, hash21(floor(px / 2.0) + 7.0)) * 0.4;
  // the plate keeps gathering light: seven eighths of what is on it stays, one eighth is this instant
  return mix(c, prev_at(uv), 0.875 * step(0.5, frame.t.y));
}
"""

# Not a filter: the plate integrates. Each frame adds an eighth to what the plate already holds, so whatever moved
# during the exposure is a smear or is not there, and what stood still is sharp. One frame alone has no such record.
comptime Daguerreotype = History[Stage[LongExposure]]


# ---------------------------------------------------------------- 40. film noir
struct MatNoir(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "one hard key light through a blind"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let l = normalize(vec3<f32>(0.4, 1.0, 0.6));
  // the slats of a blind between the lamp and the room: planes that contain the light's direction, so their shadow
  // bars fall along it and bend over every surface they land on
  let side = normalize(cross(l, vec3<f32>(0.2, 0.0, 1.0)));
  let slat = smoothstep(0.42, 0.58, abs(fract(dot(s.wpos, side) * 0.38) - 0.5) * 2.0);
  let key = max(dot(n, l), 0.0) * s.sf * slat;
  let v = dot(s.base, vec3<f32>(0.333)) * (0.035 + 1.5 * key);
  return vec4<f32>(vec3<f32>(smoothstep(0.03, 0.75, v)), 1.0);"""


struct GrainVignette(Style):
    comptime NAME: StaticString = "film_noir"
    comptime AFTER: StaticString = "1940s Hollywood film noir cinematography"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return (src_at(uv) + 0.25 * max(blur9(uv, 3.0) - 0.6, vec3<f32>(0.0)) + (hash21(px + frame.t.z) - 0.5) * 0.14) * vignette(uv, 1.9);
}
"""

# Not a filter: the picture is lit differently. One key light, no fill; the blind's bars are planes through the
# light's direction, cut off wherever the shadow map says something stands between the lamp and the surface.
comptime FilmNoirPasses = Then[ShadowPass, MeshPassOf[MatNoir, MatSkyDark]]
comptime FilmNoir = Stage[GrainVignette]


# ---------------------------------------------------------------- 41. two-strip colour
struct RedRecord(Style):
    comptime NAME: StaticString = "record behind the red filter"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(src_at(uv).r + (hash21(px + 1.0 + frame.t.z) - 0.5) * 0.05);
}
"""


struct GreenRecord(Style):
    comptime NAME: StaticString = "record behind the green filter"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(dot(src_at(uv).gb, vec2<f32>(0.6, 0.4)) + (hash21(px + 9.0 + frame.t.z) - 0.5) * 0.05);
}
"""


struct DyePrint(Style):
    comptime NAME: StaticString = "two_strip"
    comptime AFTER: StaticString = "two-strip Technicolor (Process 2, 1920s): two black-and-white records dyed and cemented"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let r = src_at(uv).r;
  let g = mix(src2_at(uv + vec2<f32>(1.5, 0.8) * frame.res.zw).r, src2_at(uv + vec2<f32>(3.0, 0.8) * frame.res.zw).r, 0.3);
  let o = r * vec3<f32>(1.0, 0.33, 0.16) + g * vec3<f32>(0.0, 0.70, 0.62);
  return smoothstep(vec3<f32>(0.03), vec3<f32>(0.97), o) * vignette(uv, 0.8);
}
"""

# Not a filter over a colour picture: there is no colour picture. Two grey records are made behind two filters, each
# with its own grain, and the print is the two dyed and laid together slightly out of register; blue and yellow have
# no record of their own and cannot come back.
comptime TwoStrip = Join[Stage[RedRecord], Stage[GreenRecord], Stage[DyePrint]]


# ---------------------------------------------------------------- 42. VHS
struct TapeLuma(Style):
    comptime NAME: StaticString = "luma, full band"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var y = 0.0;
  for (var i = -2; i <= 2; i++) { y += luma(src_at(uv + vec2<f32>(f32(i) * frame.res.z, 0.0))); }
  return vec3<f32>(y / 5.0);
}
"""


struct TapeChroma(Style):
    comptime NAME: StaticString = "chroma, a quarter of the band"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  return vec3<f32>(0.5 + 0.5 * dot(c, vec3<f32>(0.596, -0.274, -0.322)), 0.5 + 0.5 * dot(c, vec3<f32>(0.211, -0.523, 0.312)), 0.0);
}
"""


struct VhsPlayback(Style):
    comptime NAME: StaticString = "vhs"
    comptime AFTER: StaticString = "VHS tape played on a consumer deck"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let row = floor(px.y / 2.0);
  var jit = (hash21(vec2<f32>(row, frame.t.y)) - 0.5) * 2.0 * frame.res.z;
  let band = smoothstep(0.94, 1.0, uv.y);
  jit += band * (0.04 + 0.02 * sin(px.y * 1.3));
  jit += step(0.975, hash21(vec2<f32>(floor(px.y / 11.0), 5.0 + frame.t.y))) * 0.014;
  let u = vec2<f32>(uv.x + jit, uv.y);
  let y = src_at(u).r;
  let iq = (src2_at(u - vec2<f32>(8.0 * frame.res.z, 0.0)).rg * 2.0 - 1.0) * 0.85;
  var o = vec3<f32>(y + 0.956 * iq.x + 0.621 * iq.y, y - 0.272 * iq.x - 0.647 * iq.y, y - 1.106 * iq.x + 1.703 * iq.y);
  o = o * 0.86 + 0.05;
  o += step(0.9975, hash21(vec2<f32>(floor(px.x / 26.0), row + frame.t.y))) * 0.55;
  o += band * (hash21(px + 1.0) - 0.3) * 0.5;
  // what the heads read last frame is still in the signal path: a faint image a few pixels late
  return mix(o, prev_at(uv - vec2<f32>(6.0 * frame.res.z, 0.0)), 0.22);
}
"""

# Not a filter: the tape holds two signals of different bandwidth. Brightness is recorded at full width; colour is
# recorded in a target a quarter as wide and read back late, so colour cannot be sharper than that whatever the
# picture; and the last frame is still on the heads.
comptime Vhs = History[Join[Stage[TapeLuma], Scaled[Stage[TapeChroma], 4], Stage[VhsPlayback]]]


# ---------------------------------------------------------------- 43. anaglyph
struct AnaglyphPrint(Style):
    comptime NAME: StaticString = "anaglyph"
    comptime AFTER: StaticString = "red-cyan anaglyph 3-D films of the 1950s"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let conv = vec2<f32>(0.011, 0.0);   // slide the two pictures so that 9 m is in the plane of the screen
  let l = src_at(uv - conv);
  let r = src2_at(uv + conv);
  return vec3<f32>(luma(l), mix(luma(r), r.g, 0.6), mix(luma(r), r.b, 0.6));
}
"""

# Not a filter: the scene is drawn from two eyes. The red picture is the left eye's and the cyan the right's, and each
# shows the strip of background the other eye has hidden behind a near object. One picture shifted by its depth has
# nothing to put there.
comptime Anaglyph = Stereo[Stage[AnaglyphPrint]]


# ---------------------------------------------------------------- 44. colour infrared
struct MatInfrared(Material):
    """How much near-infrared a surface throws back, as grey: leaf-green reflects it strongly, most paints and the
    metal little. This is a property of the material, not of the visible picture."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "infrared reflectance"
    comptime BODY: StaticString = """
  let leaf = clamp(2.6 * s.base.g - 1.3 * s.base.b - 0.9 * s.base.r + 0.1, 0.0, 1.0);
  let lit = 0.35 + 0.65 * max(dot(normalize(s.wnrm), normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf;
  let ir = (0.12 + 0.88 * leaf) * (1.0 - 0.7 * s.metal) * lit;
  return vec4<f32>(ir, ir, ir, 1.0);"""


struct FalseColour(Style):
    comptime NAME: StaticString = "aerochrome"
    comptime AFTER: StaticString = "Kodak Aerochrome colour infrared film"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let a = aux_at(uv);
  // the film's three layers: infrared prints red, red prints green, green prints blue; a clear sky is dark in infrared
  var o = vec3<f32>(a.r * a.a + 0.05 * (1.0 - a.a), c.r * 0.85, c.g * 0.8);
  o = smoothstep(vec3<f32>(0.04), vec3<f32>(0.92), o);
  return (o + (hash21(px + frame.t.z) - 0.5) * 0.05) * vignette(uv, 0.7);
}
"""

# Not a filter: the film has a layer that sees a band the eye does not. That band is drawn by a second pass list into
# the aux target, from what each surface is; the visible frame cannot supply it (two greens of the same colour may
# differ completely in infrared).
comptime Aerochrome = Stage[FalseColour]
comptime AerochromeAux = MeshPassOf[MatInfrared, MatNothing]


# ---------------------------------------------------------------- 45. tilt-shift
struct FocusMix(Style):
    comptime NAME: StaticString = "tilt_shift"
    comptime AFTER: StaticString = "tilt-shift miniature-faking photography"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let coc = clamp(abs(view_z(uv) - 9.0) * 0.28 - 0.1, 0.0, 1.0);
  var c = mix(src_at(uv), src2_at(uv), coc);
  let g = luma(c);
  c = mix(vec3<f32>(g), c, 1.6);
  return smoothstep(vec3<f32>(0.04), vec3<f32>(0.96), c);
}
"""

# Not a filter of fixed size: the out-of-focus picture is made once in a quarter-size target (a blur 10 pixels wide for
# the cost of one 2.5 wide) and each pixel takes sharp or soft by its depth.
comptime TiltShift = Join[Stage[Copy], Scaled[Stage[Blur13], 4], Stage[FocusMix]]


# ---------------------------------------------------------------- 46. anamorphic
struct AnamorphicGrade(Style):
    comptime NAME: StaticString = "anamorphic"
    comptime AFTER: StaticString = "anamorphic-lens blockbuster cinematography with a teal-and-orange grade"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let bar = (frame.res.y - frame.res.x / 2.39) * 0.5;
  if px.y < bar || px.y > frame.res.y - bar { return vec3<f32>(0.0); }
  var c = src_at(uv);
  let l = luma(c);
  c = mix(c * vec3<f32>(0.62, 0.98, 1.12), c * vec3<f32>(1.2, 1.0, 0.74), smoothstep(0.3, 0.75, l));
  c = smoothstep(vec3<f32>(0.06), vec3<f32>(1.0), c);
  c += src2_at(uv) * vec3<f32>(0.45, 0.75, 1.6) * 2.2;
  let d = (uv - 0.5) * vec2<f32>(1.0, 1.6);
  return c * clamp(1.0 - 1.1 * dot(d, d), 0.0, 1.0);
}
"""

# Not a filter: the streak is its own branch. The highlights are cut out and smeared 240 pixels sideways in a
# quarter-size target, beside the untouched picture, and the grade puts the two together.
comptime Anamorphic = Join[Stage[Copy], Scaled[ThenPost[Stage[BrightPass], Stage[StreakH]], 4], Stage[AnamorphicGrade]]


# ---------------------------------------------------------------- 47. instant print
struct InstantCard(Style):
    comptime NAME: StaticString = "instant_print"
    comptime AFTER: StaticString = "Polaroid SX-70 instant prints: a square picture on a white card"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let side = frame.res.y * 0.74;
  let q = vec2<f32>((px.x - frame.res.x * 0.5) / side, (px.y - frame.res.y * 0.06) / side);
  if abs(px.x - frame.res.x * 0.5) > side * 0.5 + frame.res.y * 0.055 {
    return vec3<f32>(0.20, 0.17, 0.15) * (0.8 + 0.4 * fbm(vec2<f32>(px.x * 0.01, px.y * 0.2)));
  }
  if abs(q.x) > 0.5 || q.y < 0.0 || q.y > 1.0 {
    let lip = smoothstep(0.0, 0.012, max(abs(q.x) - 0.5, max(-q.y, q.y - 1.0)));
    return vec3<f32>(0.95, 0.94, 0.90) * (0.9 + 0.1 * lip) * (0.98 + 0.03 * vnoise(px * 0.6));
  }
  let u = vec2<f32>(q.x + 0.5, q.y);
  var c = src_at(u);
  let l = luma(c);
  c = mix(c * vec3<f32>(0.85, 1.02, 1.05), c * vec3<f32>(1.08, 1.0, 0.84), smoothstep(0.2, 0.8, l));
  c = c * 0.78 + vec3<f32>(0.10, 0.10, 0.12);
  let d = q - vec2<f32>(0.0, 0.5);
  return c * (1.0 - 0.7 * dot(d, d));
}
"""

# Not a crop of the wide frame: the camera's picture is square, so the scene is drawn for a square, 264 pixels a side
# (the print's own softness), with the camera's field of view fitted to it.
comptime InstantPrint = SceneSize[Stage[InstantCard], 264, 264]


# ---------------------------------------------------------------- 48. night vision
struct Intensifier(Style):
    comptime NAME: StaticString = "photocathode and gain"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let gain = pow(luma(src_at(uv)), 0.55) * 1.15 - 0.15;
  let noise = (hash21(floor(px / 1.5) + frame.t.y * 17.0) - 0.4) * 0.35;
  return vec3<f32>(clamp(gain + noise, 0.0, 1.3));
}
"""


struct TubeScreen(Style):
    comptime NAME: StaticString = "night_vision"
    comptime AFTER: StaticString = "image-intensifier night-vision goggles"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let r = length((uv - 0.5) * vec2<f32>(frame.res.x / frame.res.y, 1.0));
  let v = src_at(uv).r + 0.9 * max(src2_at(uv).r - 0.55, 0.0);
  let now = (vec3<f32>(0.12, 1.0, 0.22) * v + vec3<f32>(pow(v, 5.0) * 0.5)) * smoothstep(0.5, 0.46, r) * (1.0 - 0.9 * r * r);
  // the phosphor screen is slow: it shows the brighter of this frame and what is left of the last
  return max(now, prev_at(uv) * 0.7) * (0.9 + 0.1 * sin(px.y * 3.14159));
}
"""

# Not a filter: three things happen in three places. The gain and its noise are one target; the halo round a bright
# source is that target spread at a quarter size; and the screen's phosphor holds the last frame, so the noise of
# several frames averages in what you see and a moving light drags a tail.
comptime NightVision = History[Join[Stage[Intensifier], Scaled[Stage[Blur13], 4], Stage[TubeScreen]]]


# ---------------------------------------------------------------- 49. thermal camera
struct MatHeat(Material):
    """Temperature as grey: warm-coloured bodies are the hot ones, sunlit faces are warmer than shaded ones, metal
    reads cold (low emissivity)."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "temperature"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let sun = max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf;
  let body = dot(s.base, vec3<f32>(0.85, 0.1, -0.45));
  let h = clamp(0.08 + 0.55 * body + 0.28 * sun - 0.3 * s.metal, 0.0, 1.0);
  return vec4<f32>(h, h, h, 1.0);"""


struct Ironbow(Style):
    comptime NAME: StaticString = "thermal"
    comptime AFTER: StaticString = "handheld thermal-imaging cameras: a 320 x 180 sensor, the ironbow palette"
    comptime WGSL: StaticString = """
fn ironbow(t : f32) -> vec3<f32> {
  var c = mix(vec3<f32>(0.0, 0.0, 0.03), vec3<f32>(0.30, 0.0, 0.52), smoothstep(0.0, 0.22, t));
  c = mix(c, vec3<f32>(0.86, 0.10, 0.36), smoothstep(0.22, 0.46, t));
  c = mix(c, vec3<f32>(1.0, 0.55, 0.0), smoothstep(0.46, 0.70, t));
  c = mix(c, vec3<f32>(1.0, 0.95, 0.30), smoothstep(0.70, 0.90, t));
  return mix(c, vec3<f32>(1.0), smoothstep(0.90, 1.0, t));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var o = ironbow(src_texel(uv).r);
  if uv.x > 0.952 && uv.x < 0.976 && uv.y > 0.15 && uv.y < 0.85 {
    o = ironbow(1.0 - (uv.y - 0.15) / 0.7);
    if uv.x < 0.955 || uv.x > 0.973 || uv.y < 0.156 || uv.y > 0.844 { o = vec3<f32>(1.0); }
  }
  let d = abs(px - frame.res.xy * 0.5);
  if (d.x < 1.0 && d.y > 4.0 && d.y < 14.0) || (d.y < 1.0 && d.x > 4.0 && d.x < 14.0) { o = vec3<f32>(1.0); }
  return o;
}
"""

# Not a filter: what is drawn is temperature. The passes write it per surface (from what the thing is, whether the sun
# reaches it and whether it is metal), on the sensor's own 320 x 180 grid; no colour picture is made at any point.
comptime ThermalPasses = Then[ShadowPass, MeshPassOf[MatHeat, MatSkyDark]]
comptime Thermal = SceneSize[Stage[Ironbow], 320, 180]


# ---------------------------------------------------------------- 50. radiograph
struct MatXray(Material):
    """Every surface a ray crosses adds to the exposure, more where it crosses at a glancing angle (a longer path
    through the wall): added to the target, depth not written, back faces too."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "absorption, added, depth not written"
    comptime BLEND: Int = BLEND_ADD
    comptime DEPTH_WRITE: Bool = False
    comptime BODY: StaticString = """
  let f = 1.0 - abs(dot(normalize(s.wnrm), normalize(cam.eye.xyz - s.wpos)));
  let d = 0.055 + 0.30 * pow(f, 2.2);
  return vec4<f32>(d, d, d, 1.0);"""


struct XrayFilm(Style):
    comptime NAME: StaticString = "radiograph"
    comptime AFTER: StaticString = "X-ray film radiographs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let v = src_at(uv).r + 0.35 * blur9(uv, 3.0).r;
  var o = mix(vec3<f32>(0.01, 0.02, 0.05), vec3<f32>(0.80, 0.92, 1.0), pow(clamp(v * 1.25, 0.0, 1.0), 0.75));
  o += (hash21(px + frame.t.z) - 0.5) * 0.06;
  return o * vignette(uv, 1.2);
}
"""

# Not a filter: a finished frame holds only the nearest surface at each pixel. Here nothing hides anything: every
# surface of every object, front and back, adds its absorption to the target, so a ball behind a wall is in the
# picture and where two things overlap the film is denser.
comptime RadiographPasses = Then[MeshPassOf[MatHidden, MatBlackSky], MeshPassOf[MatXray, MatNothing]]
comptime Radiograph = Stage[XrayFilm]
