"""Screen-space reflections as a post stage (app/post.mojo), falling back to the environment's reflection.

    var r = SceneRendererOf[DefaultPasses, Ssr, Aux[SurfacePasses]](device, format, view)
    r.set_environment(device, sky_environment(...))   # or an EnvProbe: what a ray that misses keeps
    r.ssr_intensity = 1.0        # 0 (the default) returns the frame unchanged
    r.ssr_max_distance = 20.0    # metres
    r.ssr_thickness = 0.3        # metres behind a surface that still count as a hit
    r.ssr_max_roughness = 0.6    # rougher surfaces keep the environment only

The colour the passes hand over already holds MatPbr's reflection of the environment (the EnvProbe cube map, or the
environment's gradient): `env_reflect(r, rough) * env_brdf(f0, rough, n.v)`. A post stage cannot tell that part from
the rest of the colour, so the aux target carries it (`SurfacePasses`, drawn by the renderer's aux pass):

    r  e / (1 + e), e the luminance of that reflection (fogged as the colour is), in the passes' linear units
    g  the luminance of env_brdf(f0, rough, n.v): how much of whatever is reflected reaches the eye
    b  0
    a  1 + round(rough * 125) + 126 if metallic > 0.5, over 255; 0 where nothing was drawn (the clear colour).
       253 .. 255 never occur, so an aux target of another convention (the normals' a = 1, or the scene's colour with
       NoAux) reads as "no surface data" and the stage returns its input.

Only MatPbr items reflect; every other material writes rough 1 and no reflection.

Per pixel: the reflected ray of the view ray about the surface normal (rebuilt from depth: `normal_at`), from the
pixel's world point to ssr_max_distance (shortened so it stays in front of the near plane), projected to the screen and
walked in 40 steps (perspective-correct depth, the start jittered by a 4 x 4 Bayer offset). The first step whose ray depth
is behind the depth buffer by less than ssr_thickness is refined by 6 halvings. The hit is dropped if the surface there
faces away from the ray. Its weight fades over the outer 8 % of the screen, the last 30 % of the distance, and from
0.7 to 1 times ssr_max_roughness. In the passes' linear units (to_linear):

    out = colour + w * intensity * (tint * hit - e * tint_colour)

with tint = g times (for a metal) the colour's own chromaticity, else grey: the environment's reflection is taken out
and the hit put in. Where the ray misses (w = 0) the frame keeps the environment's reflection: the fallback is what the
mesh pass already drew. The hit's colour is averaged over 5 taps spread by roughness times the ray's length on screen.

Approximations: normals come from depth, so a tessellated sphere reflects with its facets; the environment's colour is
taken as grey when it is removed (its luminance is exact); an orthographic view gets no reflections.
"""
from game.draw_item import MAT_COLOR, MAT_SKY, MAT_PBR
from app.material import Material
from app.mesh_pass import MeshPassOf
from app.gbuffer import MatNothing
from app.post import Stage, Style


