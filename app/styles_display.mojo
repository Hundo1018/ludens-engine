"""Post styles after display hardware (app/post.mojo Style): each rebuilds the frame on that machine's grid, palette and
tube or panel. Resolutions are the machines'; the frame's height is divided into that many rows."""
from app.post import Style


struct DotMatrixHandheld(Style):
    """160 x 144 reflective LCD, four olive shades, a visible gap between the dots."""

    comptime NAME: StaticString = "dot_matrix_handheld"
    comptime AFTER: StaticString = "the 1989 Game Boy (DMG-01) screen"
    comptime WGSL: StaticString = """
const DMG = array<vec3<f32>, 4>(vec3<f32>(0.06, 0.22, 0.06), vec3<f32>(0.19, 0.38, 0.19), vec3<f32>(0.55, 0.67, 0.06), vec3<f32>(0.61, 0.74, 0.06));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 144.0);
  let id = floor(px / cell);
  let l = smoothstep(0.22, 0.92, luma(src_at(cell_uv(px, cell))));
  let q = u32(clamp(floor(l * 4.0 + bayer4(id) - 0.5), 0.0, 3.0));
  let f = fract(px / cell);
  let dot = step(0.14, f.x) * step(0.14, f.y);
  return mix(DMG[3] * 0.93, DMG[q], dot);
}
"""


struct RedLedVisor(Style):
    """384 x 224 red LEDs on black, four intensities, each row a swept line."""

    comptime NAME: StaticString = "red_led_visor"
    comptime AFTER: StaticString = "the 1995 Virtual Boy display"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 224.0);
  let id = floor(px / cell);
  let cu = cell_uv(px, cell);
  let l = smoothstep(0.3, 1.0, luma(src_at(cu))) * (1.0 - 0.8 * is_far(cu, 60.0)) + 0.6 * edge(cu, 1.0);
  let q = clamp(floor(l * 4.0 + bayer4(id) - 0.5), 0.0, 3.0) / 3.0;
  let row = 0.65 + 0.35 * sin(fract(px.y / cell.y) * 3.14159);
  return vec3<f32>(q * row, q * q * 0.06, 0.0);
}
"""


struct Cga(Style):
    """320 x 200, palette 1 in high intensity: black, cyan, magenta, white, with ordered dither."""

    comptime NAME: StaticString = "cga"
    comptime AFTER: StaticString = "the 1981 IBM Color Graphics Adapter, mode 4 palette 1"
    comptime WGSL: StaticString = """
const CGA = array<vec3<f32>, 4>(vec3<f32>(0.0), vec3<f32>(0.33, 1.0, 1.0), vec3<f32>(1.0, 0.33, 1.0), vec3<f32>(1.0));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 200.0);
  let c = src_at(cell_uv(px, cell)) + (bayer4(floor(px / cell)) - 0.5) * 0.55;
  var best = 0u;
  var bd = 1e9;
  for (var i = 0u; i < 4u; i++) {
    let d = CGA[i] - c;
    let dd = dot(d, d);
    if dd < bd { bd = dd; best = i; }
  }
  return CGA[best];
}
"""


struct Spectrum(Style):
    """256 x 192 pixels in 8 x 8 attribute cells: each cell has one ink and one paper of the 15 colours, so colours
    clash at object borders."""

    comptime NAME: StaticString = "spectrum"
    comptime AFTER: StaticString = "the 1982 ZX Spectrum's attribute cells"
    comptime WGSL: StaticString = """
fn zx(c : vec3<f32>) -> vec3<f32> {
  let l = luma(c);
  let bits = step(vec3<f32>(0.5), clamp(mix(vec3<f32>(l), c, 3.0) * 0.9, vec3<f32>(0.0), vec3<f32>(1.0)));
  return bits * select(0.84, 1.0, l > 0.6);
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 192.0);
  let block = cell * 8.0;
  let b0 = floor(px / block) * block;
  var lo = vec3<f32>(1.0);
  var hi = vec3<f32>(0.0);
  var ll = 9.0;
  var lh = -1.0;
  for (var j = 0; j < 4; j++) { for (var i = 0; i < 4; i++) {
    let s = src_at((b0 + (vec2<f32>(f32(i), f32(j)) + 0.5) * block / 4.0) * frame.res.zw);
    let l = luma(s);
    if l < ll { ll = l; lo = s; }
    if l > lh { lh = l; hi = s; }
  } }
  let l = luma(src_at(cell_uv(px, cell)));
  let t = (l - ll) / max(lh - ll, 0.02);
  return select(zx(lo), zx(hi), t > bayer4(floor(px / cell)));
}
"""


struct C64(Style):
    """160 x 200 double-wide pixels in the 16 fixed colours."""

    comptime NAME: StaticString = "c64"
    comptime AFTER: StaticString = "the 1982 Commodore 64's multicolour bitmap mode"
    comptime WGSL: StaticString = """
