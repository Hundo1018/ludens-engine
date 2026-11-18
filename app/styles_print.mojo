"""Pipelines after printing and drawing techniques. What makes each one is in its passes: an ink line that is geometry
(a hull, or line segments tested against depth), tone drawn on the surface in the surface's own coordinates, plates
that are separate targets, dots that are separate quads."""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.post import Style, Stage, ThenPost, Join, Scaled, Sized, Copy
from app.render_pass import Then
from app.shadow_pass import ShadowPass
from app.mesh_pass import MeshPassOf
from app.material import Material
from app.wire_pass import WireKind, WirePassOf
from app.strokes import StrokeKind, Strokes
from app.gpu_blend import BLEND_MULTIPLY, BLEND_ALPHA, DEPTH_GREATER, DEPTH_LESS_EQUAL
from app.gbuffer import HullPass, AlbedoPasses, MatNothing
from app.styles_material import MatFlat, MatFlatShadow, MatSkyPale, MatSkyPaper, MatHullThick


# ---------------------------------------------------------------- 12. newspaper halftone
struct HalftoneDots(StrokeKind):
    comptime NAME: StaticString = "halftone_dots"
    comptime WHAT: StaticString = "halftone dots, 45 degrees"
    comptime AFTER: StaticString = ""
    comptime CELL: Int = 4
    comptime CANVAS_R: Float64 = 0.90
    comptime CANVAS_G: Float64 = 0.87
    comptime CANVAS_B: Float64 = 0.78
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let c0 = frame.res.xy * 0.5;
  let p = (cell * STROKE_CELL - c0) * 1.45;
  let centre = c0 + vec2<f32>(p.x - p.y, p.x + p.y) * 0.7071;
  let l = smoothstep(0.1, 0.95, luma(src_at(centre * frame.res.zw)));
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(STROKE_CELL * 1.45 * 0.74 * sqrt(1.0 - l) + 0.01);
  s.angle = 0.0;
  s.color = vec4<f32>(0.09, 0.08, 0.08, 1.0);
  s.seed = 0.0;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  return vec4<f32>(color.rgb, smoothstep(1.0, 0.8, length(q)));
}
"""


struct Newsprint(Style):
    comptime NAME: StaticString = "news_halftone"
    comptime AFTER: StaticString = "newspaper halftone photographs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return blur9(uv, 0.6) * (0.95 + 0.07 * vnoise(px * 0.35)) * (0.97 + 0.03 * vnoise(vec2<f32>(px.x * 0.02, px.y * 0.6)));
}
"""

# Not a filter: every dot is one quad, sized once from the tone at its centre. Dots larger than their cell overlap
# their neighbours and join into the solid of the darks, as ink does; then the sheet takes the ink (a second stage).
comptime NewsHalftone = ThenPost[Strokes[HalftoneDots], Stage[Newsprint]]


# ---------------------------------------------------------------- 13. four-colour comic
struct CmyPlates(StrokeKind):
    comptime NAME: StaticString = "cmy_plates"
    comptime WHAT: StaticString = "three dot plates, multiplied"
    comptime AFTER: StaticString = "four-colour comic-book printing with Ben-Day dots, as Roy Lichtenstein enlarged it"
    comptime CELL: Int = 6
    comptime LAYERS: Int = 3
    comptime BLEND: Int = BLEND_MULTIPLY
    comptime CANVAS_R: Float64 = 0.97
    comptime CANVAS_G: Float64 = 0.95
    comptime CANVAS_B: Float64 = 0.88
    comptime WGSL: StaticString = """
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let ang = array<f32, 3>(0.26, 1.31, 0.0)[layer];
  let c0 = frame.res.xy * 0.5;
  let p = (cell * STROKE_CELL - c0) * 1.45;
  let centre = c0 + vec2<f32>(cos(ang) * p.x - sin(ang) * p.y, sin(ang) * p.x + cos(ang) * p.y);
  let c = src_at(centre * frame.res.zw);
  let k = 1.0 - max(c.r, max(c.g, c.b));
  let cmy = (vec3<f32>(1.0) - c - k) / max(1.0 - k, 1e-3);
  var s : Stroke;
  s.centre = centre;
  s.half = vec2<f32>(STROKE_CELL * 1.45 * 0.70 * sqrt(clamp(cmy[layer] + 0.6 * k, 0.0, 1.0)) + 0.01);
  s.angle = 0.0;
  s.color = vec4<f32>(array<vec3<f32>, 3>(vec3<f32>(0.0, 0.68, 0.93), vec3<f32>(0.93, 0.0, 0.55), vec3<f32>(1.0, 0.92, 0.0))[layer], 1.0);
  s.seed = 0.0;
  return s;
}
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  return vec4<f32>(mix(vec3<f32>(1.0), color.rgb, smoothstep(1.0, 0.82, length(q))), 1.0);
}
"""