struct MatSurfPlain(Material):
    """Every material but MatPbr in the surface target: rough 1, no reflection."""

    comptime NAME: StaticString = "surface, no reflection"
    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  return vec4<f32>(0.0, 0.0, 0.0, 126.0 / 255.0);"""


struct MatSurfPbr(Material):
    """MatPbr's environment reflection, its Fresnel weight, roughness and metallic, packed as app/ssr.mojo says."""

    comptime NAME: StaticString = "surface, reflection"
    comptime ID: Int = MAT_PBR
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let v = normalize(cam.eye.xyz - s.wpos);
  let ndv = max(dot(n, v), 1e-4);
  let f0 = mix(vec3<f32>(0.04), atmo_lin(s.base), s.metal);
  let fr = env_brdf(f0, s.rough, ndv);
  var e = vec3<f32>(0.0);
  if ambient_set() { e = env_reflect(reflect(-v, n), s.rough) * fr; }
  var keep = 1.0;   // the part atmo_fog leaves of the surface's own colour
  if shadow.atmo.x > 0.5 { keep = exp(-length(s.wpos - cam.eye.xyz) * shadow.atmo.y); }
  let w = vec3<f32>(0.299, 0.587, 0.114);
  let el = max(dot(e, w) * keep, 0.0);
  let fl = clamp(dot(fr, w) * keep, 0.0, 1.0);
  let k = 1.0 + round(clamp(s.rough, 0.0, 1.0) * 125.0) + select(0.0, 126.0, s.metal > 0.5);
  return vec4<f32>(el / (1.0 + el), fl, 0.0, k / 255.0);"""


comptime SurfacePasses = MeshPassOf[MatSurfPlain, MatNothing, MatSurfPbr]
"""The aux pass list that SSR reads: `SceneRendererOf[P, F, Aux[SurfacePasses]]`. Meshes only (MeshPassOf): primitives
and skinned meshes leave the clear colour (a = 0) and get no reflection."""


struct SsrStyle(Style):
    comptime NAME: StaticString = "ssr"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// a world point on this frame's screen: uv, and its view depth
fn ssr_proj(w : vec3<f32>) -> vec3<f32> {
  let d = w - frame.eye.xyz;
  let z = dot(d, frame.fwd.xyz);
  let x = dot(d, frame.right.xyz);
  let y = dot(d, frame.up.xyz);
  return vec3<f32>(x * frame.eye.w / z * 0.5 + 0.5, 0.5 - y * frame.right.w / z * 0.5, z);
}
fn ssr_inside(u : vec2<f32>) -> bool { return u.x >= 0.0 && u.x <= 1.0 && u.y >= 0.0 && u.y <= 1.0; }
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_texel(uv);
  if frame.ssr.x <= 0.0 || frame.eye.w < 0.0 { return c; }
  let a = aux_at(uv);
  let code = u32(round(a.a * 255.0));
  if code == 0u || code >= 253u { return c; }
  let metal = code > 126u;
  let rough = f32((code - 1u) % 126u) / 125.0;
  let maxr = frame.ssr.w;
  if rough > maxr || a.g <= 0.0 { return c; }
  let p = world_at(uv);
  let vdir = normalize(p - frame.eye.xyz);
  var n = normal_at(uv);
  if dot(n, vdir) > 0.0 { n = -n; }     // the cross product's sign follows the screen's handedness
  let r = reflect(vdir, n);
  let zp = dot(p - frame.eye.xyz, frame.fwd.xyz);
  var len = frame.ssr.y;
  let rz = dot(r, frame.fwd.xyz);
  if rz < 0.0 { len = min(len, (zp - 2.0 * frame.up.w) / -rz); }
  if len <= 0.0 { return c; }
  let p0 = p + n * (0.002 * zp);
  let s0 = ssr_proj(p0);
  let s1 = ssr_proj(p0 + r * len);
  let steps = 40;
  let jitter = bayer4(px);
  var t_prev = 0.0;
  var t_hit = -1.0;
  for (var i = 1; i <= steps; i++) {
    let t = (f32(i) - 1.0 + jitter) / f32(steps);
    let suv = mix(s0.xy, s1.xy, t);
    if !ssr_inside(suv) { break; }
    let zr = 1.0 / mix(1.0 / s0.z, 1.0 / s1.z, t);
    let zs = view_z(suv);
    if zr > zs && zr - zs < frame.ssr.z {
      t_hit = t;
      break;
    }
    t_prev = t;
  }
  if t_hit < 0.0 { return c; }
  // halve the interval between the last step in front and the first behind
  var lo = t_prev;
  var hi = t_hit;
  for (var k = 0; k < 6; k++) {
    let m = 0.5 * (lo + hi);
    let suv = mix(s0.xy, s1.xy, m);
    let zr = 1.0 / mix(1.0 / s0.z, 1.0 / s1.z, m);
    if zr > view_z(suv) { hi = m; } else { lo = m; }
  }
  let huv = mix(s0.xy, s1.xy, hi);
  var hn = normal_at(huv);
  if dot(hn, vdir) > 0.0 { hn = -hn; }
  if dot(hn, r) > 0.0 { return c; }     // the back of something
  let hit_w = world_at(huv);
  let dist = length(hit_w - p);
  let edge = min(min(huv.x, 1.0 - huv.x), min(huv.y, 1.0 - huv.y));
  var w = smoothstep(0.0, 0.08, edge) * (1.0 - smoothstep(0.7, 1.0, dist / frame.ssr.y));
  w *= 1.0 - smoothstep(0.7 * maxr, maxr, rough);
  // the hit's colour, spread by roughness over the ray's length on screen
  let spread = rough * length((huv - s0.xy) * frame.res.xy) * 0.15;
  let o = spread * frame.res.zw;
  var hit = to_linear(src_at(huv));
  if spread > 0.5 {
    hit = (hit + to_linear(src_at(huv + vec2<f32>(o.x, 0.0))) + to_linear(src_at(huv - vec2<f32>(o.x, 0.0)))
           + to_linear(src_at(huv + vec2<f32>(0.0, o.y))) + to_linear(src_at(huv - vec2<f32>(0.0, o.y)))) / 5.0;
  }
  let lin = to_linear(c);
  var hue = vec3<f32>(1.0);
  if metal { hue = clamp(lin / max(luma(lin), 1e-4), vec3<f32>(0.0), vec3<f32>(4.0)); }
  let ea = min(a.r, 0.996);
  let e = ea / (1.0 - ea);
  let outl = lin + w * frame.ssr.x * (a.g * hue * hit - e * hue);
  return to_display(max(outl, vec3<f32>(0.0)));
}
"""


comptime Ssr = Stage[SsrStyle]