const C64P = array<vec3<f32>, 16>(
  vec3<f32>(0.0, 0.0, 0.0), vec3<f32>(1.0, 1.0, 1.0), vec3<f32>(0.41, 0.22, 0.17), vec3<f32>(0.44, 0.64, 0.70),
  vec3<f32>(0.44, 0.24, 0.53), vec3<f32>(0.35, 0.55, 0.26), vec3<f32>(0.21, 0.16, 0.47), vec3<f32>(0.72, 0.78, 0.44),
  vec3<f32>(0.44, 0.31, 0.15), vec3<f32>(0.26, 0.22, 0.0), vec3<f32>(0.60, 0.40, 0.35), vec3<f32>(0.27, 0.27, 0.27),
  vec3<f32>(0.42, 0.42, 0.42), vec3<f32>(0.60, 0.82, 0.52), vec3<f32>(0.42, 0.37, 0.71), vec3<f32>(0.58, 0.58, 0.58));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let h = frame.res.y / 200.0;
  let cell = vec2<f32>(h * 2.0, h);
  let c = src_at(cell_uv(px, cell)) + (bayer4(floor(px / cell)) - 0.5) * 0.22;
  var best = 0u;
  var bd = 1e9;
  for (var i = 0u; i < 16u; i++) {
    let d = C64P[i] - c;
    let dd = dot(d * vec3<f32>(0.6, 1.0, 0.45), d);
    if dd < bd { bd = dd; best = i; }
  }
  return C64P[best];
}
"""


struct OneBit(Style):
    """Black or white only: tone by an 8 x 8 ordered dither, object borders as solid black lines."""

    comptime NAME: StaticString = "one_bit"
    comptime AFTER: StaticString = "the 1984 Macintosh's 1-bit screen and MacPaint's dither patterns"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(max(frame.res.y / 342.0, 1.0));
  let cu = cell_uv(px, cell);
  let l = pow(luma(src_at(cu)), 0.85);
  let on = step(bayer8(floor(px / cell)), l) * (1.0 - step(0.5, edge(cu, 1.0)));
  return vec3<f32>(on);
}
"""


struct AsciiTerminal(Style):
    """An 80-column character cell grid: each cell shows the glyph whose ink matches the cell's brightness, in green
    phosphor."""

    comptime NAME: StaticString = "ascii_terminal"
    comptime AFTER: StaticString = "ASCII art on a green-phosphor VT100 terminal"
    comptime WGSL: StaticString = """
const GLYPH = array<i32, 9>(0, 131072, 131200, 14336, 145536, 469440, 11512810, 15252014, 13199452);
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let w = frame.res.x / 80.0;
  let cell = vec2<f32>(w, w * 1.5);
  let cu = cell_uv(px, cell);
  let l = clamp(luma(src_at(cu)) * (1.0 - 0.5 * is_far(cu, 60.0)) + 0.6 * edge(cu, 2.0), 0.0, 1.0);
  let n = GLYPH[u32(clamp(l * 9.0, 0.0, 8.0))];
  let f = fract(px / cell) * vec2<f32>(1.2, 1.25) - vec2<f32>(0.1, 0.12);
  var ink = 0.0;
  if f.x >= 0.0 && f.x < 1.0 && f.y >= 0.0 && f.y < 1.0 {
    let q = vec2<i32>(floor(f * 5.0));
    ink = f32((n >> u32(q.x + 5 * q.y)) & 1);
  }
  let scan = 0.8 + 0.2 * sin(px.y * 3.14159);
  return vec3<f32>(0.10, 1.0, 0.35) * (ink * (0.45 + 0.55 * l) * scan) + vec3<f32>(0.0, 0.035, 0.012);
}
"""


