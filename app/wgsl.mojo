"""WGSL shared by the mesh, skinned and shadow passes (plan 2.3). Each pass's shader concatenates the pieces it uses;
the binding declarations stay in each shader, because the binding numbers differ per pass.

  CAM_WGSL         the camera header (`Cam`, binding 0 in both colour passes) and `cam_clip`, its projection
  SHADOW_UBO_WGSL  the `Shadow` uniform's layout: the light's view-projection, the shadow on-flag and the atmosphere
  PCF_WGSL         `shadow_factor`: the 3 x 3 percentage-closer lookup; needs `shadow_map` and `shadow_cmp` declared
  LIGHT_WGSL       the shadow pass's `light` uniform (binding 0): the light's view-projection
"""

comptime CAM_WGSL = """
struct Cam { eye : vec4<f32>, right : vec4<f32>, up : vec4<f32>, fwd : vec4<f32> };
@group(0) @binding(0) var<uniform> cam : Cam;
// clip position of a world point: eye.w = sx, right.w = sy, up.w = near, fwd.w = far (app/gpu_mesh.mojo cam_floats)
fn cam_clip(world : vec3<f32>) -> vec4<f32> {
  let d = world - cam.eye.xyz;
  let x = dot(d, cam.right.xyz);
  let y = dot(d, cam.up.xyz);
  let z = dot(d, cam.fwd.xyz);
  let near = cam.up.w;
  let far = cam.fwd.w;
  if cam.eye.w < 0.0 {  // a parallel projection (View.orthographic)
    return vec4<f32>(-x * cam.eye.w, y * cam.right.w, (z - near) / (far - near), 1.0);
  }
  return vec4<f32>(x * cam.eye.w, y * cam.right.w, far * (z - near) / (far - near), z);
}
"""

comptime SHADOW_UBO_WGSL = """
// shadow: the light's view-projection (orthographic, z in [0, 1]); params.x 1 turns the shadow factor on. sky_top, sky_hor
// and atmo are the atmosphere (app/textures.mojo ATMO_WGSL), all zero (off) until set_atmosphere.
struct Shadow { vp : mat4x4<f32>, params : vec4<f32>, sky_top : vec4<f32>, sky_hor : vec4<f32>, atmo : vec4<f32> };
"""

comptime PCF_WGSL = """
// p: the light-space position of a world point: NDC xy in [-1, 1], z in [0, 1]
fn shadow_factor(p : vec3<f32>, ndl : f32) -> f32 {
  // uv: NDC +y is the top row of the depth texture
  let uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  // a constant bias scaled by (1 - N.L) against acne on the faces turned from the light
  let ref_z = p.z - 0.003 * (1.0 - ndl);
  let texel = 1.0 / vec2<f32>(textureDimensions(shadow_map));
  // 3x3 percentage-closer filter; every tap is uniform control flow, so textureSampleCompareLevel is valid
  var acc = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      acc += textureSampleCompareLevel(shadow_map, shadow_cmp, uv + vec2<f32>(f32(i), f32(j)) * texel, ref_z);
    }
  }
  let inside = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 && p.z <= 1.0;
  return select(1.0, acc / 9.0, inside);
}
"""

comptime LIGHT_WGSL = """
struct Light {
  vp : mat4x4<f32>,
}
@group(0) @binding(0) var<uniform> light : Light;
"""

