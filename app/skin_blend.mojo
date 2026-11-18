"""How a skinned vertex blends its joints (issue #90 step 5): a SkinBlend is the WGSL of `skin_position` and
`skin_normal` over the palette (`palette : array<mat4x4<f32>>`, one rigid matrix per joint, base + joint index).
SkinnedPassOf[B, *Ms] draws with B; the palette the host writes is the same for every blend.

  LinearBlend  linear blend skinning (LBS): the weighted sum of the joint matrices (app/skin_gpu.mojo SKIN_FN, the
               source the compute path and the shadow pass use). A joint twisted by a large angle collapses the
               vertices between the joints toward the axis (the candy-wrapper effect).
  MotorBlend   motor blending (dual-quaternion / dual-number blending of the rigid motions, ludens-core's motor
               skinning): each joint matrix becomes a unit dual quaternion, they are summed on one hemisphere and
               normalised, and the vertex moves by the blended rigid motion, so a twist keeps the cross-section.
               The joint matrices must be rigid (rotation and translation, no scale).
"""
from app.skin_gpu import SKIN_FN


trait SkinBlend:
    comptime WGSL: StaticString
    """Defines `skin_position(p, j, w, base) -> vec3<f32>` and `skin_normal(n, j, w, base) -> vec3<f32>`."""


struct LinearBlend(SkinBlend):
    comptime WGSL: StaticString = SKIN_FN


struct MotorBlend(SkinBlend):
    comptime WGSL: StaticString = """
struct Dq { r : vec4<f32>, d : vec4<f32> };
fn dq_qmul(a : vec4<f32>, b : vec4<f32>) -> vec4<f32> {
  return vec4<f32>(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));
}
fn dq_rotate(q : vec4<f32>, v : vec3<f32>) -> vec3<f32> {
  return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}
// a rigid joint matrix (column-major m[c][r]) as a unit dual quaternion: rotation r, dual part d = t r / 2
fn dq_from_mat(m : mat4x4<f32>) -> Dq {
  let tr = m[0][0] + m[1][1] + m[2][2];
  var q : vec4<f32>;
  if tr > 0.0 {
    let s = sqrt(tr + 1.0) * 2.0;
    q = vec4<f32>((m[1][2] - m[2][1]) / s, (m[2][0] - m[0][2]) / s, (m[0][1] - m[1][0]) / s, 0.25 * s);
  } else if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
    let s = sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2.0;
    q = vec4<f32>(0.25 * s, (m[1][0] + m[0][1]) / s, (m[2][0] + m[0][2]) / s, (m[1][2] - m[2][1]) / s);
  } else if m[1][1] > m[2][2] {
    let s = sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2.0;
    q = vec4<f32>((m[1][0] + m[0][1]) / s, 0.25 * s, (m[2][1] + m[1][2]) / s, (m[2][0] - m[0][2]) / s);
  } else {
    let s = sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2.0;
    q = vec4<f32>((m[2][0] + m[0][2]) / s, (m[2][1] + m[1][2]) / s, 0.25 * s, (m[0][1] - m[1][0]) / s);
  }
  q = normalize(q);
  let t = vec4<f32>(m[3].xyz, 0.0);
  return Dq(q, 0.5 * dq_qmul(t, q));
}
// the blended rigid motion of a vertex: joints summed on the first joint's hemisphere, then normalised
fn dq_blend(j : vec4<u32>, w : vec4<f32>, base : u32) -> Dq {
  let first = dq_from_mat(palette[base + j[0]]);
  var r = vec4<f32>(0.0);
  var d = vec4<f32>(0.0);
  for (var k = 0u; k < 4u; k = k + 1u) {
    if w[k] == 0.0 {
      continue;
    }
    let q = dq_from_mat(palette[base + j[k]]);
    let s = select(w[k], -w[k], dot(q.r, first.r) < 0.0);
    r += q.r * s;
    d += q.d * s;
  }
  let len = length(r);
  return Dq(r / len, d / len);
}
fn skin_position(p: vec3<f32>, j: vec4<u32>, w: vec4<f32>, base: u32) -> vec3<f32> {
  if w.x + w.y + w.z + w.w == 0.0 {
    return p;
  }
  let b = dq_blend(j, w, base);
  let t = 2.0 * dq_qmul(b.d, vec4<f32>(-b.r.xyz, b.r.w)).xyz;
  return dq_rotate(b.r, p) + t;
}
fn skin_normal(n: vec3<f32>, j: vec4<u32>, w: vec4<f32>, base: u32) -> vec3<f32> {
  if w.x + w.y + w.z + w.w == 0.0 {
    return n;
  }
  return dq_rotate(dq_blend(j, w, base).r, n);
}
"""
