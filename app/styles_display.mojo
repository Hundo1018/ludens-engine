"""Pipelines after display hardware. Each rebuilds the frame the way the machine did, and the part that makes it that
machine is in the pipeline, not in a filter: the scene is rasterised at the machine's resolution (SceneSize), colour
cells are a second, smaller target (Sized), a slow panel or a phosphor is the last frame read back (History), a vector
tube is drawn as lines (WirePassOf). The comment on each says what a full-screen shader over a finished frame could not
have done."""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.post import Style, Stage, ThenPost, Join, Scaled, History, Sized, SceneSize, Stereo, Copy
from app.render_pass import Then
from app.shadow_pass import ShadowPass
from app.primitive_pass import PrimitivePass
from app.mesh_pass import MeshPassOf
from app.material import Material, MatSky
from app.wire_pass import WireKind, WirePassOf
from app.gpu_blend import BLEND_ADD, DEPTH_ALWAYS
from app.gbuffer import NormalPasses, MatNothing
from app.styles_util import Blur13, AddGlow


# ---------------------------------------------------------------- 1. dot-matrix handheld
struct DmgLcd(Style):
    comptime NAME: StaticString = "dot_matrix_handheld"
    comptime AFTER: StaticString = "the 1989 Game Boy (DMG-01) screen"
    comptime WGSL: StaticString = """
const DMG = array<vec3<f32>, 4>(vec3<f32>(0.06, 0.22, 0.06), vec3<f32>(0.19, 0.38, 0.19), vec3<f32>(0.55, 0.67, 0.06), vec3<f32>(0.61, 0.74, 0.06));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(160.0, 144.0));
  if !inside(u) { return vec3<f32>(0.70, 0.69, 0.64) * (0.96 + 0.05 * vnoise(px * 0.4)); }
  let cell = u * vec2<f32>(160.0, 144.0);
  let l = smoothstep(0.22, 0.92, luma(src_texel(u)));
  let q = u32(clamp(floor(l * 4.0 + bayer4(floor(cell)) - 0.5), 0.0, 3.0));
  let f = fract(cell);
  let now = mix(DMG[3] * 0.93, DMG[q], step(0.12, f.x) * step(0.12, f.y));
  return mix(now, prev_at(uv), 0.5);
}
"""

# Not a filter: the triangles are sampled on the 160 x 144 grid (an edge lands on whole dots), and the panel is slow:
# half of each dot is what it showed last frame, so a moving object leaves the handheld's ghost trail.
comptime DotMatrixHandheld = SceneSize[History[Stage[DmgLcd]], 160, 144]


