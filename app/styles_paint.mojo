"""Pipelines after painting and craft techniques. A mark is a thing here: a brush stroke, a tessera or a dot is one
quad placed and coloured once (app/strokes.mojo); a wash, a glaze or a brush line is drawn on the surface by a
material; a second, smaller target carries what bleeds, glows or casts a shadow."""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.post import Style, Stage, ThenPost, Join, Scaled, Sized, SceneSize, Copy
from app.render_pass import Then
from app.shadow_pass import ShadowPass
from app.mesh_pass import MeshPassOf
from app.material import Material
from app.wire_pass import WireKind, WirePassOf
from app.strokes import StrokeKind, Strokes
from app.gbuffer import HullPass, AlbedoPasses, NormalPasses, MatNothing
from app.styles_material import MatFlat, MatCel, MatSkyPale, MatSkyPaper, MatSkyDark
from app.styles_util import Kuwahara, Blur13


# ---------------------------------------------------------------- 24. pointillism
struct SeuratDots(StrokeKind):
    comptime NAME: StaticString = "pointillism"
    comptime WHAT: StaticString = "dots of unmixed colour, two layers"
    comptime AFTER: StaticString = "Georges Seurat's Pointillism"
    comptime CELL: Int = 5
    comptime LAYERS: Int = 2
    comptime CANVAS_R: Float64 = 0.93
    comptime CANVAS_G: Float64 = 0.90
    comptime CANVAS_B: Float64 = 0.82
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let h = hash22(cell + f32(layer) * 17.0);
  let centre = (cell + h) * STROKE_CELL - f32(layer) * 2.5;
  var hsv = rgb2hsv(src_at(centre * frame.res.zw));
  let r = hash21(cell * 3.1 + f32(layer) * 5.0);
  hsv.x = fract(hsv.x + (r - 0.5) * 0.12 + select(0.0, 0.5, r > 0.86 && hsv.z < 0.55));
  hsv.y = clamp(hsv.y * 1.8 + 0.15, 0.0, 1.0);
  hsv.z = clamp(hsv.z * 1.1 + (r - 0.5) * 0.2, 0.0, 1.0);
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(2.6 + 1.2 * r);
  s.angle = 0.0;
  s.color = vec4<f32>(hsv2rgb(hsv), 1.0);
  s.seed = r;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  return vec4<f32>(color.rgb, smoothstep(1.0, 0.75, length(q)));
}
"""

# Not a filter: each touch is one quad with one colour, taken from the scene at its centre and pushed to a pure hue;
# a later touch lies whole on top of an earlier one, and the ground shows between them.
comptime Pointillism = Strokes[SeuratDots]


# ---------------------------------------------------------------- 25. impasto
struct ImpastoDabs(StrokeKind):
    comptime NAME: StaticString = "impasto_dabs"
    comptime WHAT: StaticString = "short loaded strokes along the forms"
    comptime AFTER: StaticString = ""
    comptime CELL: Int = 6
    comptime LAYERS: Int = 2
    comptime CANVAS_R: Float64 = 0.60
    comptime CANVAS_G: Float64 = 0.55
    comptime CANVAS_B: Float64 = 0.45
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let h = hash22(cell + f32(layer) * 9.0);
  let centre = (cell + h) * STROKE_CELL;
  let u = centre * frame.res.zw;
  let g = sobel(u, 3.0);
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(9.0 + 5.0 * h.x, 3.2 + 1.2 * h.y) * (1.0 - 0.3 * f32(layer));
  s.angle = atan2(g.x, -g.y) * step(0.02, g.z) + (h.y - 0.5) * 0.6 + 0.5 * (1.0 - step(0.02, g.z));
  var c = src_at(u);
  let l = luma(c);
  c = clamp(mix(vec3<f32>(l), c, 1.4) + (h.x - 0.5) * 0.08, vec3<f32>(0.0), vec3<f32>(1.0));
  s.color = vec4<f32>(c, 1.0);
  s.seed = h.x * 37.0;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  let bristle = 0.75 + 0.25 * sin(q.y * 9.0 + seed);
  let body = smoothstep(1.0, 0.7, abs(q.y)) * smoothstep(1.0, 0.8 - 0.2 * vnoise(vec2<f32>(q.y * 3.0, seed)), abs(q.x));
  return vec4<f32>(color.rgb * (0.9 + 0.2 * bristle), body);
}
"""


