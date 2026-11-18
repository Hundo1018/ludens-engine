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

# The point lights (issue #90 step 3), per pixel, added to the per-vertex sun term. `lights` is declared by each shader
# at its own binding (RenderResources.lights). n.x is the light count (0 .. MAX_POINT_LIGHTS); with 0 the shaders use
# their per-vertex colour unchanged, so a frame without point lights is the same as before they existed.
comptime POINT_LIGHTS_WGSL = """
struct PointLight { pos_range : vec4<f32>, color : vec4<f32> };
struct Lights { n : vec4<f32>, l : array<PointLight, 16> };
// the point lights' diffuse term at a world point with unit normal nrm: colour * intensity * N.L * (1 - (d / r)^2)^2
fn point_lights(wpos : vec3<f32>, nrm : vec3<f32>) -> vec3<f32> {
  var sum = vec3<f32>(0.0);
  let count = min(u32(lights.n.x), 16u);
  for (var i = 0u; i < count; i++) {
    let d = lights.l[i].pos_range.xyz - wpos;
    let dist = max(length(d), 1e-4);
    let x = clamp(1.0 - (dist / lights.l[i].pos_range.w) * (dist / lights.l[i].pos_range.w), 0.0, 1.0);
    sum += lights.l[i].color.rgb * lights.l[i].color.w * max(dot(nrm, d / dist), 0.0) * x * x;
  }
  return sum;
}
fn has_point_lights() -> bool {
  return lights.n.x > 0.5;
}
"""
