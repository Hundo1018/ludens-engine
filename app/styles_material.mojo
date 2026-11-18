"""Surface materials (app/material.mojo Material) shared by the style pipelines: looks that are decided on the surface,
with the true normal, the shadow map and the item's own colour, before any stage sees the frame."""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.material import Material
from app.gpu_blend import BLEND_ADD


struct MatFlat(Material):
    """The item's colour with no light at all."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "flat colour"
    comptime BODY: StaticString = """
  return vec4<f32>(s.base, 1.0);"""


struct MatFlatShadow(Material):
    """The item's colour, one step darker and bluer where the shadow map says the sun does not reach."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "flat colour, cast shadows"
    comptime BODY: StaticString = """
  let lit = step(0.5, s.sf) * step(0.0, dot(normalize(s.wnrm), normalize(vec3<f32>(0.4, 1.0, 0.6))));
  let g = dot(s.base, vec3<f32>(0.333));
  let base = clamp(mix(vec3<f32>(g), s.base, 1.25) * 1.06, vec3<f32>(0.0), vec3<f32>(1.0));
  return vec4<f32>(mix(base * vec3<f32>(0.70, 0.72, 0.84), base, lit), 1.0);"""


struct MatCel(Material):
    """Two tones per colour, split where the sun's light (with the shadow map) falls below a threshold; the dark
    tone leans blue; a hard-edged highlight."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "two-tone cel"
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let l = normalize(vec3<f32>(0.4, 1.0, 0.6));
  let v = normalize(cam.eye.xyz - s.wpos);
  let lit = step(0.2, dot(n, l) * s.sf);
  let g = dot(s.base, vec3<f32>(0.333));
  let base = clamp(mix(vec3<f32>(g), s.base, 1.3), vec3<f32>(0.0), vec3<f32>(1.0));
  let spec = step(0.97, dot(n, normalize(v + l))) * lit;
  return vec4<f32>(mix(base * vec3<f32>(0.52, 0.52, 0.70), base, lit) + spec * 0.35, 1.0);"""


struct MatSkyPale(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "pale sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.70, 0.86, 0.96, 1.0);"""


struct MatSkyPaper(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "paper sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.94, 0.92, 0.85, 1.0);"""


struct MatSkyDark(Material):
    comptime ID: Int = MAT_SKY
    comptime NAME: StaticString = "dark sky"
    comptime BODY: StaticString = """
  return vec4<f32>(0.02, 0.02, 0.02, 1.0);"""


struct MatHullThick(Material):
    """The outline hull (app/gbuffer.mojo MatHull) three times as wide: a line cut with a knife."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "thick hull, back faces"
    comptime VERT_WORLD: StaticString = "world = world + normalize(world - m[3].xyz) * 0.014 * length(world - cam.eye.xyz);"
    comptime BODY: StaticString = """
  if dot(s.wnrm, cam.eye.xyz - s.wpos) > 0.0 { discard; }
  return vec4<f32>(0.06, 0.05, 0.05, 1.0);"""
