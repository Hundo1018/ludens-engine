"""Post styles after printing and drawing techniques (app/post.mojo Style)."""
from app.post import Style


struct NewsHalftone(Style):
    """One black ink on newsprint: a 45-degree screen of dots whose size carries the tone."""

    comptime NAME: StaticString = "news_halftone"
    comptime AFTER: StaticString = "newspaper halftone photographs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let r = vec2<f32>(px.x + px.y, px.y - px.x) * 0.7071 / 5.0;
  let centre = (floor(r) + 0.5) * 5.0;
  let cpx = vec2<f32>(centre.x - centre.y, centre.x + centre.y) * 0.7071;
  let l = smoothstep(0.1, 0.95, luma(src_at(cpx * frame.res.zw)));
  let d = length(fract(r) - 0.5);
  let ink = smoothstep(0.06, -0.06, d - 0.72 * sqrt(1.0 - l));
  let paper = vec3<f32>(0.90, 0.87, 0.78) * (0.95 + 0.07 * vnoise(px * 0.35));
  return mix(paper, vec3<f32>(0.09, 0.08, 0.08), ink);
}
"""


struct ComicCmyk(Style):
    """Four process inks, each a dot screen at its own angle, under a black key line."""

    comptime NAME: StaticString = "comic_cmyk"
    comptime AFTER: StaticString = "four-colour comic-book printing with Ben-Day dots, as Roy Lichtenstein enlarged it"
    comptime WGSL: StaticString = """
fn screen(px : vec2<f32>, ang : f32, amount : f32) -> f32 {
  let c = cos(ang);
  let s = sin(ang);
  let r = vec2<f32>(c * px.x + s * px.y, -s * px.x + c * px.y) / 6.0;
  return smoothstep(0.08, -0.08, length(fract(r) - 0.5) - 0.68 * sqrt(amount));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var c = src_at(uv);
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.6), vec3<f32>(0.0), vec3<f32>(1.0));
  c = floor(c * 4.0 + 0.5) / 4.0;
  let k = 1.0 - max(c.r, max(c.g, c.b));
  let cmy = (vec3<f32>(1.0) - c - k) / max(1.0 - k, 1e-3);
  var paper = vec3<f32>(0.97, 0.95, 0.88);
  paper *= mix(vec3<f32>(1.0), vec3<f32>(0.0, 0.68, 0.93), screen(px, 0.26, cmy.x));
  paper *= mix(vec3<f32>(1.0), vec3<f32>(0.93, 0.0, 0.55), screen(px, 1.31, cmy.y));
  paper *= mix(vec3<f32>(1.0), vec3<f32>(1.0, 0.92, 0.0), screen(px, 0.0, cmy.z));
  paper *= 1.0 - 0.85 * screen(px, 0.785, k * 0.8);
  return paper * (1.0 - step(0.4, edge(uv, 1.6)));
}
"""


struct Risograph(Style):
    """Two soy inks, pink and blue, printed one after the other a few pixels out of register, with a grainy laydown."""

    comptime NAME: StaticString = "risograph"
    comptime AFTER: StaticString = "two-colour Risograph prints"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let a = src_at(uv);
  let b = src_at(uv + vec2<f32>(5.0, -3.0) * frame.res.zw);
  let warm = clamp(1.0 - (a.g + a.b) * 0.55 + (a.r - a.g) * 0.8, 0.0, 1.0);
  let cool = clamp(1.0 - (b.r + b.g) * 0.55 + (b.b - b.r) * 0.8, 0.0, 1.0);
  let g1 = step(hash21(px + 3.0) * 0.9 + 0.05, warm);
  let g2 = step(hash21(px * 1.3 + 11.0) * 0.9 + 0.05, cool);
  var paper = vec3<f32>(0.95, 0.93, 0.87);
  paper *= mix(vec3<f32>(1.0), vec3<f32>(1.0, 0.28, 0.47), g1);
  paper *= mix(vec3<f32>(1.0), vec3<f32>(0.0, 0.42, 0.72), g2);
  return paper;
}
"""


