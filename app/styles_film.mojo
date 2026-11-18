"""Post styles after film and photographic processes (app/post.mojo Style)."""
from app.post import Style


struct Daguerreotype(Style):
    """After 19th-century sepia plates and silent-film prints: one warm tone, a vignette, scratches and dust."""

    comptime NAME: StaticString = "daguerreotype"
    comptime AFTER: StaticString = "19th-century sepia plates and silent-film prints"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let g = pow(luma(blur9(uv, 1.0)), 0.9);
  var c = mix(vec3<f32>(0.10, 0.06, 0.03), vec3<f32>(0.98, 0.90, 0.72), g);
  let scratch = step(0.997, hash21(vec2<f32>(floor(px.x), frame.t.z + 3.0))) * step(0.3, vnoise(vec2<f32>(px.x, px.y * 0.01)));
  let dust = step(0.9992, hash21(floor(px / 2.0) + frame.t.z));
  c = c * (0.9 + 0.2 * vnoise(px * 0.7)) + scratch * 0.25 - dust * 0.4;
  return c * vignette(uv, 2.2);
}
"""


struct FilmNoir(Style):
    """Black and white with nothing in the middle: hard contrast, grain, and the light cut into bars as if through a
    window blind (planes in the scene's world space, so the bars bend over the forms)."""

    comptime NAME: StaticString = "film_noir"
    comptime AFTER: StaticString = "1940s Hollywood film noir cinematography"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let w = world_at(uv);
  let far = is_far(uv, 60.0);
  let slat = smoothstep(0.38, 0.62, abs(fract((w.y + w.z * 0.55 + w.x * 0.3) * 0.5) - 0.5) * 2.0);
  var l = luma(src_at(uv)) * mix(mix(0.38, 1.0, slat), 0.5, far);
  l = smoothstep(0.16, 0.74, l);
  l += (hash21(px + frame.t.z) - 0.5) * 0.16;
  return vec3<f32>(l) * vignette(uv, 1.9);
}
"""


struct TwoStrip(Style):
    """Two colour records instead of three: orange-red and blue-green. Blues and yellows have no ink of their own."""

    comptime NAME: StaticString = "two_strip"
    comptime AFTER: StaticString = "two-strip Technicolor (Process 2, 1920s)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = mix(src_at(uv), blur9(uv, 2.5), 0.35);
  let cyan_record = dot(c.gb, vec2<f32>(0.6, 0.4));
  var o = c.r * vec3<f32>(1.0, 0.33, 0.16) + cyan_record * vec3<f32>(0.0, 0.70, 0.62);
  o = smoothstep(vec3<f32>(0.03), vec3<f32>(0.97), o);
  o *= 0.96 + 0.05 * hash21(vec2<f32>(frame.t.y, 2.0));
  o += (hash21(px * 0.5 + frame.t.z) - 0.5) * 0.06;
  return o * vignette(uv, 0.8);
}
"""


struct Vhs(Style):
    """A worn tape: soft brightness, colour smeared and late by a few pixels, lines that do not start in the same
    place, white dropouts, and the band at the bottom where the heads switch."""

    comptime NAME: StaticString = "vhs"
    comptime AFTER: StaticString = "VHS tape played on a consumer deck"
    comptime WGSL: StaticString = """
fn vy(c : vec3<f32>) -> vec3<f32> {
  return vec3<f32>(dot(c, vec3<f32>(0.299, 0.587, 0.114)), dot(c, vec3<f32>(0.596, -0.274, -0.322)), dot(c, vec3<f32>(0.211, -0.523, 0.312)));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let row = floor(px.y / 2.0);
  var jit = (hash21(vec2<f32>(row, frame.t.y)) - 0.5) * 2.0 * frame.res.z;
  let band = smoothstep(0.94, 1.0, uv.y);
  jit += band * (0.04 + 0.02 * sin(px.y * 1.3));
  jit += step(0.975, hash21(vec2<f32>(floor(px.y / 11.0), 5.0 + frame.t.z))) * 0.014;
  let u = vec2<f32>(uv.x + jit, uv.y);
  let e = vec2<f32>(frame.res.z, 0.0);
  var y = 0.0;
  for (var i = -2; i <= 2; i++) { y += vy(src_at(u + e * f32(i))).x; }
  y /= 5.0;
  var iq = vec2<f32>(0.0);
  for (var i = 0; i < 9; i++) { iq += vy(src_at(u - e * (4.0 + f32(i) * 2.0))).yz; }
  iq = iq / 9.0 * 0.85;
  var o = vec3<f32>(y + 0.956 * iq.x + 0.621 * iq.y, y - 0.272 * iq.x - 0.647 * iq.y, y - 1.106 * iq.x + 1.703 * iq.y);
  o = o * 0.88 + 0.05;
  o += step(0.9975, hash21(vec2<f32>(floor(px.x / 26.0), row + frame.t.z))) * 0.55;
  o += band * (hash21(px + 1.0) - 0.3) * 0.5;
  o += (hash21(px + frame.t.y * 3.0) - 0.5) * 0.05;
  return o;
}
"""