# ---------------------------------------------------------------- 2. red LED visor
struct RedLedPair(Style):
    comptime NAME: StaticString = "red_led_visor"
    comptime AFTER: StaticString = "the 1995 Virtual Boy: two 384 x 224 red LED displays, one per eye"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let half = vec2<f32>(frame.res.x * 0.5, frame.res.y);
  let right = px.x >= half.x;
  let p = vec2<f32>(px.x - select(0.0, half.x, right), px.y);
  let size = vec2<f32>(384.0, 224.0);
  let k = min(half.x / size.x, half.y / size.y) * 0.94;
  let u = (p - (half - size * k) * 0.5) / (size * k);
  if !inside(u) { return vec3<f32>(0.0); }
  let c = select(src_texel(u), src2_texel(u).rgb, right);
  let cell = u * size;
  let l = smoothstep(0.3, 1.0, luma(c));
  let q = clamp(floor(l * 4.0 + bayer4(floor(cell)) - 0.5), 0.0, 3.0) / 3.0;
  let row = 0.6 + 0.4 * sin(fract(cell.y) * 3.14159);
  return vec3<f32>(q * row, q * q * 0.05, 0.0);
}
"""

# Not a filter: the scene is drawn twice, from two eyes. The right display shows what the right eye sees, including
# what a near object hides from the left one.
comptime RedLedVisor = Stereo[SceneSize[Stage[RedLedPair], 384, 224]]


# ---------------------------------------------------------------- 3. CGA on a composite monitor
comptime CGA_NTSC_WGSL = """
// what a composite monitor makes of a bit pattern: brightness is the mean of four bits, hue the phase they sit at
fn ntsc(y : f32, i0 : f32, q0 : f32) -> vec3<f32> {
  let i = i0 * 0.84 - q0 * 0.55;
  let q = i0 * 0.55 + q0 * 0.84;
  return clamp(vec3<f32>(y + 0.956 * i + 0.621 * q, y - 0.272 * i - 0.647 * q, y - 1.106 * i + 1.703 * q), vec3<f32>(0.0), vec3<f32>(1.0));
}
fn artifact(p : u32) -> vec3<f32> {
  let b = vec4<f32>(f32(p & 1u), f32((p >> 1u) & 1u), f32((p >> 2u) & 1u), f32((p >> 3u) & 1u));
  return ntsc((b.x + b.y + b.z + b.w) * 0.25, (b.x - b.z) * 0.5, (b.y - b.w) * 0.5);
}
"""


struct CgaBits(Style):
    """640 x 200, one bit per pixel: for each group of four pixels, the pattern whose artifact colour is nearest."""

    comptime NAME: StaticString = "cga_bits"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = CGA_NTSC_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let group = floor(px.x / 4.0);
  let c = scene_texel(vec2<f32>((group * 4.0 + 2.0) / 640.0, uv.y)) + (bayer4(vec2<f32>(group, floor(px.y))) - 0.5) * 0.22;
  var best = 0u;
  var bd = 1e9;
  for (var p = 0u; p < 16u; p++) {
    let d = artifact(p) - c;
    let dd = dot(d, d);
    if dd < bd { bd = dd; best = p; }
  }
  return vec3<f32>(f32((best >> (u32(px.x) & 3u)) & 1u));
}
"""


struct NtscDecode(Style):
    """The monitor: each point of the line is decoded from the four bits around it and their phase."""

    comptime NAME: StaticString = "cga_composite"
    comptime AFTER: StaticString = "the 1981 IBM CGA in 640 x 200 on a composite monitor: 16 artifact colours from 1-bit pixels"
    comptime WGSL: StaticString = CGA_NTSC_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(4.0, 3.0));
  if !inside(u) { return vec3<f32>(0.0); }
  let x = floor(u.x * 640.0);
  var y = 0.0;
  var i = 0.0;
  var q = 0.0;
  for (var k = 0; k < 4; k++) {
    let xi = x - 3.0 + f32(k);
    let b = src_texel(vec2<f32>((xi + 0.5) / 640.0, u.y)).r;
    let ph = u32(i32(xi) & 3);
    y += b * 0.25;
    i += b * 0.5 * (f32(ph == 0u) - f32(ph == 2u));
    q += b * 0.5 * (f32(ph == 1u) - f32(ph == 3u));
  }
  return ntsc(y, i, q);
}
"""

# Not a filter: there is no colour anywhere until the decoder. The first stage's target holds bits; the colours exist
# only as their phase, so a hue's edge shows the fringe the real signal has.
comptime CgaComposite = SceneSize[ThenPost[Sized[Stage[CgaBits], 640, 200], Stage[NtscDecode]], 640, 200, 4, 3]


# ---------------------------------------------------------------- 4. ZX Spectrum
comptime ZX_WGSL = """
fn zx_index(c : vec3<f32>) -> f32 {
  let l = luma(c);
  let b = step(vec3<f32>(0.5), clamp(mix(vec3<f32>(l), c, 3.0) * 0.9, vec3<f32>(0.0), vec3<f32>(1.0)));
  return (b.b + 2.0 * b.r + 4.0 * b.g + 8.0 * step(0.6, l)) / 15.0;
}
fn zx_color(v : f32) -> vec3<f32> {
  let i = u32(v * 15.0 + 0.5);
  return vec3<f32>(f32((i >> 1u) & 1u), f32((i >> 2u) & 1u), f32(i & 1u)) * select(0.84, 1.0, (i & 8u) != 0u);
}
"""


struct ZxAttr(Style):
    """The attribute file, 32 x 24: per 8 x 8 cell an ink, a paper and the brightness that divides them."""

    comptime NAME: StaticString = "zx_attributes"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = ZX_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let b0 = floor(px) * 8.0;
  var lo = vec3<f32>(1.0);
  var hi = vec3<f32>(0.0);
  var ll = 9.0;
  var lh = -1.0;
  for (var j = 0; j < 4; j++) { for (var i = 0; i < 4; i++) {
    let s = scene_texel((b0 + vec2<f32>(f32(i), f32(j)) * 2.0 + 1.0) / vec2<f32>(256.0, 192.0));
    let l = luma(s);
    if l < ll { ll = l; lo = s; }
    if l > lh { lh = l; hi = s; }
  } }
  return vec3<f32>(zx_index(lo), zx_index(hi), (ll + lh) * 0.5);
}
"""