struct Engraving(Style):
    """Parallel swelling lines: one set whose width follows the tone and bends with it, a crossing set in the darks."""

    comptime NAME: StaticString = "engraving"
    comptime AFTER: StaticString = "copperplate engraving: Albrecht Duerer's prints, banknote portraits"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = smoothstep(0.08, 0.95, luma(blur9(uv, 1.5)));
  let n = normal_at(uv);
  let t1 = (px.y + px.x * 0.25 + 26.0 * l + 9.0 * n.x) * 1.15;
  let t2 = (px.x - px.y * 0.6 + 14.0 * l) * 1.15;
  let w1 = 0.5 + 0.5 * sin(t1);
  let w2 = 0.5 + 0.5 * sin(t2);
  var ink = smoothstep(0.12, -0.12, w1 - (1.0 - l) * 1.05);
  ink = max(ink, smoothstep(0.12, -0.12, w2 - (0.55 - l) * 1.6));
  ink = max(ink, step(0.5, edge(uv, 1.0)));
  return mix(vec3<f32>(0.93, 0.90, 0.80), vec3<f32>(0.13, 0.10, 0.08), ink);
}
"""


struct CrossHatch(Style):
    """Pen strokes in up to four directions, one more direction for each step darker, and a contour line."""

    comptime NAME: StaticString = "cross_hatch"
    comptime AFTER: StaticString = "pen-and-ink cross-hatching: Gustave Dore's illustrations"
    comptime WGSL: StaticString = """
fn hatch(px : vec2<f32>, ang : f32, gap : f32) -> f32 {
  let d = px.x * cos(ang) + px.y * sin(ang) + 2.5 * vnoise(px * 0.05 + ang);
  let run = vnoise(vec2<f32>(floor(d / gap) * 7.0 + ang, (px.x * sin(ang) - px.y * cos(ang)) * 0.03));
  return smoothstep(0.32, 0.12, abs(fract(d / gap) - 0.5)) * step(0.22, run);
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = luma(blur9(uv, 1.0));
  var ink = step(0.45, edge(uv, 1.2));
  ink = max(ink, hatch(px, 0.6, 6.0) * step(l, 0.78) * (1.0 - is_far(uv, 60.0)));
  ink = max(ink, hatch(px, 2.2, 6.0) * step(l, 0.60));
  ink = max(ink, hatch(px, 1.4, 5.0) * step(l, 0.44));
  ink = max(ink, hatch(px, 0.0, 4.0) * step(l, 0.30));
  let paper = vec3<f32>(0.96, 0.95, 0.91) * (0.97 + 0.05 * vnoise(px * 0.2));
  return mix(paper, vec3<f32>(0.10, 0.10, 0.16), ink);
}
"""


struct Woodcut(Style):
    """Black and paper only. The darks are solid; the lights are cut along the tone's contour lines, as a gouge
    follows a form."""

    comptime NAME: StaticString = "woodcut"
    comptime AFTER: StaticString = "German Expressionist woodcuts (Die Bruecke)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = smoothstep(0.15, 0.95, luma(blur9(uv, 2.5)));
  let grain = fbm(vec2<f32>(px.x * 0.02, px.y * 0.25));
  let cut = 0.5 + 0.5 * sin(l * 46.0 + grain * 5.0 + px.y * 0.06);
  var ink = step(l, 0.34);
  ink = max(ink, step(cut, (0.95 - l) * 0.9));
  ink = max(ink, step(0.4, edge(uv, 2.0)));
  ink *= step(0.12, vnoise(px * 0.9) + 0.25 * grain);
  return mix(vec3<f32>(0.91, 0.86, 0.74), vec3<f32>(0.07, 0.06, 0.05), ink);
}
"""


