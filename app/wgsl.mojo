"""WGSL shared by the mesh, skinned and shadow passes (plan 2.3). Each pass's shader concatenates the pieces it uses;
the binding declarations stay in each shader, because the binding numbers differ per pass.

  CAM_WGSL         the camera header (`Cam`, binding 0 in both colour passes) and `cam_clip`, its projection
  SHADOW_UBO_WGSL  the `Shadow` uniform's layout: the light's view-projection, the shadow on-flag and the atmosphere
  PCF_WGSL         `cascade_pcf`: the 3 x 3 percentage-closer lookup in one cascade; needs `shadow_map`, `shadow_cmp`,
                   `shadow`; `shadow_at`: the sun's shadow at a world point (cascade by view depth, blended, normal
                   offset; also needs `cam`); `shadow_factor`: cascade 0 at a light-space position
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
// shadow: the sun's shadow. vp is cascade 0's view-projection (orthographic, z in [0, 1]); params.x 1 turns the shadow factor
// on, params.y the number of cascades (1 for a fixed box, set_shadow), params.z the share of a cascade's depth range over
// which it blends into the next. sky_top, sky_hor and atmo are the atmosphere (app/textures.mojo ATMO_WGSL), all zero (off)
// until set_atmosphere. casc: each cascade's view-projection; split: the view depth where cascade i ends; bias: its depth
// bias (NDC); info.x the share of the map's width one cascade takes (1, or 0.5 for a 2 x 2 map), info.y a cascade's
// texels across. Cascade i is the square (i % 2, i / 2) of the map.
struct Shadow {
  vp : mat4x4<f32>, params : vec4<f32>, sky_top : vec4<f32>, sky_hor : vec4<f32>, atmo : vec4<f32>,
  casc : array<mat4x4<f32>, 4>, split : vec4<f32>, bias : vec4<f32>, info : vec4<f32>,
};
fn cascade_count() -> u32 { return clamp(u32(shadow.params.y), 1u, 4u); }
// the cascade a point at view depth vz reads: the first whose range reaches past it; cascade_count() beyond the last
fn cascade_for(vz : f32) -> u32 {
  let n = cascade_count();
  for (var i = 0u; i < n; i++) {
    if vz < shadow.split[i] { return i; }
  }
  return n;
}
// where a world point falls in cascade i: xy its uv in the whole map, z its depth; w 1 inside the cascade, 0 outside
fn cascade_uv(i : u32, w : vec3<f32>) -> vec4<f32> {
  let c = shadow.casc[i] * vec4<f32>(w, 1.0);
  let p = c.xyz / c.w;
  let local = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  let inside = local.x >= 0.0 && local.x <= 1.0 && local.y >= 0.0 && local.y <= 1.0 && p.z <= 1.0;
  let org = vec2<f32>(f32(i % 2u), f32(i / 2u)) * shadow.info.x;
  return vec4<f32>(org + local * shadow.info.x, p.z, select(0.0, 1.0, inside));
}
"""