struct ZxScreen(Style):
    comptime NAME: StaticString = "spectrum"
    comptime AFTER: StaticString = "the 1982 ZX Spectrum: 256 x 192 pixels, two colours per 8 x 8 attribute cell, a border"
    comptime WGSL: StaticString = ZX_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(320.0, 240.0));
  if !inside(u) { return vec3<f32>(0.0); }
  let v = (u * vec2<f32>(320.0, 240.0) - vec2<f32>(32.0, 24.0)) / vec2<f32>(256.0, 192.0);
  if !inside(v) { return vec3<f32>(0.0, 0.0, 0.84); }
  let a = src_texel(v);
  let l = luma(scene_texel(v)) + (bayer4(floor(v * vec2<f32>(256.0, 192.0))) - 0.5) * 0.12;
  return zx_color(select(a.r, a.g, l > a.b));
}
"""

# Not a filter: the two colours of a cell are stored once, in a 32 x 24 target, and every pixel of the cell is forced
# to one of them. Where two objects share a cell one of them takes the other's colour: the clash is a property of the
# storage.
comptime Spectrum = SceneSize[ThenPost[Sized[Stage[ZxAttr], 32, 24], Stage[ZxScreen]], 256, 192]


# ---------------------------------------------------------------- 5. Commodore 64
comptime C64_WGSL = """
const C64P = array<vec3<f32>, 16>(
  vec3<f32>(0.0, 0.0, 0.0), vec3<f32>(1.0, 1.0, 1.0), vec3<f32>(0.41, 0.22, 0.17), vec3<f32>(0.44, 0.64, 0.70),
  vec3<f32>(0.44, 0.24, 0.53), vec3<f32>(0.35, 0.55, 0.26), vec3<f32>(0.21, 0.16, 0.47), vec3<f32>(0.72, 0.78, 0.44),
  vec3<f32>(0.44, 0.31, 0.15), vec3<f32>(0.26, 0.22, 0.0), vec3<f32>(0.60, 0.40, 0.35), vec3<f32>(0.27, 0.27, 0.27),
  vec3<f32>(0.42, 0.42, 0.42), vec3<f32>(0.60, 0.82, 0.52), vec3<f32>(0.42, 0.37, 0.71), vec3<f32>(0.58, 0.58, 0.58));
fn c64_near(c : vec3<f32>) -> u32 {
  var best = 0u;
  var bd = 1e9;
  for (var i = 0u; i < 16u; i++) {
    let d = C64P[i] - c;
    let dd = dot(d * vec3<f32>(0.6, 1.0, 0.45), d);
    if dd < bd { bd = dd; best = i; }
  }
  return best;
}
"""


struct C64Cell(Style):
    """The colour memory, 40 x 25: the three palette entries most used in each 4 x 8 cell (the fourth colour is the
    shared background, black)."""

    comptime NAME: StaticString = "c64_cells"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = C64_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var count : array<u32, 16>;
  let b0 = floor(px) * vec2<f32>(4.0, 8.0);
  for (var j = 0; j < 8; j++) { for (var i = 0; i < 4; i++) {
    let k = c64_near(scene_texel((b0 + vec2<f32>(f32(i), f32(j)) + 0.5) / vec2<f32>(160.0, 200.0)));
    count[k] += 1u;
  } }
  count[0] = 0u;
  var pick = vec3<f32>(0.0);
  for (var n = 0; n < 3; n++) {
    var best = 0u;
    var bc = 0u;
    for (var i = 1u; i < 16u; i++) { if count[i] > bc { bc = count[i]; best = i; } }
    count[best] = 0u;
    pick[n] = f32(best) / 15.0;
  }
  return pick;
}
"""