struct ImpastoRelief(Style):
    comptime NAME: StaticString = "impasto"
    comptime AFTER: StaticString = "Impressionist oil impasto: Claude Monet"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let e = frame.res.zw * 1.2;
  let gx = luma(src_at(uv + vec2<f32>(e.x, 0.0))) - luma(src_at(uv - vec2<f32>(e.x, 0.0)));
  let gy = luma(src_at(uv + vec2<f32>(0.0, e.y))) - luma(src_at(uv - vec2<f32>(0.0, e.y)));
  let weave = 0.96 + 0.04 * sin(px.x * 2.1) * sin(px.y * 2.1);
  return src_at(uv) * clamp(1.0 + (-gx - gy) * 2.2, 0.6, 1.5) * weave;
}
"""

# Not a filter: the picture is first simplified (Kuwahara), then repainted as two layers of stroke quads, each turned
# along the edge it lies on and loaded with one colour; the last stage lights the ridges the strokes left.
comptime Impasto = ThenPost[Stage[Kuwahara], ThenPost[Strokes[ImpastoDabs], Stage[ImpastoRelief]]]


# ---------------------------------------------------------------- 26. swirling strokes
struct SwirlDabs(StrokeKind):
    comptime NAME: StaticString = "swirl_dabs"
    comptime WHAT: StaticString = "long strokes along a turbulent flow"
    comptime AFTER: StaticString = ""
    comptime CELL: Int = 7
    comptime LAYERS: Int = 2
    comptime CANVAS_R: Float64 = 0.10
    comptime CANVAS_G: Float64 = 0.13
    comptime CANVAS_B: Float64 = 0.30
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let h = hash22(cell + f32(layer) * 23.0);
  let centre = (cell + h) * STROKE_CELL;
  let p = centre * 0.012;
  let a = fbm(p + vec2<f32>(0.0, 0.03)) - fbm(p - vec2<f32>(0.0, 0.03));
  let b = fbm(p + vec2<f32>(0.03, 0.0)) - fbm(p - vec2<f32>(0.03, 0.0));
  let g = sobel(centre * frame.res.zw, 3.0);
  let v = vec2<f32>(a, -b) * 30.0 + vec2<f32>(-g.y, g.x) * 2.5;
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(13.0 + 6.0 * h.x, 2.4 + 0.8 * h.y);
  s.angle = atan2(v.y, v.x);
  var c = src_at(centre * frame.res.zw);
  let l = luma(c);
  c = clamp(mix(vec3<f32>(l), c, 1.8) * (0.8 + 0.4 * h.y), vec3<f32>(0.0), vec3<f32>(1.0));
  s.color = vec4<f32>(c, 1.0);
  s.seed = h.y * 11.0;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  let taper = smoothstep(1.0, 0.5, abs(q.x));
  let body = smoothstep(1.0, 0.55, abs(q.y) / max(taper, 0.05));
  return vec4<f32>(mix(color.rgb * 0.7 + vec3<f32>(0.0, 0.02, 0.08), color.rgb * 1.1, smoothstep(-0.2, 0.6, q.y)), body);
}
"""