# The lights (issue #90 step 3 and app/lights.mojo). `lights` is declared by each shader at its own binding
# (RenderResources.lights); the layout is app/lights.mojo's (L_* offsets). Three states:
#   nothing set     the shaders use their per-vertex colour unchanged: the frame is the one from before lights existed
#   point lights    per pixel, added to the per-vertex sun term (the first form of this file)
#   a light rig     any of: a sun of the host's (set_sun), an ambient / environment (set_ambient, set_environment),
#                   spot, directional or area lights. Then `rig()` computes the light per pixel.
# A shader that includes this declares `local_shadow` (LOCAL_SHADOW_WGSL with the atlas bound, or NO_LOCAL_SHADOW_WGSL).
comptime POINT_LIGHTS_WGSL = """
struct PointLight { pos_range : vec4<f32>, color : vec4<f32> };
struct SpotLight { pos_range : vec4<f32>, color : vec4<f32>, dir_cos : vec4<f32>, cone : vec4<f32> };
struct DirLight { dir : vec4<f32>, color : vec4<f32> };
struct AreaLight { pos : vec4<f32>, ex : vec4<f32>, ey : vec4<f32>, color : vec4<f32> };
struct Lights {
  n : vec4<f32>,                    // counts: point, spot, directional, area
  l : array<PointLight, 16>,
  sun_dir : vec4<f32>,              // xyz toward the sun; w 1 when the host set it (set_sun)
  sun_color : vec4<f32>,            // rgb times intensity (0.6 white until set)
  amb : vec4<f32>,                  // w 1: the ambient is `sh` (set_ambient / set_environment), not the fixed 0.4
  sh : array<vec4<f32>, 9>,         // the environment's radiance, order-2 spherical harmonics (rgb)
  env_top : vec4<f32>,              // the environment for reflections: zenith, horizon, nadir (rgb)
  env_hor : vec4<f32>,
  env_gnd : vec4<f32>,
  pshadow : array<vec4<f32>, 4>,    // per point light: its first atlas tile + 1 (six tiles), 0 for no shadow
  spots : array<SpotLight, 8>,      // cone.x cos(inner), dir_cos.w cos(outer), cone.y atlas tile + 1 or 0
  dirs : array<DirLight, 4>,        // dir.w atlas tile + 1 or 0
  areas : array<AreaLight, 4>,      // a rectangle: centre, two half-edge vectors; it emits toward cross(ex, ey).
                                    // pos.w atlas tile + 1 or 0, ex.w the shadow view's far distance, ey.w its size
  tiles : array<mat4x4<f32>, 16>,   // the atlas tiles' view-projections
};
const L_PI = 3.14159265;
fn falloff(dist : f32, range : f32) -> f32 {
  let x = clamp(1.0 - (dist / range) * (dist / range), 0.0, 1.0);
  return x * x;
}
// the shadow of point light i at a world point: the cube face the point lies in
fn point_shadow(i : u32, wpos : vec3<f32>, nrm : vec3<f32>) -> f32 {
  let base = lights.pshadow[i / 4u][i % 4u];
  if base < 0.5 { return 1.0; }
  let d = wpos - lights.l[i].pos_range.xyz;
  let a = abs(d);
  var face = 0.0;
  if a.x >= a.y && a.x >= a.z { face = select(1.0, 0.0, d.x > 0.0); }
  else if a.y >= a.z { face = select(3.0, 2.0, d.y > 0.0); }
  else { face = select(5.0, 4.0, d.z > 0.0); }
  return local_shadow(base + face, wpos, nrm, length(d));
}
// the point lights' diffuse term at a world point with unit normal nrm: colour * intensity * N.L * (1 - (d / r)^2)^2
fn point_lights(wpos : vec3<f32>, nrm : vec3<f32>) -> vec3<f32> {
  var sum = vec3<f32>(0.0);
  let count = min(u32(lights.n.x), 16u);
  for (var i = 0u; i < count; i++) {
    let d = lights.l[i].pos_range.xyz - wpos;
    let dist = max(length(d), 1e-4);
    let x = clamp(1.0 - (dist / lights.l[i].pos_range.w) * (dist / lights.l[i].pos_range.w), 0.0, 1.0);
    sum += lights.l[i].color.rgb * lights.l[i].color.w * max(dot(nrm, d / dist), 0.0) * x * x * point_shadow(i, wpos, nrm);
  }
  return sum;
}
fn has_point_lights() -> bool {
  return lights.n.x > 0.5;
}
fn sun_custom() -> bool { return lights.sun_dir.w > 0.5; }
fn ambient_set() -> bool { return lights.amb.w > 0.5; }
// true when the light must be computed per pixel by rig()
fn rig_on() -> bool {
  return lights.n.y + lights.n.z + lights.n.w > 0.5 || sun_custom() || ambient_set();
}
fn sun_dir() -> vec3<f32> {
  if sun_custom() { return lights.sun_dir.xyz; }
  return normalize(vec3<f32>(0.4, 1.0, 0.6));
}
// the environment's irradiance over pi on a surface facing n (Ramamoorthi and Hanrahan 2001): a white matte surface
// under a uniform environment of radiance c reflects c
fn sh_lit(n : vec3<f32>) -> vec3<f32> {
  let e = 0.429043 * lights.sh[8].rgb * (n.x * n.x - n.y * n.y) + 0.743125 * lights.sh[6].rgb * n.z * n.z
        + 0.886227 * lights.sh[0].rgb - 0.247708 * lights.sh[6].rgb
        + 2.0 * 0.429043 * (lights.sh[4].rgb * n.x * n.y + lights.sh[7].rgb * n.x * n.z + lights.sh[5].rgb * n.y * n.z)
        + 2.0 * 0.511664 * (lights.sh[3].rgb * n.x + lights.sh[1].rgb * n.y + lights.sh[2].rgb * n.z);
  return max(e, vec3<f32>(0.0)) / L_PI;
}
// the environment seen along r by a surface of this roughness: the gradient for a mirror, the irradiance for a matte one
fn env_radiance(r : vec3<f32>, rough : f32) -> vec3<f32> {
  let up = pow(clamp(r.y, 0.0, 1.0), 0.5);
  let down = pow(clamp(-r.y, 0.0, 1.0), 0.5);
  let sky = mix(mix(lights.env_hor.rgb, lights.env_top.rgb, up), lights.env_gnd.rgb, down);
  return mix(sky, sh_lit(r), clamp(rough, 0.0, 1.0));
}
// the split-sum environment BRDF, Karis's analytic fit (Unreal Engine 4 on mobile, 2014)
fn env_brdf(f0 : vec3<f32>, rough : f32, ndv : f32) -> vec3<f32> {
  let r = rough * vec4<f32>(-1.0, -0.0275, -0.572, 0.022) + vec4<f32>(1.0, 0.0425, 1.04, -0.04);
  let a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
  let ab = vec2<f32>(-1.04, 1.04) * a004 + r.zw;
  return f0 * ab.x + ab.y;
}
// One light sample: the unit direction to it and what arrives from it (before N.L), in the units of the lit term.
struct LSample { l : vec3<f32>, e : vec3<f32> };
const AREA_TAPS = 9u;
fn extra_count() -> u32 {
  return min(u32(lights.n.y), 8u) + min(u32(lights.n.z), 4u);
}
// the shadow of a directional light: its tile is a parallel view, whose scale gives the size of a texel
fn dir_shadow(tile1 : f32, wpos : vec3<f32>, nrm : vec3<f32>) -> f32 {
  if tile1 < 0.5 { return 1.0; }
  let m = lights.tiles[u32(tile1) - 1u];
  let half = 1.0 / max(length(vec3<f32>(m[0][0], m[1][0], m[2][0])), 1e-6);
  return local_shadow(tile1, wpos, nrm, half * 0.5);
}
// sample k of the spot and directional lights
fn extra_sample(k : u32, wpos : vec3<f32>, nrm : vec3<f32>) -> LSample {
  let ns = min(u32(lights.n.y), 8u);
  if k < ns {
    let s = lights.spots[k];
    let d = s.pos_range.xyz - wpos;
    let dist = max(length(d), 1e-4);
    let l = d / dist;
    let cone = smoothstep(s.dir_cos.w, s.cone.x, dot(-l, s.dir_cos.xyz));
    var e = s.color.rgb * s.color.w * falloff(dist, s.pos_range.w) * cone;
    if cone > 0.0 { e *= local_shadow(s.cone.y, wpos, nrm, dist); }
    return LSample(l, e);
  }
  let dl = lights.dirs[k - ns];
  return LSample(dl.dir.xyz, dl.color.rgb * dl.color.w * dir_shadow(dl.dir.w, wpos, nrm));
}
fn area_count() -> u32 { return min(u32(lights.n.w), 4u); }
// how much of area light j reaches a point (1 without a shadow): app/wgsl.mojo LOCAL_SHADOW_WGSL area_shadow
fn area_light_shadow(j : u32, wpos : vec3<f32>, nrm : vec3<f32>) -> f32 {
  let a = lights.areas[j];
  return area_shadow(a.pos.w, a.ey.w, a.ex.w, wpos, nrm);
}
// tap t (0 .. AREA_TAPS - 1) of area light j: the 3 x 3 Gauss-Legendre points of the rectangle, each a patch of its
// area (by the point's weight) that emits by the cosine of its normal:
// e = colour * intensity * cos(at the light) * patch area / (pi d^2), so the sum times N.L is colour * intensity times
// the rectangle's form factor (within 0.5 % from one panel width away, 6 % at half a width, too dark nearer;
// tests/lights_native.mojo).
fn area_tap(j : u32, t : u32, wpos : vec3<f32>) -> LSample {
  let a = lights.areas[j];
  let ti = t % 3u;
  let tj = t / 3u;
  let w = select(0.55555556, 0.88888889, ti == 1u) * select(0.55555556, 0.88888889, tj == 1u);  // sums to 4
  let p = a.pos.xyz + a.ex.xyz * (f32(ti) - 1.0) * 0.77459667 + a.ey.xyz * (f32(tj) - 1.0) * 0.77459667;
  let d = p - wpos;
  let d2 = max(dot(d, d), 1e-6);
  let l = d / sqrt(d2);
  let c = cross(a.ex.xyz, a.ey.xyz);
  let quarter = length(c);   // |ex| |ey|: a quarter of the rectangle
  let cl = max(dot(-l, c / max(quarter, 1e-9)), 0.0);
  // a patch closer than its own size would send more than everything it emits: its factor is capped at its share
  return LSample(l, a.color.rgb * a.color.w * min(cl * w * quarter / (L_PI * d2), w * 0.25));
}
// Rig.lit is the light a material multiplies by the sun's shadow factor (the sun, and what the first form put with it:
// the fixed 0.4 ambient and the point lights); Rig.extra is light the sun's shadow does not touch.
struct Rig { lit : vec3<f32>, extra : vec3<f32> };
fn rig(vlit : f32, wpos : vec3<f32>, n : vec3<f32>) -> Rig {
  var lit = vec3<f32>(vlit);
  var extra = vec3<f32>(0.0);
  if ambient_set() {
    lit = lights.sun_color.rgb * max(dot(n, sun_dir()), 0.0);
    extra = sh_lit(n) + point_lights(wpos, n);
  } else {
    if sun_custom() { lit = vec3<f32>(0.4) + lights.sun_color.rgb * max(dot(n, sun_dir()), 0.0); }
    lit += point_lights(wpos, n);
  }
  let count = extra_count();
  for (var k = 0u; k < count; k++) {
    let s = extra_sample(k, wpos, n);
    extra += s.e * max(dot(n, s.l), 0.0);
  }
  let na = area_count();
  for (var j = 0u; j < na; j++) {
    let sh = area_light_shadow(j, wpos, n);
    for (var t = 0u; t < AREA_TAPS; t++) {
      let s = area_tap(j, t, wpos);
      extra += s.e * max(dot(n, s.l), 0.0) * sh;
    }
  }
  return Rig(lit, extra);
}
"""