struct C64Screen(Style):
    comptime NAME: StaticString = "c64"
    comptime AFTER: StaticString = "the 1982 Commodore 64, multicolour bitmap: 160 x 200 double-wide pixels, 3 colours per cell and a background"
    comptime WGSL: StaticString = C64_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(384.0, 272.0));
  if !inside(u) { return vec3<f32>(0.0); }
  let v = (u * vec2<f32>(384.0, 272.0) - vec2<f32>(32.0, 36.0)) / vec2<f32>(320.0, 200.0);
  if !inside(v) { return C64P[14]; }
  let cell = src_texel(v);
  let c = scene_texel(v) + (bayer4(floor(v * vec2<f32>(160.0, 200.0))) - 0.5) * 0.12;
  var o = C64P[0];
  var bd = dot(c, c);
  for (var n = 0; n < 3; n++) {
    let p = C64P[u32(cell[n] * 15.0 + 0.5)];
    let d = p - c;
    if dot(d, d) < bd { bd = dot(d, d); o = p; }
  }
  return o;
}
"""

# Not a filter: as with the Spectrum, each cell's colours are a second target (40 x 25), chosen by counting, and the
# pixels are 2 : 1 because the scene is rasterised 160 wide for a 320-wide picture.
comptime C64 = SceneSize[ThenPost[Sized[Stage[C64Cell], 40, 25], Stage[C64Screen]], 160, 200, 8, 5]


# ---------------------------------------------------------------- 6. 1-bit screen
struct MacScreen(Style):
    comptime NAME: StaticString = "one_bit"
    comptime AFTER: StaticString = "the 1984 Macintosh: 512 x 342, black or white, MacPaint's dither patterns"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(512.0, 342.0));
  let r = abs(u - 0.5) * vec2<f32>(512.0, 342.0) - vec2<f32>(248.0, 163.0);
  if !inside(u) || length(max(r, vec2<f32>(0.0))) > 8.0 { return vec3<f32>(0.0); }
  let l = pow(luma(src_texel(u)), 0.85);
  return vec3<f32>(step(bayer8(floor(u * vec2<f32>(512.0, 342.0))), l) * (1.0 - step(0.5, gedge(u, 1.0))));
}
"""

# Not a filter: the outlines are one screen pixel wide because the normals they come from are rasterised at 512 x 342
# too (the aux target follows the scene's size), and they are the mesh's own normals, so a sphere has no facet lines.
comptime OneBit = SceneSize[Stage[MacScreen], 512, 342]
comptime OneBitAux = NormalPasses


# ---------------------------------------------------------------- 7. character terminal
struct AsciiCells(Style):
    comptime NAME: StaticString = "ascii_terminal"
    comptime AFTER: StaticString = "ASCII art on an 80 x 30 green-phosphor terminal (VT100)"
    comptime WGSL: StaticString = """
const GLYPH = array<i32, 9>(0, 131072, 131200, 14336, 145536, 469440, 11512810, 15252014, 13199452);
fn cell_l(u : vec2<f32>) -> f32 { return luma(src_texel(u)) * (1.0 - 0.5 * is_far(u, 60.0)); }
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let n = vec2<f32>(80.0, 30.0);
  let id = floor(uv * n);
  let u = (id + 0.5) / n;
  let l = clamp(cell_l(u), 0.0, 1.0);
  let gx = cell_l(u + vec2<f32>(1.0 / n.x, 0.0)) - cell_l(u - vec2<f32>(1.0 / n.x, 0.0));
  let gy = cell_l(u + vec2<f32>(0.0, 1.0 / n.y)) - cell_l(u - vec2<f32>(0.0, 1.0 / n.y));
  var g = GLYPH[u32(clamp(l * 9.0, 0.0, 8.0))];
  var bright = 0.45 + 0.55 * l;
  if abs(gx) + abs(gy) > 0.16 {
    bright = 1.0;
    if abs(gx) > 2.0 * abs(gy) { g = 4329604; } else if abs(gy) > 2.0 * abs(gx) { g = 14336; } else if gx * gy > 0.0 { g = 1118480; } else { g = 17043521; }
  }
  let f = fract(uv * n) * vec2<f32>(1.2, 1.25) - vec2<f32>(0.1, 0.12);
  var ink = 0.0;
  if f.x >= 0.0 && f.x < 1.0 && f.y >= 0.0 && f.y < 1.0 {
    let q = vec2<i32>(floor(f * 5.0));
    ink = f32((g >> u32(q.x + 5 * q.y)) & 1);
  }
  return vec3<f32>(0.10, 1.0, 0.35) * ink * bright * (0.8 + 0.2 * sin(px.y * 3.14159)) + vec3<f32>(0.0, 0.035, 0.012);
}
"""