struct KeyPlate(Style):
    comptime NAME: StaticString = "comic_cmyk"
    comptime AFTER: StaticString = "four-colour comic-book printing with Ben-Day dots, as Roy Lichtenstein enlarged it"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let k = scene_at(uv);
  return src_at(uv) * mix(1.0, 0.04, step(max(k.r, max(k.g, k.b)), 0.12));
}
"""

# Not a filter: the passes draw flat colour (no light) and the black line as a hull, so the black plate is geometry.
# The three colour plates are three layers of dot quads, each at its screen angle, printed by multiplying: where a
# cyan and a yellow dot overlap the paper is green, and the overlap is where the dots happen to cross.
comptime ComicPasses = Then[ShadowPass, Then[MeshPassOf[MatFlatShadow, MatSkyPale], HullPass]]
comptime ComicCmyk = ThenPost[Strokes[CmyPlates], Stage[KeyPlate]]


# ---------------------------------------------------------------- 14. risograph
struct RisoWarmDrum(Style):
    comptime NAME: StaticString = "riso_drum_pink"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let a = aux_at(uv);
  let warm = smoothstep(-0.05, 0.25, a.r - a.b) * a.a;
  let tone = 1.0 - luma(src_at(uv));
  return vec3<f32>(step(hash21(px + 3.0) * 0.9 + 0.05, clamp(tone * 1.5 * warm + 0.15 * warm, 0.0, 1.0)));
}
"""


struct RisoCoolDrum(Style):
    comptime NAME: StaticString = "riso_drum_blue"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let a = aux_at(uv);
  let cool = mix(1.0, smoothstep(0.25, -0.05, a.r - a.b), a.a);
  let tone = 1.0 - luma(src_at(uv));
  return vec3<f32>(step(hash21(px * 1.3 + 11.0) * 0.9 + 0.05, clamp(tone * 1.4 * cool, 0.0, 1.0)));
}
"""


struct RisoPrint(Style):
    comptime NAME: StaticString = "risograph"
    comptime AFTER: StaticString = "two-colour Risograph prints"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var paper = vec3<f32>(0.95, 0.93, 0.87) * (0.97 + 0.04 * vnoise(px * 0.5));
  paper *= mix(vec3<f32>(1.0), vec3<f32>(1.0, 0.28, 0.47), src_at(uv).r);
  paper *= mix(vec3<f32>(1.0), vec3<f32>(0.0, 0.42, 0.72), src2_at(uv + vec2<f32>(5.0, -3.0) * frame.res.zw).r);
  return paper;
}
"""

# Not a filter: which drum prints an object is decided by the object's own colour, read from an aux target of unlit
# colours, so a warm object is pink in its shadow too; a lit frame cannot tell a red thing in shade from a brown one.
# Each drum is its own target, and the second is laid down 5 pixels out of register.
comptime Risograph = Join[Stage[RisoWarmDrum], Stage[RisoCoolDrum], Stage[RisoPrint]]
comptime RisographAux = AlbedoPasses


