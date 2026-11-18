"""Helper stages for chains (app/post.mojo ThenPost): filters that are not a look by themselves."""
from app.post import Style


struct Kuwahara(Style):
    """The Kuwahara filter: each pixel takes the mean of whichever of its four 5 x 5 corner windows varies least, so
    flat areas smooth out and borders stay sharp. The first stage of the painted looks."""

    comptime NAME: StaticString = "kuwahara"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var best = vec3<f32>(0.0);
  var bv = 1e9;
  for (var q = 0; q < 4; q++) {
    let sx = f32(q & 1) * 2.0 - 1.0;
    let sy = f32(q >> 1) * 2.0 - 1.0;
    var m = vec3<f32>(0.0);
    var m2 = 0.0;
    for (var j = 0; j < 5; j++) { for (var i = 0; i < 5; i++) {
      let c = src_at(uv + vec2<f32>(f32(i) * sx, f32(j) * sy) * frame.res.zw * 1.25);
      m += c;
      m2 += dot(c, c);
    } }
    m /= 25.0;
    let v = m2 / 25.0 - dot(m, m);
    if v < bv { bv = v; best = m; }
  }
  return best;
}
"""


struct BrightPass(Style):
    """Keeps only what is brighter than 0.9, for a glow or a lens streak to spread."""

    comptime NAME: StaticString = "bright_pass"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  return c * smoothstep(0.9, 1.0, max(c.r, max(c.g, c.b)));
}
"""


struct StreakH(Style):
    """A 61-texel horizontal smear with a long tail (inside Scaled[.., 4]: 240 pixels of the frame)."""

    comptime NAME: StaticString = "streak_h"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var s = vec3<f32>(0.0);
  var wsum = 0.0;
  for (var i = -30; i <= 30; i++) {
    let w = exp(-abs(f32(i)) / 11.0);
    s += src_at(uv + vec2<f32>(f32(i) * frame.res.z, 0.0)) * w;
    wsum += w;
  }
  return s / wsum;
}
"""


struct Blur13(Style):
    """A 13-tap disc blur, 2.5 texels wide: run inside Scaled it covers 4 or 8 times that for the same cost."""

    comptime NAME: StaticString = "blur"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var s = src_at(uv);
  for (var i = 0; i < 12; i++) {
    let a = f32(i) * 2.39996;
    s += src_at(uv + vec2<f32>(cos(a), sin(a)) * sqrt(f32(i) + 1.0) * 0.72 * frame.res.zw);
  }
  return s / 13.0;
}
"""


struct AddGlow(Style):
    """`src` plus 1.4 times `src2`: the last stage of a Join whose second branch is the blurred light."""

    comptime NAME: StaticString = "add_glow"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> { return src_at(uv) + 1.4 * src2_at(uv); }
"""
