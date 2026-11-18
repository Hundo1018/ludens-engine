"""Surface materials (app/material.mojo Material) for the pipelines whose look starts on the surface, before any post
stage. A pass built with one of these as the pack's first material shades every item with it (an ID that the pack does
not have falls to the first), and a sky material of ID MAT_SKY keeps the sky sphere apart:

    comptime CelPasses = Then[ShadowPass, Then[PrimitivePass, MeshPassOf[MatCel, MatSky]]]
"""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.material import Material


struct MatCel(Material):
    """Two tones per colour, split where the sun's light (with the shadow map) falls below a threshold; the dark
    tone leans blue; a hard-edged highlight."""

    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let l = normalize(vec3<f32>(0.4, 1.0, 0.6));
  let v = normalize(cam.eye.xyz - s.wpos);
  let lit = step(0.2, dot(n, l) * s.sf);
  let g = dot(s.base, vec3<f32>(0.333));
  let base = clamp(mix(vec3<f32>(g), s.base, 1.3), vec3<f32>(0.0), vec3<f32>(1.0));
  let spec = step(0.97, dot(n, normalize(v + l))) * lit;
  return vec4<f32>(mix(base * vec3<f32>(0.52, 0.52, 0.70), base, lit) + spec * 0.35, 1.0);"""


struct MatFlatSky(Material):
    """A flat pale sky for the cel pipeline."""

    comptime ID: Int = MAT_SKY
    comptime BODY: StaticString = """
  return vec4<f32>(0.66, 0.84, 0.96, 1.0);"""


struct MatHeat(Material):
    """Temperature as grey: warm-coloured bodies are the hot ones, sunlit faces are warmer than shaded ones, metal
    reads cold (low emissivity)."""

    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let sun = max(dot(n, normalize(vec3<f32>(0.4, 1.0, 0.6))), 0.0) * s.sf;
  let body = dot(s.base, vec3<f32>(0.85, 0.1, -0.45));
  let h = clamp(0.08 + 0.55 * body + 0.28 * sun - 0.3 * s.metal, 0.0, 1.0);
  return vec4<f32>(h, h, h, 1.0);"""


struct MatDark(Material):
    """Nothing: the sky of the thermal and radiograph pipelines."""

    comptime ID: Int = MAT_SKY
    comptime BODY: StaticString = """
  return vec4<f32>(0.02, 0.02, 0.02, 1.0);"""


struct MatXray(Material):
    """How edge-on the surface is to the eye, which is where a ray passes through the most material of a shell."""

    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  let f = 1.0 - abs(dot(normalize(s.wnrm), normalize(cam.eye.xyz - s.wpos)));
  let d = 0.12 + 0.88 * pow(f, 1.8);
  return vec4<f32>(d, d, d, 1.0);"""