struct DarkContour(Style):
    comptime NAME: StaticString = "swirl_strokes"
    comptime AFTER: StaticString = "Vincent van Gogh's late brushwork (The Starry Night)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return mix(src_at(uv), vec3<f32>(0.06, 0.09, 0.25), 0.75 * step(0.5, edge(uv, 1.6)));
}
"""

# Not a filter: long tapered quads, each turned once to a flow field (a curl noise bent along the picture's edges),
# lit along their width like a ridge of paint; over a dark blue ground that shows between them.
comptime SwirlStrokes = ThenPost[Strokes[SwirlDabs], Stage[DarkContour]]


# ---------------------------------------------------------------- 27. watercolour
struct WatercolourPaper(Style):
    comptime NAME: StaticString = "watercolour"
    comptime AFTER: StaticString = "English watercolour: J. M. W. Turner's washes"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let wob = (vec2<f32>(fbm(px * 0.03), fbm(px * 0.03 + 40.0)) - 0.5) * 9.0 * frame.res.zw;
  let wet = smoothstep(0.5, 0.75, fbm(px * 0.012 + 5.0)) * 0.8;
  let sharp = src_at(uv + wob);
  let bled = src2_at(uv + wob);
  var c = mix(sharp, bled, wet);
  let g = luma(c);
  c = mix(vec3<f32>(g), c, 1.25);
  let pool = clamp(length(sharp - bled) * 3.0, 0.0, 1.0) * (1.0 - wet);
  let grain = fbm(px * 0.45);
  let paper = vec3<f32>(0.97, 0.95, 0.90);
  var o = mix(paper, c, clamp(0.66 + 0.35 * (grain - 0.5) + 0.25 * (fbm(px * 0.015) - 0.5), 0.0, 1.0));
  o *= 1.0 - 0.45 * pool;
  return o * (0.96 + 0.06 * vnoise(px * 0.8));
}
"""

# Not a filter over one picture: two pictures of the washes exist, a crisp one and one spread in a quarter-size
# target. Where the paper is wet the spread one shows (wet in wet); where it is dry the crisp one shows and pigment
# pools along the border, which is exactly where the two differ.
comptime Watercolour = Join[Stage[Kuwahara], Scaled[Stage[Blur13], 4], Stage[WatercolourPaper]]


# ---------------------------------------------------------------- 28. ink wash
struct MatInkWash(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "three dilutions of ink"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let tone = (0.25 + 0.75 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf) * (0.5 + 0.5 * dot(s.base, vec3<f32>(0.333)));
  let w = floor(clamp(1.0 - tone, 0.0, 0.999) * 3.0 + 0.4 * sin(dot(s.wpos, vec3<f32>(3.1, 1.7, 2.3)))) / 3.0;
  return vec4<f32>(mix(vec3<f32>(0.94, 0.92, 0.85), vec3<f32>(0.10, 0.10, 0.11), clamp(w, 0.0, 1.0) * 0.6), 1.0);"""


struct MatBrushHull(Material):
    """A hull whose width changes along the form (pressure) and that breaks where the brush runs dry."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "brush hull, varying width"
    comptime VERT_WORLD: StaticString = "world = world + normalize(world - m[3].xyz) * (0.004 + 0.012 * (0.5 + 0.5 * sin(dot(world, vec3<f32>(1.3, 2.1, 1.7))))) * length(world - cam.eye.xyz);"
    comptime BODY: StaticString = """
  if dot(s.wnrm, cam.eye.xyz - s.wpos) > 0.0 { discard; }
  if sin(dot(s.wpos, vec3<f32>(7.0, 5.0, 9.0))) * sin(dot(s.wpos, vec3<f32>(31.0, 17.0, 23.0))) > 0.55 { discard; }
  return vec4<f32>(0.07, 0.07, 0.08, 1.0);"""


struct RicePaperSeal(Style):
    comptime NAME: StaticString = "sumi_e"
    comptime AFTER: StaticString = "East Asian ink-wash painting (sumi-e, shuimo)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let wob = (vec2<f32>(fbm(px * 0.04), fbm(px * 0.04 + 9.0)) - 0.5) * 5.0 * frame.res.zw;
  var o = mix(src_at(uv + wob), blur9(uv + wob, 1.5), 0.5);
  o *= 0.95 + 0.07 * vnoise(vec2<f32>(px.x * 0.05, px.y * 0.7));
  let s = (uv - vec2<f32>(0.925, 0.84)) * frame.res.xy / frame.res.y;
  if abs(s.x) < 0.035 && abs(s.y) < 0.035 {
    let inner = step(abs(s.x), 0.027) * step(abs(s.y), 0.027) * step(0.5, vnoise(s * 160.0 + 4.0));
    o = mix(vec3<f32>(0.78, 0.13, 0.10), vec3<f32>(0.94, 0.92, 0.85), inner * 0.9);
  }
  return o;
}
"""

# Not a filter: the wash is three dilutions chosen on the surface from the real light, and the line is a hull whose
# width is set per vertex (the pressure of the brush) and which is cut away where the brush is dry. The stage lets the
# ink spread into the paper and adds the seal.
comptime SumiEPasses = Then[ShadowPass, Then[MeshPassOf[MatInkWash, MatSkyPaper], MeshPassOf[MatBrushHull, MatNothing]]]
comptime SumiE = Stage[RicePaperSeal]


# ---------------------------------------------------------------- 29. De Stijl
comptime STIJL_WGSL = """
fn cut(i : f32, n : f32, seed : f32) -> f32 { return (i + 0.6 * (hash21(vec2<f32>(i, seed)) - 0.5) * step(0.5, i) * step(i, n - 0.5)) / n; }
"""


struct CellColour(Style):
    """A 13 x 8 table: per rectangle of the composition, the strongest of the unlit colours inside it."""

    comptime NAME: StaticString = "composition table"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = STIJL_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let id = floor(px);
  let lo = vec2<f32>(cut(id.x, 13.0, 1.0), cut(id.y, 8.0, 2.0));
  let hi = vec2<f32>(cut(id.x + 1.0, 13.0, 1.0), cut(id.y + 1.0, 8.0, 2.0));
  var best = vec3<f32>(0.0, -1.0, 0.0);
  for (var j = 0; j < 4; j++) { for (var i = 0; i < 4; i++) {
    let a = aux_at(mix(lo, hi, (vec2<f32>(f32(i), f32(j)) + 0.5) / 4.0));
    let h = rgb2hsv(a.rgb);
    if a.a > 0.5 && h.y > best.y { best = h; }
  } }
  var o = vec3<f32>(0.95, 0.94, 0.90);
  if best.y > 0.42 {
    o = vec3<f32>(0.85, 0.12, 0.10);
    if best.x > 0.10 && best.x < 0.24 { o = vec3<f32>(0.97, 0.82, 0.10); }
    if best.x >= 0.24 && best.x < 0.80 { o = vec3<f32>(0.08, 0.20, 0.60); }
  }
  if best.y >= 0.0 && best.z < 0.3 { o = vec3<f32>(0.07); }
  return o;
}
"""


