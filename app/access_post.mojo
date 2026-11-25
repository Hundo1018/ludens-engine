"""The accessibility stages of the post-processing graph (app/post.mojo), switched by the player's settings (game/access.mojo)
through `SceneRendererOf.post_user` (`Access.post_user(dt)`): a flash limiter and a colour-blind filter.

    comptime Pipeline = AccessPost                # or: ThenPost[Lens, AccessPost]
    var r = SceneRendererOf[DefaultPasses, Pipeline](device, format, view)
    r.post_user = access.post_user(frame_dt)      # every frame; kinds off and a step of 0 return the input unchanged
    r.reduce_motion = access.reduce_motion        # the lens stages (app/lens.mojo) then draw no blur

FlashLimit (inside History, so `prev` is its own last output): a pixel whose luminance would move more than `Frame.user.w` away
from where it was a frame ago moves exactly that far, on the line from the old colour to the new one. Frame 0 and a limit of 0
return the input. ColorBlind reads `Frame.user.xyz`: kind 1 protanopia, 2 deuteranopia, 3 tritanopia; strength 0 .. 1; z = 1
shows the simulation, 0 the correction. Both are mirrored by game/access_filters.mojo, which tests/access_native.mojo compares
them with pixel by pixel.

`AccessPost` runs both at the cost of a full-screen pass each plus History's copy of the frame, whether or not a setting is on. A
game that offers neither switch leaves them out of its pipeline."""
from app.post import History, Stage, Style, ThenPost


struct FlashLimit(Style):
    comptime NAME: StaticString = "flash_limit"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let limit = frame.user.w;
  if limit <= 0.0 || frame.t.y < 0.5 { return c; }
  let p = prev_at(uv);
  let w = vec3<f32>(0.2126, 0.7152, 0.0722);
  let d = dot(c - p, w);
  let a = abs(d);
  if a <= limit { return c; }
  return p + (c - p) * (limit / a);
}
"""


struct ColorBlind(Style):
    comptime NAME: StaticString = "color_blind"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn cb_to_linear(c : vec3<f32>) -> vec3<f32> {
  return select(pow((c + 0.055) / 1.055, vec3<f32>(2.4)), c / 12.92, c <= vec3<f32>(0.04045));
}
fn cb_to_srgb(c : vec3<f32>) -> vec3<f32> {
  return select(1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - 0.055, c * 12.92, c <= vec3<f32>(0.0031308));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let kind = i32(frame.user.x + 0.5);
  let k = clamp(frame.user.y, 0.0, 1.0);
  if kind < 1 || kind > 3 || k <= 0.0 { return c; }
  // Machado, Oliveira, Fernandes 2009, severity 1.0, linear RGB; each matrix is written by columns (WGSL), so m * v is the row-major product
  var m = mat3x3<f32>(vec3<f32>(0.152286, 0.114503, -0.003882), vec3<f32>(1.052583, 0.786281, -0.048116), vec3<f32>(-0.204868, 0.099216, 1.051998));
  if kind == 2 {
    m = mat3x3<f32>(vec3<f32>(0.367322, 0.280085, -0.011820), vec3<f32>(0.860646, 0.672501, 0.042940), vec3<f32>(-0.227968, 0.047413, 0.968881));
  } else if kind == 3 {
    m = mat3x3<f32>(vec3<f32>(1.255528, -0.078411, 0.004733), vec3<f32>(-0.076749, 0.930809, 0.691367), vec3<f32>(-0.178779, 0.147602, 0.303900));
  }
  let lin = cb_to_linear(c);
  let sim = clamp(m * lin, vec3<f32>(0.0), vec3<f32>(1.0));
  var out = sim;
  if frame.user.z < 0.5 {
    let e = lin - sim;
    if kind == 3 {
      out = vec3<f32>(lin.r + e.r + 0.7 * e.b, lin.g + e.g + 0.7 * e.b, lin.b);
    } else {
      out = vec3<f32>(lin.r, lin.g + 0.7 * e.r + e.g, lin.b + 0.7 * e.r + e.b);
    }
  }
  return cb_to_srgb(clamp(mix(lin, out, k), vec3<f32>(0.0), vec3<f32>(1.0)));
}
"""


comptime AccessPost = ThenPost[History[Stage[FlashLimit]], Stage[ColorBlind]]