# The spot and point lights' shadows: a depth atlas of 4 x 4 tiles, one view per tile (lights.tiles). `tile1` is the
# tile + 1 (0: the light casts none). The lookup is at the point moved along its normal by a length that grows with the
# distance to the light (a texel of the tile covers more there), then a 3 x 3 percentage-closer filter inside the tile.
comptime LOCAL_SHADOW_WGSL = """
fn local_shadow(tile1 : f32, wpos : vec3<f32>, nrm : vec3<f32>, dist : f32) -> f32 {
  if tile1 < 0.5 { return 1.0; }
  let t = u32(tile1) - 1u;
  let c = lights.tiles[t] * vec4<f32>(wpos + nrm * (0.02 + 0.012 * dist), 1.0);
  if c.w <= 0.0 { return 1.0; }
  let p = c.xyz / c.w;
  if abs(p.x) > 1.0 || abs(p.y) > 1.0 || p.z > 1.0 { return 1.0; }
  let size = vec2<f32>(textureDimensions(atlas_map));
  let org = vec2<f32>(f32(t % 4u), f32(t / 4u)) * 0.25;
  let half_texel = 0.5 / size;
  let lo = org + half_texel;
  let hi = org + vec2<f32>(0.25) - half_texel;
  let uv = org + vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) * 0.25;
  var acc = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      acc += textureSampleCompareLevel(atlas_map, shadow_cmp, clamp(uv + vec2<f32>(f32(i), f32(j)) / size, lo, hi), p.z);
    }
  }
  return acc / 9.0;
}

// An area light's shadow, soft by the light's size (percentage-closer soft shadows, Fernando 2005): one view from the
// panel's centre along its normal. The blockers between the panel and the point are averaged over the part of the
// view the panel's size covers; the penumbra at the point is size * (receiver - blocker) / blocker wide (similar
// triangles), and that width is filtered with 25 depth comparisons.
fn area_depth(px : vec2<f32>, lo : vec2<f32>, hi : vec2<f32>, far : f32) -> f32 {
  let d = textureLoad(atlas_map, vec2<i32>(clamp(px, lo, hi)), 0);
  return 0.05 * far / (far - d * (far - 0.05));
}
fn area_shadow(tile1 : f32, size : f32, far : f32, wpos : vec3<f32>, nrm : vec3<f32>) -> f32 {
  if tile1 < 0.5 { return 1.0; }
  let t = u32(tile1) - 1u;
  let m = lights.tiles[t];
  let c = m * vec4<f32>(wpos + nrm * 0.04, 1.0);
  if c.w <= 0.06 { return 1.0; }
  let p = c.xyz / c.w;
  if abs(p.x) > 1.0 || abs(p.y) > 1.0 || p.z > 1.0 { return 1.0; }
  let tile_px = f32(textureDimensions(atlas_map).x) * 0.25;
  let org = vec2<f32>(f32(t % 4u), f32(t / 4u)) * tile_px;
  let lo = org + vec2<f32>(0.5);
  let hi = org + vec2<f32>(tile_px - 0.5);
  let q = org + vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) * tile_px;
  let zr = c.w;
  let px_per_m = tile_px * 0.5 * length(vec3<f32>(m[0][0], m[1][0], m[2][0])) / zr;   // at the receiver's depth
  let search = clamp(size * 0.5 * px_per_m, 1.0, 48.0);
  var zb = 0.0;
  var nb = 0.0;
  for (var j = 0; j < 5; j++) {
    for (var i = 0; i < 5; i++) {
      let z = area_depth(q + (vec2<f32>(f32(i), f32(j)) * 0.5 - 1.0) * search, lo, hi, far);
      if z < zr - 0.06 { zb += z; nb += 1.0; }
    }
  }
  if nb < 0.5 { return 1.0; }
  zb /= nb;
  let pen = clamp(size * (zr - zb) / zb * 0.5 * px_per_m, 1.0, 64.0);
  var lit = 0.0;
  for (var j = 0; j < 5; j++) {
    for (var i = 0; i < 5; i++) {
      let z = area_depth(q + (vec2<f32>(f32(i), f32(j)) * 0.5 - 1.0) * pen, lo, hi, far);
      lit += step(zr - 0.06, z);
    }
  }
  return lit / 25.0;
}
"""

comptime NO_LOCAL_SHADOW_WGSL = """
fn local_shadow(tile1 : f32, wpos : vec3<f32>, nrm : vec3<f32>, dist : f32) -> f32 { return 1.0; }
fn area_shadow(tile1 : f32, size : f32, far : f32, wpos : vec3<f32>, nrm : vec3<f32>) -> f32 { return 1.0; }
"""