struct Blueprint(Style):
    """White construction lines on Prussian blue, a drafting grid behind, the shaded faces hatched."""

    comptime NAME: StaticString = "blueprint"
    comptime AFTER: StaticString = "cyanotype architectural blueprints"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = luma(src_at(uv));
  var w = edge(uv, 1.0);
  let g1 = step(fract(px.x / 40.0), 1.0 / 40.0) + step(fract(px.y / 40.0), 1.0 / 40.0);
  let g2 = step(fract(px.x / 8.0), 1.0 / 8.0) + step(fract(px.y / 8.0), 1.0 / 8.0);
  w = max(w, 0.22 * min(g1, 1.0) + 0.07 * min(g2, 1.0));
  let far = is_far(uv, 60.0);
  let hatching = step(fract((px.x + px.y) / 6.0), 0.2) * step(l, 0.5) * (1.0 - far);
  w = max(w, 0.45 * hatching);
  let blue = vec3<f32>(0.05, 0.20, 0.52) * (0.85 + 0.3 * fbm(px * 0.01));
  return mix(blue, vec3<f32>(0.90, 0.95, 1.0), clamp(w, 0.0, 1.0));
}
"""


struct UkiyoE(Style):
    """Flat blocks of a few pigments, a black key block, the sky printed as a graded band from the top (bokashi), the
    paper's fibre under all of it."""

    comptime NAME: StaticString = "ukiyo_e"
    comptime AFTER: StaticString = "Edo woodblock prints: Hokusai, Hiroshige"
    comptime WGSL: StaticString = """
const UKI = array<vec3<f32>, 7>(
  vec3<f32>(0.10, 0.20, 0.42), vec3<f32>(0.30, 0.47, 0.60), vec3<f32>(0.86, 0.80, 0.63), vec3<f32>(0.76, 0.30, 0.20),
  vec3<f32>(0.45, 0.55, 0.42), vec3<f32>(0.72, 0.62, 0.40), vec3<f32>(0.20, 0.19, 0.20));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var c = blur9(uv, 1.5);
  let g = luma(c);
  c = mix(vec3<f32>(g), c, 1.4) * (floor(g * 4.0 + 0.5) / 4.0) / max(g, 0.05);
  var best = 0u;
  var bd = 1e9;
  for (var i = 0u; i < 7u; i++) {
    let d = UKI[i] - c;
    let dd = dot(d, d);
    if dd < bd { bd = dd; best = i; }
  }
  var o = UKI[best];
  if is_far(uv, 60.0) > 0.5 {
    o = mix(vec3<f32>(0.10, 0.20, 0.42), vec3<f32>(0.90, 0.85, 0.70), smoothstep(0.0, 0.22, uv.y));
  }
  o = mix(o, vec3<f32>(0.08, 0.07, 0.08), step(0.4, edge(uv, 1.3)));
  let fibre = 0.93 + 0.1 * vnoise(vec2<f32>(px.x * 0.9, px.y * 0.08)) + 0.04 * vnoise(px * 0.6);
  return o * fibre;
}
"""


struct Constructivist(Style):
    """Three inks: black, red and the paper. A diagonal divides the sheet and the red changes sides across it."""

    comptime NAME: StaticString = "constructivist"
    comptime AFTER: StaticString = "1920s Soviet Constructivist posters: Rodchenko, El Lissitzky"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = smoothstep(0.2, 0.95, luma(src_at(uv)));
  let side = step(0.0, uv.x * 0.9 + uv.y * 1.6 - 1.25);
  let bars = step(fract((px.x * 0.6 - px.y) / 9.0), 0.45);
  let red = vec3<f32>(0.80, 0.12, 0.09);
  let cream = vec3<f32>(0.92, 0.87, 0.74);
  let black = vec3<f32>(0.09, 0.08, 0.08);
  var o = mix(cream, red, side);
  if l < 0.62 { o = mix(mix(red, cream, side), o, bars * step(0.5, l)); }
  if l < 0.32 { o = black; }
  if is_far(uv, 60.0) > 0.5 { o = mix(cream, red, side); }
  o = mix(o, black, step(abs(uv.x * 0.9 + uv.y * 1.6 - 1.25), 0.012));
  return o * (0.94 + 0.08 * vnoise(px * 0.5));
}
"""


struct PopArt(Style):
    """The frame four times, each a three-level silkscreen in its own trio of inks."""

    comptime NAME: StaticString = "pop_art"
    comptime AFTER: StaticString = "Andy Warhol's repeated silkscreen panels"
    comptime WGSL: StaticString = """