struct MondrianBars(Style):
    comptime NAME: StaticString = "de_stijl"
    comptime AFTER: StaticString = "Piet Mondrian's De Stijl compositions"
    comptime WGSL: StaticString = STIJL_WGSL + """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var id = vec2<f32>(0.0);
  var lo = vec2<f32>(0.0);
  var hi = vec2<f32>(1.0);
  for (var i = 0; i < 13; i++) {
    let a = cut(f32(i), 13.0, 1.0);
    let b = cut(f32(i) + 1.0, 13.0, 1.0);
    if uv.x >= a && uv.x < b { lo.x = a; hi.x = b; id.x = f32(i); }
  }
  for (var j = 0; j < 8; j++) {
    let a = cut(f32(j), 8.0, 2.0);
    let b = cut(f32(j) + 1.0, 8.0, 2.0);
    if uv.y >= a && uv.y < b { lo.y = a; hi.y = b; id.y = f32(j); }
  }
  let o = src_texel((id + 0.5) / vec2<f32>(13.0, 8.0));
  let d = min(min(uv.x - lo.x, hi.x - uv.x) * frame.res.x, min(uv.y - lo.y, hi.y - uv.y) * frame.res.y);
  return mix(vec3<f32>(0.06), o, step(2.5, d));
}
"""

# Not a filter: the whole picture is a 13 x 8 texture, one texel per rectangle, and the choice in each texel is made
# from the objects' own colours (an aux target), not from the lit frame: a red ball in shadow is still a red rectangle.
comptime DeStijl = ThenPost[Sized[Stage[CellColour], 13, 8], Stage[MondrianBars]]
comptime DeStijlAux = AlbedoPasses