# Not a filter: one rasterised sample per character cell. A border between two cells is seen as a difference of
# neighbouring samples and drawn with the line character of its direction ( | - / \\ ).
comptime AsciiTerminal = SceneSize[Stage[AsciiCells], 80, 30, 16, 9]


# ---------------------------------------------------------------- 8. CRT television
struct CompositeBleed(Style):
    """The signal: brightness keeps its detail, colour is averaged along the line (YIQ, 13 taps), bright edges ring."""

    comptime NAME: StaticString = "composite_bleed"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn yiq(c : vec3<f32>) -> vec3<f32> {
  return vec3<f32>(dot(c, vec3<f32>(0.299, 0.587, 0.114)), dot(c, vec3<f32>(0.596, -0.274, -0.322)), dot(c, vec3<f32>(0.211, -0.523, 0.312)));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let e = vec2<f32>(frame.res.z, 0.0);
  var iq = vec2<f32>(0.0);
  for (var i = -6; i <= 6; i++) { iq += yiq(src_at(uv + e * f32(i) * 1.5)).yz; }
  iq /= 13.0;
  let y = yiq(src_at(uv)).x * 1.15 - 0.15 * yiq(src_at(uv - e * 3.0)).x;
  return vec3<f32>(y + 0.956 * iq.x + 0.621 * iq.y, y - 0.272 * iq.x - 0.647 * iq.y, y - 1.106 * iq.x + 1.703 * iq.y);
}
"""


struct CrtTube(Style):
    comptime NAME: StaticString = "crt_tube"
    comptime AFTER: StaticString = "a 1980s interlaced CRT television on a composite input"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = uv * 2.0 - 1.0;
  let u = d * (1.0 + 0.11 * dot(d.yx * d.yx, vec2<f32>(1.0, 0.6))) * 0.5 + 0.5;
  if !inside(u) { return vec3<f32>(0.0); }
  let line = floor(u.y * 480.0);
  if (u32(line) & 1u) != (u32(frame.t.y) & 1u) { return prev_at(uv) * 0.7; }
  var c = src_at(u);
  c = c * c;
  let k = u32(px.x) % 3u;
  let mask = vec3<f32>(f32(k == 0u), f32(k == 1u), f32(k == 2u)) * 1.5 + 0.35;
  c = c * mask * 2.0;
  let corner = smoothstep(0.0, 0.03, u.x) * smoothstep(0.0, 0.03, 1.0 - u.x) * smoothstep(0.0, 0.04, u.y) * smoothstep(0.0, 0.04, 1.0 - u.y);
  return sqrt(c) * corner * vignette(uv, 0.9);
}
"""

# Not a filter: each frame the beam draws one field, the odd or the even lines; the other lines are what the phosphor
# still shows of the last frame, dimmer. A moving edge is combed.
comptime CrtTelevision = ThenPost[Stage[CompositeBleed], History[Stage[CrtTube]]]


# ---------------------------------------------------------------- 9. vector display
struct BeamLines(WireKind):
    comptime NAME: StaticString = "beam, additive, no depth test"
    comptime BLEND: Int = BLEND_ADD
    comptime DEPTH_COMPARE: Int = DEPTH_ALWAYS
    comptime FRAG: StaticString = """
  return vec4<f32>(0.22, 0.62, 0.46, 1.0);"""