struct Anaglyph(Style):
    """A stereo pair from the one frame: each eye's view is the frame shifted sideways by its depth (zero shift at
    9 m), the left eye printed in red, the right in cyan."""

    comptime NAME: StaticString = "anaglyph"
    comptime AFTER: StaticString = "red-cyan anaglyph 3-D films of the 1950s"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = clamp(0.024 * (1.0 - 9.0 / view_z(uv)), -0.04, 0.024);
  let l = luma(src_at(uv + vec2<f32>(d, 0.0)));
  let r = src_at(uv - vec2<f32>(d, 0.0));
  return vec3<f32>(l, mix(luma(r), r.g, 0.6), mix(luma(r), r.b, 0.6));
}
"""


struct Aerochrome(Style):
    """False colour: infrared is shown as red, red as green, green as blue. Infrared is guessed from how green a
    surface is, since foliage is what reflects it; green things come out pink to crimson."""

    comptime NAME: StaticString = "aerochrome"
    comptime AFTER: StaticString = "Kodak Aerochrome colour infrared film"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let ir = clamp(2.6 * c.g - 1.1 * c.b - 0.7 * c.r + 0.15, 0.0, 1.0);
  var o = vec3<f32>(ir, c.r * 0.85, c.g * 0.8);
  o = smoothstep(vec3<f32>(0.05), vec3<f32>(0.95), o);
  o += (hash21(px + frame.t.z) - 0.5) * 0.05;
  return o * vignette(uv, 0.7);
}
"""


struct TiltShift(Style):
    """A thin slice of the scene in focus (around 9 m) and everything nearer or farther blurred in proportion, with
    the colours pushed: the scene reads as a table-top model."""

    comptime NAME: StaticString = "tilt_shift"
    comptime AFTER: StaticString = "tilt-shift miniature-faking photography"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let coc = clamp(abs(view_z(uv) - 9.0) * 1.5 - 0.6, 0.0, 8.0);
  var c = vec3<f32>(0.0);
  for (var i = 0; i < 24; i++) {
    let a = f32(i) * 2.39996;
    let r = sqrt((f32(i) + 0.5) / 24.0) * coc;
    c += src_at(uv + vec2<f32>(cos(a), sin(a)) * r * frame.res.zw);
  }
  c /= 24.0;
  let g = luma(c);
  c = mix(vec3<f32>(g), c, 1.6);
  return smoothstep(vec3<f32>(0.04), vec3<f32>(0.96), c);
}
"""


struct AnamorphicGrade(Style):
    """Third stage after BrightPass and StreakH: the scene graded teal in the shadows and orange in the lights, the
    highlights' horizontal streaks added in blue, a 2.39 : 1 letterbox."""

    comptime NAME: StaticString = "anamorphic"
    comptime AFTER: StaticString = "anamorphic-lens blockbuster cinematography with a teal-and-orange grade"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let bar = (frame.res.y - frame.res.x / 2.39) * 0.5;
  if px.y < bar || px.y > frame.res.y - bar { return vec3<f32>(0.0); }
  var c = scene_at(uv);
  let l = luma(c);
  c = mix(c * vec3<f32>(0.62, 0.98, 1.12), c * vec3<f32>(1.2, 1.0, 0.74), smoothstep(0.3, 0.75, l));
  c = smoothstep(vec3<f32>(0.06), vec3<f32>(1.0), c);
  c += src_at(uv) * vec3<f32>(0.45, 0.75, 1.6) * 1.1;
  let d = (uv - 0.5) * vec2<f32>(1.0, 1.6);
  return c * clamp(1.0 - 1.1 * dot(d, d), 0.0, 1.0);
}
"""


struct InstantPrint(Style):
    """A square picture on a white card with a deep bottom margin: lifted blacks, a warm cast in the lights and a
    green-blue one in the shadows, low contrast, soft."""

    comptime NAME: StaticString = "instant_print"
    comptime AFTER: StaticString = "Polaroid SX-70 instant prints"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let side = frame.res.y * 0.74;
  let top = frame.res.y * 0.06;
  let cx = frame.res.x * 0.5;
  let margin = frame.res.y * 0.055;
  let q = vec2<f32>((px.x - cx) / side, (px.y - top) / side);
  if abs(px.x - cx) > side * 0.5 + margin {
    return vec3<f32>(0.20, 0.17, 0.15) * (0.8 + 0.4 * fbm(vec2<f32>(px.x * 0.01, px.y * 0.2)));
  }
  if abs(q.x) > 0.5 || q.y < 0.0 || q.y > 1.0 {
    let lip = smoothstep(0.0, 0.012, max(abs(q.x) - 0.5, max(-q.y, q.y - 1.0)));
    return vec3<f32>(0.95, 0.94, 0.90) * (0.9 + 0.1 * lip) * (0.98 + 0.03 * vnoise(px * 0.6));
  }
  let u = vec2<f32>(0.5 + q.x * frame.res.y / frame.res.x * 1.15, 0.1 + q.y * 0.9);
  var c = blur9(u, 1.2);
  let l = luma(c);
  c = mix(c * vec3<f32>(0.85, 1.02, 1.05), c * vec3<f32>(1.08, 1.0, 0.84), smoothstep(0.2, 0.8, l));
  c = c * 0.78 + vec3<f32>(0.10, 0.10, 0.12);
  let d = q - vec2<f32>(0.0, 0.5);
  return c * (1.0 - 0.7 * dot(d, d));
}
"""