# ---------------------------------------------------------------- 30. stained glass
struct GlassPanes(Style):
    comptime NAME: StaticString = "glass panes in lead"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let p = px / 22.0;
  let id = floor(p);
  var d1 = 9.0;
  var d2 = 9.0;
  var site = vec2<f32>(0.0);
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) {
    let c = id + vec2<f32>(f32(i), f32(j));
    let s = c + hash22(c);
    let d = length(p - s);
    if d < d1 { d2 = d1; d1 = d; site = s; } else if d < d2 { d2 = d; }
  } }
  let su = site * 22.0 * frame.res.zw;
  let a = aux_at(su);
  // the glass is the object's own colour; how bright it is is how much light the scene has behind it
  var hsv = rgb2hsv(mix(src_at(su), a.rgb, a.a));
  hsv.y = clamp(hsv.y * 1.7 + 0.25, 0.0, 1.0);
  hsv.z = clamp(0.25 + 1.1 * luma(src_at(su)), 0.0, 1.0);
  let o = hsv2rgb(hsv) * (0.75 + 0.5 * vnoise(px * 0.12 + site * 7.0));
  return mix(o, vec3<f32>(0.0), smoothstep(0.10, 0.04, d2 - d1));
}
"""


struct LightThrough(Style):
    comptime NAME: StaticString = "stained_glass"
    comptime AFTER: StaticString = "Gothic cathedral stained glass"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  return c + src2_at(uv) * 0.75 * (0.35 + 0.65 * step(0.02, luma(c)));
}
"""

# Not a filter: a pane's colour is the object's unlit colour (aux) and its brightness the light in the scene behind
# it, two different sources; and the light that spills past the leads is the panes blurred in a quarter-size target.
comptime StainedGlass = ThenPost[Stage[GlassPanes], Join[Stage[Copy], Scaled[Stage[Blur13], 4], Stage[LightThrough]]]
comptime StainedGlassAux = AlbedoPasses


# ---------------------------------------------------------------- 31. mosaic
struct Tesserae(StrokeKind):
    comptime NAME: StaticString = "mosaic"
    comptime WHAT: StaticString = "tesserae, each cut and set"
    comptime AFTER: StaticString = "Byzantine wall mosaics (Ravenna)"
    comptime CELL: Int = 9
    comptime CANVAS_R: Float64 = 0.74
    comptime CANVAS_G: Float64 = 0.71
    comptime CANVAS_B: Float64 = 0.64
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let h = hash22(cell);
  let centre = (cell + 0.5 + (h - 0.5) * 0.18) * STROKE_CELL + vec2<f32>(4.0 * sin(cell.y * 1.7), 0.0);
  let u = centre * frame.res.zw;
  let g = sobel(u, 4.0);
  var c = src_at(u);
  let l = luma(c);
  c = clamp(mix(vec3<f32>(l), c, 1.35), vec3<f32>(0.0), vec3<f32>(1.0)) * (0.82 + 0.3 * h.x);
  if is_far(u, 60.0) > 0.5 { c = vec3<f32>(0.85, 0.64, 0.18) * (0.7 + 0.5 * h.x) + 0.25 * step(0.9, h.x); }
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(3.5 + 0.7 * h.y, 3.5 + 0.7 * h.x);
  // a tessera next to an edge is set along it (the andamento); elsewhere it sits square, a little off
  s.angle = atan2(g.x, -g.y) * step(0.08, g.z) + (h.x - 0.5) * 0.25;
  s.color = vec4<f32>(c, 1.0);
  s.seed = h.y;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  let chip = step(q.x + q.y, 1.75 - 0.5 * seed);
  return vec4<f32>(color.rgb * (1.0 + 0.22 * (q.y - q.x) * 0.5), chip);
}
"""

# Not a filter: every stone is its own quad: cut to its own size, turned to follow the edge it lies beside, one
# colour, a chipped corner; the grout is the canvas showing between them.
comptime Mosaic = Strokes[Tesserae]


# ---------------------------------------------------------------- 32. cross-stitch
struct StitchX(Style):
    comptime NAME: StaticString = "cross_stitch"
    comptime AFTER: StaticString = "counted cross-stitch samplers"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let n = vec2<f32>(80.0, 45.0);
  var c = src_texel(uv);
  let cg = luma(c);
  c = floor(clamp(mix(vec3<f32>(cg), c, 1.5), vec3<f32>(0.0), vec3<f32>(1.0)) * 5.0 + 0.5) / 5.0;
  let f = fract(uv * n);
  let a = abs(f.x - f.y);
  let b = abs(f.x + f.y - 1.0);
  let over = smoothstep(0.36, 0.24, a);
  let under = smoothstep(0.36, 0.24, b) * (1.0 - over);
  let hole = smoothstep(0.16, 0.08, length(fract(uv * n + 0.5) - 0.5));
  var cloth = vec3<f32>(0.90, 0.87, 0.78) * (0.92 + 0.08 * sin(px.x * 1.5708) * sin(px.y * 1.5708));
  cloth = mix(cloth, vec3<f32>(0.55, 0.52, 0.45), hole);
  if is_far(uv, 60.0) > 0.5 { return cloth; }
  var o = mix(cloth, c * 0.8 * (0.85 + 0.15 * sin((f.x - f.y) * 40.0)), under);
  return mix(o, c * (1.1 - 0.4 * a) * (0.85 + 0.15 * sin((f.x + f.y) * 40.0)), over);
}
"""