# ---------------------------------------------------------------- 15. engraving
struct MatEngrave(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "engraved lines on the surface"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let tone = clamp((0.25 + 0.75 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf) * (0.55 + 0.45 * dot(s.base, vec3<f32>(0.333))), 0.0, 1.0);
  // a direction lying in the surface: lines run round the form, 46 to the metre, and swell as the tone falls
  let a = normalize(cross(n, vec3<f32>(0.37, 0.21, 0.90)));
  let b = cross(n, a);
  // the line count halves each time the distance doubles, so the lines keep their spacing on the page
  let f = 290.0 / exp2(floor(log2(max(length(s.wpos - cam.eye.xyz), 2.0) / 5.0)));
  let w1 = 0.5 + 0.5 * sin(dot(s.wpos, a) * f);
  let w2 = 0.5 + 0.5 * sin(dot(s.wpos, b) * f);
  var ink = smoothstep(0.15, -0.15, w1 - (1.0 - tone) * 1.05);
  ink = max(ink, smoothstep(0.15, -0.15, w2 - (0.5 - tone) * 1.7));
  return vec4<f32>(mix(vec3<f32>(0.93, 0.90, 0.80), vec3<f32>(0.13, 0.10, 0.08), ink), 1.0);"""

# Not a filter, and no stage at all: the lines are drawn in each surface's own plane, in metres. They foreshorten
# with the face, run round a sphere, stay on an object when it moves, and their width comes from the real light and
# the shadow map.
comptime EngravingPasses = Then[ShadowPass, Then[MeshPassOf[MatEngrave, MatSkyPaper], HullPass]]


# ---------------------------------------------------------------- 16. cross-hatching
struct MatHatch(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "hatching on the surface"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let tone = clamp((0.2 + 0.8 * max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf) * (0.6 + 0.4 * dot(s.base, vec3<f32>(0.333))), 0.0, 1.0);
  let w = pow(abs(n), vec3<f32>(6.0));
  let ws = w / (w.x + w.y + w.z);
  var ink = 0.0;
  for (var k = 0; k < 4; k++) {
    let ang = 0.6 + 0.8 * f32(k);
    let dir = vec2<f32>(cos(ang), sin(ang));
    let gap = (26.0 + 5.0 * f32(k)) / exp2(floor(log2(max(length(s.wpos - cam.eye.xyz), 2.0) / 5.0)));
    let hx = smoothstep(0.30, 0.12, abs(fract(dot(s.wpos.zy, dir) * gap) - 0.5));
    let hy = smoothstep(0.30, 0.12, abs(fract(dot(s.wpos.xz, dir) * gap) - 0.5));
    let hz = smoothstep(0.30, 0.12, abs(fract(dot(s.wpos.xy, dir) * gap) - 0.5));
    ink = max(ink, (hx * ws.x + hy * ws.y + hz * ws.z) * step(tone, 0.80 - 0.19 * f32(k)));
  }
  ink *= smoothstep(26.0, 13.0, length(s.wpos - cam.eye.xyz));
  return vec4<f32>(mix(vec3<f32>(0.96, 0.95, 0.91), vec3<f32>(0.10, 0.10, 0.16), clamp(ink, 0.0, 1.0)), 1.0);"""

# Not a filter: four directions of strokes fixed to the surfaces (projected along the world axes), one more direction
# for each step into shade. The strokes are on the things, so they do not slide over them when the camera moves.
comptime CrossHatchPasses = Then[ShadowPass, Then[MeshPassOf[MatHatch, MatSkyPaper], HullPass]]


# ---------------------------------------------------------------- 17. woodcut
struct MatWoodcut(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "cut lights, solid darks"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let lit = max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf;
  // the gouge follows the form: cuts run along the surface, across the direction the light comes from
  let across = normalize(cross(n, normalize(vec3<f32>(0.4, 1.0, 0.6))) + vec3<f32>(1e-3, 0.0, 0.0));
  let cut = 0.5 + 0.5 * sin(dot(s.wpos, cross(n, across)) * 70.0 + 3.0 * sin(dot(s.wpos, across) * 9.0));
  let ink = max(step(lit, 0.22), step(cut, 0.9 - lit * 1.3));
  return vec4<f32>(mix(vec3<f32>(0.91, 0.86, 0.74), vec3<f32>(0.07, 0.06, 0.05), ink), 1.0);"""


struct BlockPrint(Style):
    comptime NAME: StaticString = "woodcut"
    comptime AFTER: StaticString = "German Expressionist woodcuts (Die Bruecke)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let grain = fbm(vec2<f32>(px.x * 0.02, px.y * 0.25));
  let starved = step(vnoise(px * 0.9) + 0.25 * grain, 0.12) * step(luma(c), 0.3);
  return mix(c, vec3<f32>(0.91, 0.86, 0.74), starved) * (0.96 + 0.06 * grain);
}
"""

# Not a filter: black is what the knife left standing. The darks are decided by the shadow map, the cuts in the lights
# follow each surface across the light's direction, and the contour is a thick hull; the stage only prints the block
# (ink that did not take along the wood's grain).
comptime WoodcutPasses = Then[ShadowPass, Then[MeshPassOf[MatWoodcut, MatSkyPaper], MeshPassOf[MatHullThick, MatNothing]]]
comptime Woodcut = Stage[BlockPrint]


# ---------------------------------------------------------------- 18. blueprint
struct MatBlueFill(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "blue fill"
    comptime BODY: StaticString = """
  return vec4<f32>(0.05, 0.20, 0.52, 1.0);"""


struct MatBlueSky(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "blue sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.045, 0.18, 0.49, 1.0);"""


struct VisibleEdges(WireKind):
    comptime NAME: StaticString = "visible edges"
    comptime FRAG: StaticString = """
  return vec4<f32>(0.92, 0.96, 1.0, 1.0);"""


struct HiddenEdges(WireKind):
    comptime NAME: StaticString = "hidden edges, depth test reversed, dashed"
    comptime DEPTH_COMPARE: Int = DEPTH_GREATER
    comptime FRAG: StaticString = """
  if fract(in.t / 0.24) > 0.5 { discard; }
  return vec4<f32>(0.45, 0.62, 0.90, 1.0);"""


struct DraftingSheet(Style):
    comptime NAME: StaticString = "blueprint"
    comptime AFTER: StaticString = "cyanotype architectural blueprints, with hidden edges dashed as in technical drawing"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let g1 = min(step(fract(px.x / 40.0), 1.0 / 40.0) + step(fract(px.y / 40.0), 1.0 / 40.0), 1.0);
  let g2 = min(step(fract(px.x / 8.0), 1.0 / 8.0) + step(fract(px.y / 8.0), 1.0 / 8.0), 1.0);
  let c = src_at(uv) * (0.85 + 0.3 * fbm(px * 0.01));
  return c + vec3<f32>(0.85, 0.9, 1.0) * (0.16 * g1 + 0.05 * g2);
}
"""

# Not a filter: the dashed lines are the edges that are behind something. A second line pass runs with the depth test
# reversed, so it draws exactly the segments the solids hide; a finished frame holds no trace of them.
comptime BlueprintPasses = Then[MeshPassOf[MatBlueFill, MatBlueSky], Then[WirePassOf[VisibleEdges], WirePassOf[HiddenEdges]]]
comptime Blueprint = Stage[DraftingSheet]


# ---------------------------------------------------------------- 19. ukiyo-e
struct MatBokashiSky(Material):
    """The sky as a graded band from the top of the sheet (bokashi), by view direction."""

    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "bokashi sky"
    comptime BODY: StaticString = """
  let up = normalize(s.wpos - cam.eye.xyz).y;
  return vec4<f32>(mix(vec3<f32>(0.90, 0.85, 0.70), vec3<f32>(0.10, 0.20, 0.42), smoothstep(0.04, 0.26, up)), 1.0);"""


struct WoodblockInks(Style):
    comptime NAME: StaticString = "ukiyo_e"
    comptime AFTER: StaticString = "Edo woodblock prints: Hokusai, Hiroshige"
    comptime WGSL: StaticString = """
const UKI = array<vec3<f32>, 7>(
  vec3<f32>(0.10, 0.20, 0.42), vec3<f32>(0.30, 0.47, 0.60), vec3<f32>(0.86, 0.80, 0.63), vec3<f32>(0.76, 0.30, 0.20),
  vec3<f32>(0.45, 0.55, 0.42), vec3<f32>(0.72, 0.62, 0.40), vec3<f32>(0.20, 0.19, 0.20));
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  var o = c;
  if is_far(uv, 60.0) < 0.5 && max(c.r, max(c.g, c.b)) > 0.12 {
    var bd = 1e9;
    for (var i = 0u; i < 7u; i++) {
      let d = UKI[i] - c;
      if dot(d, d) < bd { bd = dot(d, d); o = UKI[i]; }
    }
  }
  return o * (0.93 + 0.1 * vnoise(vec2<f32>(px.x * 0.9, px.y * 0.08)) + 0.04 * vnoise(px * 0.6));
}
"""

# Not a filter: each block prints one flat colour, so the passes draw the items' own colours with no light, a shadow
# only where the shadow map casts one, and the key block as a hull. The stage maps what was printed onto seven
# pigments and lays the paper's fibre over it.
comptime UkiyoEPasses = Then[ShadowPass, Then[MeshPassOf[MatFlatShadow, MatBokashiSky], HullPass]]
comptime UkiyoE = Stage[WoodblockInks]


# ---------------------------------------------------------------- 20. constructivist poster
struct Photomontage(Style):
    comptime NAME: StaticString = "constructivist"
    comptime AFTER: StaticString = "1920s Soviet Constructivist photomontage posters: Rodchenko, El Lissitzky"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let red = vec3<f32>(0.80, 0.12, 0.09);
  let cream = vec3<f32>(0.92, 0.87, 0.74);
  let side = step(0.0, uv.x * 0.9 + uv.y * 1.6 - 1.25);
  let a = aux_at(uv);
  var o = mix(cream, red, side);
  if a.a > 0.5 {
    let l = smoothstep(0.15, 0.9, luma(src_at(uv)));
    let photo = vec3<f32>(step(bayer4(px), l * 0.95 + 0.02)) * vec3<f32>(0.93, 0.90, 0.84) + vec3<f32>(0.07);
    let warm = step(0.18, a.r - max(a.g, a.b));
    o = mix(photo, mix(red, vec3<f32>(0.08), step(l, 0.35)), warm);
    if a.g > a.r && a.g > a.b * 0.98 && luma(a.rgb) > 0.58 { o = mix(cream, red, 1.0 - side) * (0.75 + 0.25 * l); }
  }
  o = mix(o, vec3<f32>(0.08), step(abs(uv.x * 0.9 + uv.y * 1.6 - 1.25), 0.012) * (1.0 - a.a));
  return o * (0.94 + 0.08 * vnoise(px * 0.5));
}
"""

# Not a filter: a montage is cut from different materials. Which treatment a thing gets (a screened photograph, a
# flat red shape, part of the ground) is chosen by what the thing is: its own colour and whether anything is there at
# all, both read from an aux target of unlit colour and coverage. The lit frame only supplies the photograph's tone.
comptime Constructivist = Stage[Photomontage]
comptime ConstructivistAux = AlbedoPasses


# ---------------------------------------------------------------- 21. pop-art panels
struct Posterize3(Style):
    comptime NAME: StaticString = "three-level screen"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  if max(c.r, max(c.g, c.b)) < 0.12 { return vec3<f32>(0.0, 1.0, 0.0); }
  let l = smoothstep(0.2, 0.9, luma(c));
  return vec3<f32>(select(select(0.5, 0.0, l < 0.38), 1.0, l > 0.72), 0.0, 0.0);
}
"""


struct FourUp(Style):
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
  // each pull of the screen lands a little off: the panel's registration
  let off = (hash22(p + 3.0) - 0.5) * 0.012;
  let s = src_texel(u + off);
  var o = POP[k + u32(s.r * 2.0 + 0.5)];
  if src_texel(u).g > 0.5 { o = vec3<f32>(0.05); }
  let border = step(u.x, 0.008) + step(u.y, 0.012) + step(0.992, u.x) + step(0.988, u.y);
  return mix(o, vec3<f32>(0.05), clamp(border, 0.0, 1.0));
}
"""

# Not a filter: one screen is made once, at a quarter of the frame, holding only which of three tones each point is
# and where the line is (the line is a hull in the passes); the four panels are the same small screen pulled four
# times in different inks, each pull slightly off register against its own line.
comptime PopArtPasses = Then[ShadowPass, Then[MeshPassOf[MatFlatShadow, MatSkyPale], HullPass]]
comptime PopArt = ThenPost[Scaled[Stage[Posterize3], 2], Stage[FourUp]]


# ---------------------------------------------------------------- 22. ligne claire
# Not a filter, and no stage: flat local colour from the items themselves, a cast shadow as one flat darker tone from
# the shadow map, and one even line that is a hull, so it passes behind what stands in front of it.
comptime LigneClairePasses = Then[ShadowPass, Then[MeshPassOf[MatFlatShadow, MatSkyPale], HullPass]]


# ---------------------------------------------------------------- 23. topographic map
struct MatContour(Material):
    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "height contours and grid on the surface"
    comptime BODY: StaticString = """
  let h = s.wpos.y + 0.02;
  let dist = length(s.wpos - cam.eye.xyz);
  let n = normalize(s.wnrm);
  var o = mix(vec3<f32>(0.78, 0.88, 0.70), vec3<f32>(0.93, 0.86, 0.66), smoothstep(0.0, 1.5, h));
  o = mix(o, vec3<f32>(0.99, 0.98, 0.95), smoothstep(1.5, 3.5, h));
  o *= 0.80 + 0.20 * max(dot(n, normalize(vec3<f32>(-0.5, 0.6, 0.6))), 0.0);
  // a line's width in metres grows with distance so it stays about a pixel wide; none on level ground
  let steep = sqrt(max(1.0 - n.y * n.y, 0.0));
  let w = 0.0016 * dist;
  let minor = step(abs(fract(h / 0.25 + 0.5) - 0.5) * 0.25, w * steep) * step(0.05, steep);
  let major = step(abs(fract(h + 0.5) - 0.5), 2.2 * w * steep) * step(0.05, steep);
  o = mix(o, vec3<f32>(0.62, 0.38, 0.20), clamp(0.75 * minor + major, 0.0, 1.0));
  let gx = step(abs(fract(s.wpos.x / 2.0 + 0.5) - 0.5) * 2.0, w * 1.2);
  let gz = step(abs(fract(s.wpos.z / 2.0 + 0.5) - 0.5) * 2.0, w * 1.2);
  o = mix(o, vec3<f32>(0.20, 0.45, 0.75), 0.6 * max(gx, gz) * step(0.7, n.y));
  return vec4<f32>(o, 1.0);"""

# Not a filter, and no stage: the contours are lines of equal height drawn on the surfaces themselves, from the
# interpolated world position, every 0.25 m and heavier every metre, with the survey grid on level ground.
comptime TopoMapPasses = Then[MeshPassOf[MatContour, MatSkyPaper], HullPass]