struct NightVision(Style):
    """One round green tube: the dark amplified, the brightest parts washed out toward white, noise that changes
    every frame."""

    comptime NAME: StaticString = "night_vision"
    comptime AFTER: StaticString = "image-intensifier night-vision goggles"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let r = length((uv - 0.5) * vec2<f32>(frame.res.x / frame.res.y, 1.0));
  let l = luma(blur9(uv, 1.2));
  let gain = pow(l, 0.55) * 1.15 - 0.15;
  let noise = (hash21(floor(px / 1.5) + frame.t.y * 17.0) - 0.4) * 0.3;
  let v = clamp(gain + noise, 0.0, 1.3);
  var o = vec3<f32>(0.12, 1.0, 0.22) * v + vec3<f32>(pow(v, 5.0) * 0.5);
  o *= 0.9 + 0.1 * sin(px.y * 3.14159);
  return o * smoothstep(0.5, 0.46, r) * (1.0 - 0.9 * r * r);
}
"""


struct Ironbow(Style):
    """The post stage of the thermal pipeline: the passes drew temperature as grey (the material `MatHeat`); this
    maps it through the ironbow palette on a 320 x 180 sensor grid, with the camera's scale bar and centre mark."""

    comptime NAME: StaticString = "thermal"
    comptime AFTER: StaticString = "handheld thermal-imaging cameras (ironbow palette)"
    comptime WGSL: StaticString = """
fn ironbow(t : f32) -> vec3<f32> {
  var c = mix(vec3<f32>(0.0, 0.0, 0.03), vec3<f32>(0.30, 0.0, 0.52), smoothstep(0.0, 0.22, t));
  c = mix(c, vec3<f32>(0.86, 0.10, 0.36), smoothstep(0.22, 0.46, t));
  c = mix(c, vec3<f32>(1.0, 0.55, 0.0), smoothstep(0.46, 0.70, t));
  c = mix(c, vec3<f32>(1.0, 0.95, 0.30), smoothstep(0.70, 0.90, t));
  return mix(c, vec3<f32>(1.0), smoothstep(0.90, 1.0, t));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let cell = vec2<f32>(frame.res.y / 180.0);
  let cu = cell_uv(px, cell);
  var o = ironbow(blur9(cu, 1.5).r);
  if uv.x > 0.952 && uv.x < 0.976 && uv.y > 0.15 && uv.y < 0.85 {
    o = ironbow(1.0 - (uv.y - 0.15) / 0.7);
    if uv.x < 0.955 || uv.x > 0.973 || uv.y < 0.156 || uv.y > 0.844 { o = vec3<f32>(1.0); }
  }
  let d = abs(px - frame.res.xy * 0.5);
  if (d.x < 1.0 && d.y > 4.0 && d.y < 14.0) || (d.y < 1.0 && d.x > 4.0 && d.x < 14.0) { o = vec3<f32>(1.0); }
  return o;
}
"""


struct XrayFilm(Style):
    """The post stage of the radiograph pipeline: the passes drew how edge-on each surface is to the eye (the
    material `MatXray`); this develops it as a blue-white negative with a soft glow and grain."""

    comptime NAME: StaticString = "radiograph"
    comptime AFTER: StaticString = "X-ray film radiographs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let v = src_at(uv).r + 0.5 * blur9(uv, 4.0).r + 0.3 * edge(uv, 1.0);
  var o = mix(vec3<f32>(0.01, 0.02, 0.05), vec3<f32>(0.80, 0.92, 1.0), pow(clamp(v * 0.9, 0.0, 1.0), 0.8));
  o += (hash21(px + frame.t.z) - 0.5) * 0.06;
  return o * vignette(uv, 1.2);
}
"""