const POP = array<vec3<f32>, 12>(
  vec3<f32>(0.10, 0.10, 0.45), vec3<f32>(0.95, 0.20, 0.55), vec3<f32>(1.0, 0.92, 0.25),
  vec3<f32>(0.35, 0.05, 0.30), vec3<f32>(0.10, 0.75, 0.80), vec3<f32>(1.0, 0.60, 0.15),
  vec3<f32>(0.05, 0.30, 0.20), vec3<f32>(0.95, 0.85, 0.10), vec3<f32>(1.0, 0.45, 0.60),
  vec3<f32>(0.45, 0.10, 0.05), vec3<f32>(0.25, 0.85, 0.40), vec3<f32>(0.80, 0.90, 1.0));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let p = floor(uv * 2.0);
  let u = fract(uv * 2.0);
  let k = u32(p.x + 2.0 * p.y) * 3u;
  let l = smoothstep(0.2, 0.9, luma(src_at(u)));
  var o = POP[k + 1u];
  if l < 0.38 { o = POP[k]; }
  if l > 0.72 { o = POP[k + 2u]; }
  let frame_line = step(u.x, 0.008) + step(u.y, 0.012) + step(0.992, u.x) + step(0.988, u.y);
  return mix(o, vec3<f32>(0.05), clamp(step(0.5, edge(u, 2.0)) + frame_line, 0.0, 1.0));
}
"""


struct LigneClaire(Style):
    """One even black line around every form, flat local colour inside it, no shading and no hatching."""

    comptime NAME: StaticString = "ligne_claire"
    comptime AFTER: StaticString = "the ligne claire of Herge's Tintin albums"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var hsv = rgb2hsv(src_at(uv));
  hsv.x = floor(hsv.x * 18.0 + 0.5) / 18.0;
  hsv.y = min(floor(hsv.y * 3.0 + 0.7) / 3.0 * 0.85, 0.8);
  hsv.z = mix(0.9, 0.72, step(hsv.z, 0.33));
  var o = hsv2rgb(hsv);
  if is_far(uv, 60.0) > 0.5 { o = vec3<f32>(0.70, 0.85, 0.95); }
  return mix(o, vec3<f32>(0.06), step(0.35, edge(uv, 1.1)));
}
"""


struct TopoMap(Style):
    """The scene as a survey sheet: height above the floor as brown contour lines (every 0.25 m, heavier every
    metre) over a height tint, with a blue 2-metre grid."""

    comptime NAME: StaticString = "topo_map"
    comptime AFTER: StaticString = "USGS topographic quadrangle maps"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let paper = vec3<f32>(0.96, 0.94, 0.86);
  if is_far(uv, 60.0) > 0.5 { return paper * (0.97 + 0.04 * vnoise(px * 0.3)); }
  let w = world_at(uv);
  let wx = world_at(uv + vec2<f32>(frame.res.z, 0.0));
  let wy = world_at(uv + vec2<f32>(0.0, frame.res.w));
  let dh = max(abs(wx.y - w.y), abs(wy.y - w.y)) + 1e-4;
  let h = w.y + 0.02;
  var o = mix(vec3<f32>(0.78, 0.88, 0.70), vec3<f32>(0.93, 0.86, 0.66), smoothstep(0.0, 1.5, h));
  o = mix(o, vec3<f32>(0.99, 0.98, 0.95), smoothstep(1.5, 3.5, h));
  o *= 0.82 + 0.18 * luma(src_at(uv));
  let minor = 1.0 - smoothstep(0.0, 1.2, abs(fract(h / 0.25 + 0.5) - 0.5) * 0.25 / dh);
  let major = 1.0 - smoothstep(0.0, 2.4, abs(fract(h + 0.5) - 0.5) / dh);
  o = mix(o, vec3<f32>(0.62, 0.38, 0.20), clamp(0.7 * minor + major, 0.0, 1.0) * step(dh, 0.2));
  let dg = max(length(wx.xz - w.xz), length(wy.xz - w.xz)) + 1e-4;
  let gx = abs(fract(w.x / 2.0 + 0.5) - 0.5) * 2.0 / dg;
  let gz = abs(fract(w.z / 2.0 + 0.5) - 0.5) * 2.0 / dg;
  o = mix(o, vec3<f32>(0.20, 0.45, 0.75), 0.6 * (1.0 - smoothstep(0.0, 1.0, min(gx, gz))));
  return o;
}
"""