# Not a filter: the pattern is counted. The scene is rasterised at 80 x 45, one sample per square of the cloth, and
# each square gets one stitch of one floss colour.
comptime CrossStitch = SceneSize[Stage[StitchX], 80, 45]


# ---------------------------------------------------------------- 33. pencil sketch
struct SketchOutline(Style):
    comptime NAME: StaticString = "outline, drawn twice"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let j = (vec2<f32>(vnoise(px * 0.04), vnoise(px * 0.04 + 7.0)) - 0.5) * 5.0 * frame.res.zw;
  return vec3<f32>(1.0 - clamp(0.75 * gedge(uv + j, 1.0) + 0.45 * gedge(uv - j * 1.7, 1.0), 0.0, 1.0));
}
"""


struct GraphiteStrokes(StrokeKind):
    comptime NAME: StaticString = "graphite_strokes"
    comptime WHAT: StaticString = "graphite strokes across the form"
    comptime AFTER: StaticString = ""
    comptime CELL: Int = 5
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let h = hash22(cell);
  let centre = (cell + h) * STROKE_CELL;
  let u = centre * frame.res.zw;
  let n = gnormal(u);
  let tone = smoothstep(0.85, 0.2, luma(src_at(u))) * aux_at(u).a;
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(7.0 + 6.0 * h.x, 0.7) * step(h.y, tone * 1.1);
  // strokes lie across the direction the surface turns in: flat ground one way, a wall another, round a ball
  s.angle = 0.75 + 1.2 * n.x - 0.8 * n.z + (h.y - 0.5) * 0.3;
  s.color = vec4<f32>(0.25, 0.25, 0.27, 0.35 + 0.4 * tone);
  s.seed = h.x;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  return vec4<f32>(color.rgb, color.a * smoothstep(1.0, 0.6, abs(q.x)) * (0.7 + 0.3 * sin(q.x * 20.0 + seed * 50.0)));
}
"""