struct CompositeBleed(Style):
    """Stage 1 of the CRT: a composite video signal. Brightness keeps its detail, colour is smeared along the line
    (YIQ: I and Q averaged over 12 pixels), and bright edges ring once to the right."""

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
    """Stage 2 of the CRT: the tube. A curved face, 240 scanlines, an aperture grille of red, green and blue stripes,
    dark corners."""

    comptime NAME: StaticString = "crt_tube"
    comptime AFTER: StaticString = "a 1980s consumer CRT television on a composite input"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = uv * 2.0 - 1.0;
  let w = d * (1.0 + 0.11 * dot(d.yx * d.yx, vec2<f32>(1.0, 0.6)) ) ;
  let u = w * 0.5 + 0.5;
  if u.x < 0.0 || u.x > 1.0 || u.y < 0.0 || u.y > 1.0 { return vec3<f32>(0.0); }
  var c = src_at(u);
  c = c * c;
  let line = 0.55 + 0.45 * cos(u.y * 240.0 * TAU);
  let k = u32(px.x) % 3u;
  let mask = vec3<f32>(f32(k == 0u), f32(k == 1u), f32(k == 2u)) * 1.5 + 0.35;
  c = c * line * mask * 1.5;
  let corner = smoothstep(0.0, 0.03, u.x) * smoothstep(0.0, 0.03, 1.0 - u.x) * smoothstep(0.0, 0.04, u.y) * smoothstep(0.0, 0.04, 1.0 - u.y);
  return sqrt(c) * corner * vignette(uv, 0.9);
}
"""


struct VectorLines(Style):
    """Stage 1 of the vector display: only the scene's silhouettes and creases, as thin lines on black."""

    comptime NAME: StaticString = "vector_lines"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return vec3<f32>(edge(uv, 1.0));
}
"""


struct PhosphorGlow(Style):
    """Stage 2 of the vector display: the beam's halo. Each line is drawn sharp and again spread over 24 pixels."""

    comptime NAME: StaticString = "vector_scope"
    comptime AFTER: StaticString = "vector displays: the 1982 Vectrex and oscilloscope X-Y mode"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var halo = 0.0;
  for (var i = 0; i < 24; i++) {
    let a = f32(i) * 2.39996;
    let r = sqrt(f32(i) + 0.5) * 2.4;
    halo += src_at(uv + vec2<f32>(cos(a), sin(a)) * r * frame.res.zw).r;
  }
  let v = src_at(uv).r + halo / 24.0 * 1.6;
  let flick = 0.92 + 0.08 * hash21(vec2<f32>(floor(px.y / 3.0), frame.t.y));
  return vec3<f32>(0.35, 1.0, 0.75) * v * flick + vec3<f32>(0.0, 0.015, 0.02);
}
"""


struct Console32(Style):
    """320 x 240, five bits per channel, the 4 x 4 dither that hides the banding."""

    comptime NAME: StaticString = "console_32bit"
    comptime AFTER: StaticString = "mid-1990s 32-bit consoles: 240-line output, 15-bit colour, ordered dither"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 240.0);
  let c = src_at(cell_uv(px, cell)) * 1.05;
  return clamp(floor(c * 31.0 + bayer4(floor(px / cell)) * 1.6 - 0.3) / 31.0, vec3<f32>(0.0), vec3<f32>(1.0));
}
"""


struct LedWall(Style):
    """72 rows of round emitters on a black board, each as bright as its patch of the frame."""

    comptime NAME: StaticString = "led_wall"
    comptime AFTER: StaticString = "stadium LED video boards"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 72.0);
  var c = src_at(cell_uv(px, cell));
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.5), vec3<f32>(0.0), vec3<f32>(1.0));
  let f = fract(px / cell) - 0.5;
  let r = length(f);
  let lamp = smoothstep(0.42, 0.30, r);
  let halo = 0.18 * smoothstep(0.75, 0.2, r);
  return c * (lamp * 1.6 + halo);
}
"""