struct MatHidden(Material):
    """Draws nothing (with MatBlackSky: the solids are absent, the sky is black)."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "none"
    comptime BODY: StaticString = """
  discard;
  return vec4<f32>(0.0);"""


struct MatBlackSky(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "black sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.0, 0.0, 0.0, 1.0);"""


struct PhosphorPersist(Style):
    comptime NAME: StaticString = "vector_scope"
    comptime AFTER: StaticString = "vector displays: the 1982 Vectrex, oscilloscope X-Y mode"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let now = src_at(uv) + 1.8 * src2_at(uv);
  return max(now, prev_at(uv) * 0.62) + vec3<f32>(0.0, 0.004, 0.006);
}
"""

# Not a filter: no surface is drawn at all. The pass draws line segments (line-list topology), added to each other
# with the depth test off, so the far side of a box shows through its near side and crossings are brighter, as on a
# tube with no hidden-line removal. The halo is the lines blurred at a quarter size; the trail is last frame's phosphor.
comptime VectorScopePasses = Then[MeshPassOf[MatHidden, MatBlackSky], WirePassOf[BeamLines]]
comptime VectorScope = History[Join[Stage[Copy], Scaled[Stage[Blur13], 4], Stage[PhosphorPersist]]]


# ---------------------------------------------------------------- 10. 32-bit console
struct MatSnap(Material):
    """Vertices snapped to a 320 x 240 grid after projection, colour lit per vertex."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "vertex snap"
    comptime VERT_CLIP: StaticString = "out.pos = vec4<f32>(floor(out.pos.xy / out.pos.w * vec2<f32>(160.0, 120.0) + 0.5) / vec2<f32>(160.0, 120.0) * out.pos.w, out.pos.zw);"
    comptime BODY: StaticString = """
  return vec4<f32>(s.color * (0.55 + 0.45 * s.sf), 1.0);"""


struct Dither15(Style):
    comptime NAME: StaticString = "console_32bit"
    comptime AFTER: StaticString = "mid-1990s 32-bit consoles: 320 x 240, vertices on whole pixels, 15-bit colour with ordered dither"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let u = fit_uv(px, vec2<f32>(4.0, 3.0));
  if !inside(u) { return vec3<f32>(0.0); }
  let c = src_texel(u) * 1.05;
  return clamp(floor(c * 31.0 + bayer4(floor(u * vec2<f32>(320.0, 240.0))) * 1.6 - 0.3) / 31.0, vec3<f32>(0.0), vec3<f32>(1.0));
}
"""

# Not a filter: the snap happens to the vertices, in the vertex stage, before the triangles are filled. Edges meet at
# whole pixels and a slowly moving object's outline jumps from one grid position to the next.
comptime Console32Passes = Then[ShadowPass, MeshPassOf[MatSnap, MatSky]]
comptime Console32 = SceneSize[Stage[Dither15], 320, 240]


# ---------------------------------------------------------------- 11. LED wall
struct LedEmitters(Style):
    comptime NAME: StaticString = "led_emitters"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let n = vec2<f32>(128.0, 72.0);
  var c = src_texel(uv);
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.5), vec3<f32>(0.0), vec3<f32>(1.0));
  let r = length(fract(uv * n) - 0.5);
  return c * c * smoothstep(0.42, 0.30, r) * 1.5;
}
"""


struct LedWallGlow(Style):
    comptime NAME: StaticString = "led_wall"
    comptime AFTER: StaticString = "stadium LED video boards"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> { return src_at(uv) + 1.2 * src2_at(uv); }
"""

# Not a filter: 128 x 72 rasterised samples, one per lamp; the light each lamp spills on its neighbours is the lamp
# picture blurred in a quarter-size target and added back.
comptime LedWall = SceneSize[ThenPost[Stage[LedEmitters], Join[Stage[Copy], Scaled[Stage[Blur13], 4], Stage[LedWallGlow]]], 128, 72]