struct DrawingPaper(Style):
    comptime NAME: StaticString = "pencil_sketch"
    comptime AFTER: StaticString = "graphite pencil drawing"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let tooth = 0.85 + 0.3 * hash21(floor(px));
  let graphite = clamp(((1.0 - src_at(uv).r) + (1.0 - src2_at(uv).r)) * tooth, 0.0, 1.0);
  return mix(vec3<f32>(0.95, 0.94, 0.91), vec3<f32>(0.22, 0.22, 0.24), graphite);
}
"""

# Not a filter: the shading is separate pencil strokes (quads), each turned by the surface normal under it, which
# comes from an aux target of the meshes' own normals; the outline is found in those normals too, so a sphere has a
# rim and no facet lines. The two drawings are made side by side and laid on the paper together.
comptime PencilSketch = Join[Stage[SketchOutline], Strokes[GraphiteStrokes], Stage[DrawingPaper]]
comptime PencilSketchAux = NormalPasses


# ---------------------------------------------------------------- 34. chalkboard
struct MatBoard(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "board, faint rubbed light"
    comptime BODY: StaticString = """
  let lit = max(dot(normalize(s.wnrm), normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf;
  return vec4<f32>(vec3<f32>(0.10, 0.20, 0.16) + 0.10 * lit * (0.5 + s.base), 1.0);"""


struct MatBoardSky(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "board sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.10, 0.20, 0.16, 1.0);"""


struct ChalkLine(WireKind):
    comptime NAME: StaticString = "chalk edges, broken"
    comptime FRAG: StaticString = """
  if fract(sin(floor(in.t * 55.0) * 12.9898) * 43758.5453) < 0.22 { discard; }
  return vec4<f32>(0.93, 0.93, 0.88, 1.0);"""


struct ChalkDust(Style):
    comptime NAME: StaticString = "chalkboard"
    comptime AFTER: StaticString = "chalk drawings on a classroom blackboard"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var m = vec3<f32>(0.0);
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) { m = max(m, src_at(uv + vec2<f32>(f32(i), f32(j)) * frame.res.zw)); } }
  let c = src_at(uv);
  let chalk = step(0.6, luma(m));
  let dust = hash21(floor(px / 1.5)) * 0.6 + 0.4 * vnoise(px * 0.3);
  let board = c * (0.8 + 0.5 * fbm(vec2<f32>(px.x * 0.004, px.y * 0.02))) + 0.03 * fbm(px * 0.02);
  return mix(board, vec3<f32>(0.93, 0.93, 0.88), chalk * step(0.3, dust)) + 0.08 * blur9(uv, 3.0) * step(0.5, dust);
}
"""

# Not a filter: the chalk lines are the objects' edges as line segments, broken along their own length (so a gap
# stays at the same place on an edge), drawn over a board on which the lit faces are only faintly rubbed in.
comptime ChalkboardPasses = Then[ShadowPass, Then[MeshPassOf[MatBoard, MatBoardSky], WirePassOf[ChalkLine]]]
comptime Chalkboard = Stage[ChalkDust]


# ---------------------------------------------------------------- 35. chiaroscuro
struct MatCandle(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "lit by the point lights only"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  var c = s.base * s.base * 0.012;
  let count = min(u32(lights.n.x), 16u);
  for (var i = 0u; i < count; i++) {
    let d = lights.l[i].pos_range.xyz - s.wpos;
    let dist = max(length(d), 1e-4);
    let fall = 1.0 / (0.35 + dist * dist * 0.22);
    c += s.base * s.base * vec3<f32>(1.0, 0.72, 0.42) * max(dot(n, d / dist), 0.0) * fall * 3.2;
  }
  return vec4<f32>(sqrt(c / (c + 0.6) * 1.6), 1.0);"""


struct Varnish(Style):
    comptime NAME: StaticString = "chiaroscuro"
    comptime AFTER: StaticString = "Baroque chiaroscuro: Caravaggio, Georges de La Tour's candle-lit scenes"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var c = src_at(uv) + vec3<f32>(0.03, 0.02, 0.01);
  let p = px / 14.0;
  let id = floor(p);
  var d1 = 9.0;
  var d2 = 9.0;
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) {
    let s = id + vec2<f32>(f32(i), f32(j));
    let d = length(p - s - hash22(s));
    if d < d1 { d2 = d1; d1 = d; } else if d < d2 { d2 = d; }
  } }
  c *= 1.0 - 0.3 * smoothstep(0.05, 0.0, d2 - d1);
  return c * vec3<f32>(1.0, 0.94, 0.80) * vignette(uv, 1.3);
}
"""

# Not a filter: the sun is not in this picture. The material lights each surface from the scene's point light alone,
# with no ambient term, so the darkness is the absence of light on those surfaces and not a darkened daylight frame.
comptime ChiaroscuroPasses = MeshPassOf[MatCandle, MatSkyDark]
comptime Chiaroscuro = Stage[Varnish]


# ---------------------------------------------------------------- 36. paper cut-outs
struct DepthStep(Style):
    comptime NAME: StaticString = "where a nearer sheet overhangs"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let z = view_z(uv);
  var sh = 0.0;
  for (var i = 1; i <= 5; i++) {
    sh = max(sh, step(view_z(uv + vec2<f32>(-0.004, -0.006) * f32(i)), z * 0.94));
  }
  return vec3<f32>(sh);
}
"""