comptime PCF_WGSL = """
// cascade i at a light-space position p (NDC xy in [-1, 1], z in [0, 1]): a 3 x 3 percentage-closer filter inside the
// cascade's square of the map
fn cascade_pcf(i : u32, p : vec3<f32>, ndl : f32) -> f32 {
  let local = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  let s = shadow.info.x;
  let org = vec2<f32>(f32(i % 2u), f32(i / 2u)) * s;
  let uv = org + local * s;
  // a constant bias scaled by (1 - N.L) against acne on the faces turned from the light
  let ref_z = p.z - shadow.bias[i] * (1.0 - ndl);
  let texel = 1.0 / vec2<f32>(textureDimensions(shadow_map));
  let lo = org + texel * 0.5;
  let hi = org + vec2<f32>(s) - texel * 0.5;
  // every tap is a comparison at level 0, valid in non-uniform control flow
  var acc = 0.0;
  for (var j = -1; j <= 1; j++) {
    for (var k = -1; k <= 1; k++) {
      acc += textureSampleCompareLevel(shadow_map, shadow_cmp, clamp(uv + vec2<f32>(f32(k), f32(j)) * texel, lo, hi), ref_z);
    }
  }
  let inside = local.x >= 0.0 && local.x <= 1.0 && local.y >= 0.0 && local.y <= 1.0 && p.z <= 1.0;
  return select(1.0, acc / 9.0, inside);
}

// the first cascade's lookup at a light-space position (the form before cascades; a fixed box has only that one)
fn shadow_factor(p : vec3<f32>, ndl : f32) -> f32 {
  return cascade_pcf(0u, p, ndl);
}

// cascade i at a world point, moved along its normal before the lookup (normal offset): by one texel of the cascade, up to
// three where the surface turns from the sun. Without it a curved or faceted surface lit head-on (N.L near 1, where the
// depth bias is near 0) shadows itself in stripes and rings (acne).
fn cascade_at(i : u32, wpos : vec3<f32>, n : vec3<f32>, ndl : f32) -> f32 {
  let m = shadow.casc[i];
  // the world size of one texel: the orthographic projection's x scale is 1 / half extent
  let sx = length(vec3<f32>(m[0].x, m[1].x, m[2].x));
  let texel = 2.0 / (max(sx, 1e-6) * shadow.info.y);
  let lp = m * vec4<f32>(wpos + n * texel * (1.0 + 2.0 * (1.0 - ndl)), 1.0);
  return cascade_pcf(i, lp.xyz / lp.w, ndl);
}

// the sun's shadow at a world point: the cascade its view depth falls in, blended into the next one over the last
// params.z of its range (the last cascade fades to lit), so no seam shows where one cascade hands over. Needs `cam`.
fn shadow_at(wpos : vec3<f32>, n : vec3<f32>, ndl : f32) -> f32 {
  let vz = dot(wpos - cam.eye.xyz, cam.fwd.xyz);
  let count = cascade_count();
  let i = cascade_for(vz);
  if i >= count { return 1.0; }
  var f = cascade_at(i, wpos, n, ndl);
  if shadow.params.z > 0.0 {
    let z0 = select(0.0, shadow.split[max(i, 1u) - 1u], i > 0u);
    let z1 = shadow.split[i];
    let band = shadow.params.z * (z1 - z0);
    let t = (vz - (z1 - band)) / max(band, 1e-6);
    if t > 0.0 {
      var g = 1.0;
      if i + 1u < count { g = cascade_at(i + 1u, wpos, n, ndl); }
      f = mix(f, g, clamp(t, 0.0, 1.0));
    }
  }
  return f;
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
  env_top : vec4<f32>,              // the environment for reflections: zenith, horizon, nadir (rgb); env_top.w 1
  env_hor : vec4<f32>,              // when a captured cube map is used instead (ENV_WGSL), env_hor.w its blurriest mip
  env_gnd : vec4<f32>,
  pshadow : array<vec4<f32>, 4>,    // per point light: its first atlas tile + 1 (six tiles), 0 for no shadow
  spots : array<SpotLight, 8>,      // cone.x cos(inner), dir_cos.w cos(outer), cone.y atlas tile + 1 or 0
  dirs : array<DirLight, 4>,        // dir.w atlas tile + 1 or 0
  areas : array<AreaLight, 4>,      // a rectangle: centre, two half-edge vectors; it emits toward cross(ex, ey).
                                    // pos.w atlas tile + 1 or 0, ex.w the shadow view's far distance, ey.w its size
  probe_org : vec4<f32>,            // the irradiance probe grid (app/irradiance.mojo): first probe, w 1 when on;
  probe_cell : vec4<f32>,           // the spacing (m) and the counts along x, y, z. Read by sh_lit_at (PROBES_WGSL)
  probe_dim : vec4<f32>,
  tiles : array<mat4x4<f32>, 112>,  // the atlas tiles' view-projections (app/lights.mojo MAX_TILES)
  tile_rect : array<vec4<f32>, 112>,  // each tile's square in the atlas: uv of its corner, uv size, texels across
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
    let ndl = max(dot(nrm, d / dist), 0.0);
    // the shadow is looked up only where the light arrives (in range, facing it)
    if x * ndl > 0.0 {
      sum += lights.l[i].color.rgb * lights.l[i].color.w * ndl * x * x * point_shadow(i, wpos, nrm);
    }
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
    if cone > 0.0 && dist < s.pos_range.w && dot(nrm, l) > 0.0 { e *= local_shadow(s.cone.y, wpos, nrm, dist); }
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
    extra = sh_lit_at(wpos, n) + point_lights(wpos, n);
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

# The local lights' shadows: a depth atlas of square tiles, one view per tile (lights.tiles), each tile's square in
# lights.tile_rect (sizes chosen per frame, app/lights.mojo atlas_sizes). `tile1` is the tile + 1 (0: the light casts none). The lookup is at the point moved along its normal by a length that grows with the
# distance to the light (a texel of the tile covers more there), then a 3 x 3 percentage-closer filter inside the tile.
comptime LOCAL_SHADOW_WGSL = """
fn local_shadow(tile1 : f32, wpos : vec3<f32>, nrm : vec3<f32>, dist : f32) -> f32 {
  if tile1 < 0.5 { return 1.0; }
  let t = u32(tile1) - 1u;
  let r = lights.tile_rect[t];
  // the offset grows as the tile's texels do (it was set for 512 across)
  let c = lights.tiles[t] * vec4<f32>(wpos + nrm * (0.02 + 0.012 * dist) * max(512.0 / r.w, 1.0), 1.0);
  if c.w <= 0.0 { return 1.0; }
  let p = c.xyz / c.w;
  if abs(p.x) > 1.0 || abs(p.y) > 1.0 || p.z > 1.0 { return 1.0; }
  let size = vec2<f32>(textureDimensions(atlas_map));
  let org = r.xy;
  let half_texel = 0.5 / size;
  let lo = org + half_texel;
  let hi = org + vec2<f32>(r.z) - half_texel;
  let uv = org + vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) * r.z;
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
  let r = lights.tile_rect[t];
  let tile_px = r.w;
  let org = r.xy * f32(textureDimensions(atlas_map).x);
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