struct PaperLayers(Style):
    comptime NAME: StaticString = "paper_cut"
    comptime AFTER: StaticString = "Henri Matisse's paper cut-outs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var hsv = rgb2hsv(src_at(uv));
  hsv.x = floor(hsv.x * 10.0 + 0.5) / 10.0;
  hsv.y = clamp(hsv.y * 1.5, 0.0, 0.9);
  hsv.z = clamp(hsv.z * 1.15, 0.0, 0.95);
  let o = hsv2rgb(hsv) * (1.0 - 0.45 * src2_at(uv).r);
  return o * (0.95 + 0.06 * vnoise(px * 0.7) + 0.03 * vnoise(vec2<f32>(px.x * 0.05, px.y * 0.9)));
}
"""

# Not a filter: the sheets are the items drawn in their own flat colour (no light), and the shadow a sheet casts on
# the one behind is a second picture, made from the depth buffer at half size and softened there, then laid under.
comptime PaperCutPasses = MeshPassOf[MatFlat, MatSkyPaper]
comptime PaperCut = Join[Stage[Copy], Scaled[ThenPost[Stage[DepthStep], Stage[Blur13]], 2], Stage[PaperLayers]]


# ---------------------------------------------------------------- 37. blue-and-white porcelain
struct MatGlaze(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "cobalt wash under a glaze"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let l = normalize(vec3<f32>(0.4, 1.0, 0.6));
  let v = normalize(cam.eye.xyz - s.wpos);
  let tone = (0.2 + 0.8 * max(dot(n, l), 0.0) * s.sf) * (0.55 + 0.45 * dot(s.base, vec3<f32>(0.333)));
  let brush = 0.72 + 0.28 * sin(dot(s.wpos, vec3<f32>(9.0, 23.0, 13.0)) + 2.0 * sin(dot(s.wpos, vec3<f32>(3.0, 1.0, 4.0))));
  let blue = (0.30 * step(tone, 0.62) + 0.34 * step(tone, 0.40)) * brush;
  var c = mix(vec3<f32>(0.95, 0.96, 0.97), vec3<f32>(0.07, 0.16, 0.52), blue);
  c += 0.55 * pow(max(dot(n, normalize(v + l)), 0.0), 60.0) + 0.10 * pow(1.0 - max(dot(n, v), 0.0), 3.0);
  return vec4<f32>(c, 1.0);"""


struct MatSkyGlaze(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "white ground"
    comptime BODY: StaticString = """
  return vec4<f32>(0.93, 0.94, 0.96, 1.0);"""


struct MatCobaltHull(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "cobalt hull"
    comptime VERT_WORLD: StaticString = "world = world + normalize(world - m[3].xyz) * 0.007 * length(world - cam.eye.xyz);"
    comptime BODY: StaticString = """
  if dot(s.wnrm, cam.eye.xyz - s.wpos) > 0.0 { discard; }
  return vec4<f32>(0.06, 0.13, 0.46, 1.0);"""

# Not a filter, and no stage: the blue is painted on the surface (its strength from the real light, its streaks fixed
# to the object), the highlight is the glaze's own, from the true normal, and the line is a cobalt hull.
comptime PorcelainPasses = Then[ShadowPass, Then[MeshPassOf[MatGlaze, MatSkyGlaze], MeshPassOf[MatCobaltHull, MatNothing]]]


# ---------------------------------------------------------------- 38. cel animation
# Not a filter, and no stage: two tones of paint per colour from the light and the shadow map, on the surface, and an
# ink line that is a hull.
comptime CelPasses = Then[ShadowPass, Then[MeshPassOf[MatCel, MatSkyPale], HullPass]]