# What MatPbr reflects (the mesh and skinned passes, which bind `env_cube` and `samp`): the cube map captured by an
# EnvProbe (app/env_probe.mojo) while one is in use, else the environment's three-colour gradient. A rougher surface
# reads a smaller mip (each mip is the mean of four texels of the one above, not a GGX filter) and, from roughness 0.7
# up, the environment's irradiance. The cube map is looked up by direction alone: reflections are right at the
# probe's position and shift with distance from it (no parallax correction).
comptime ENV_WGSL = """
fn env_reflect(r : vec3<f32>, rough : f32) -> vec3<f32> {
  if lights.env_top.w > 0.5 {
    let c = atmo_lin(textureSampleLevel(env_cube, samp, r, clamp(rough, 0.0, 1.0) * lights.env_hor.w).rgb);
    return mix(c, sh_lit(r), smoothstep(0.7, 1.0, rough));
  }
  return env_radiance(r, rough);
}
"""


# The ambient from baked irradiance probes (app/irradiance.mojo): a grid of order-2 spherical harmonics, 9 vec4 per
# probe (rgb), probe (ix, iy, iz) at index (iz * ny + iy) * nx + ix, in a storage buffer each shader declares as
# `probes`. At a world point the eight probes around it are blended by trilinear weights (outside the grid, the nearest
# face's); with no grid set, the environment's harmonics as before. NO_PROBES_WGSL is for shaders without the buffer.
comptime PROBES_WGSL = """
fn probe_irr(i : u32, n : vec3<f32>) -> vec3<f32> {
  let b = i * 9u;
  let e = 0.429043 * probes[b + 8u].rgb * (n.x * n.x - n.y * n.y) + 0.743125 * probes[b + 6u].rgb * n.z * n.z
        + 0.886227 * probes[b].rgb - 0.247708 * probes[b + 6u].rgb
        + 2.0 * 0.429043 * (probes[b + 4u].rgb * n.x * n.y + probes[b + 7u].rgb * n.x * n.z + probes[b + 5u].rgb * n.y * n.z)
        + 2.0 * 0.511664 * (probes[b + 3u].rgb * n.x + probes[b + 1u].rgb * n.y + probes[b + 2u].rgb * n.z);
  return max(e, vec3<f32>(0.0)) / L_PI;
}
fn sh_lit_at(wpos : vec3<f32>, n : vec3<f32>) -> vec3<f32> {
  if lights.probe_org.w < 0.5 { return sh_lit(n); }
  let dim = vec3<i32>(lights.probe_dim.xyz);
  let g = clamp((wpos - lights.probe_org.xyz) / lights.probe_cell.xyz, vec3<f32>(0.0), vec3<f32>(dim - vec3<i32>(1)));
  let lo = min(vec3<i32>(floor(g)), max(dim - vec3<i32>(2), vec3<i32>(0)));
  let f = g - vec3<f32>(lo);
  var e = vec3<f32>(0.0);
  for (var k = 0u; k < 8u; k++) {
    let o = vec3<i32>(i32(k & 1u), i32((k >> 1u) & 1u), i32((k >> 2u) & 1u));
    let c = min(lo + o, dim - vec3<i32>(1));
    let w = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1) * select(1.0 - f.z, f.z, o.z == 1);
    if w > 0.0 { e += w * probe_irr(u32((c.z * dim.y + c.y) * dim.x + c.x), n); }
  }
  return e;
}
"""

comptime NO_PROBES_WGSL = """
fn sh_lit_at(wpos : vec3<f32>, n : vec3<f32>) -> vec3<f32> { return sh_lit(n); }
"""
