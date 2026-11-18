"""Surface materials as types (plan 2.5, issue #90). A draw item's `material` is a Material's ID; each Material
contributes one WGSL function `mat_<ID>(s : Surface) -> vec4<f32>`, and `Materials[*Ms].wgsl()` writes those functions
and `shade(mat, s)`, the switch that calls the one named by the item. The mesh and skinned passes take the same pack,
so a material looks the same on a static and on a skinned mesh, and a game adds a material by adding a type:

    struct MatToon(Material):
        comptime ID: Int = 7
        comptime BODY: StaticString = "return atmo_out(atmo_fog(floor(s.base * s.lit * 4.0) / 4.0 * s.sf, s.wpos));"
    comptime MyMeshPass = MeshPassOf[MatColor, MatUv, MatTriplanar, MatSky, MatToon]

A body may use what both passes declare: `Surface` (below), `tex` / `samp` (the texture array), `triplanar`, the
atmosphere functions (app/textures.mojo ATMO_WGSL), `shadow` and `cam`. An ID that no material in the pack has shades
as the pack's first material.
"""
from game.draw_item import MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY, MAT_PBR

# What a material reads, filled by the fragment shader of each pass:
#   base  the item's colour (sRGB), color = base * lit, lit the light reaching the point (rgb): the sun's diffuse term
#         (0.4 .. 1.0, per vertex) plus the point lights (per pixel, RenderResources.set_lights)
#   uv / layer: the texture coordinates and array layer; wpos / wnrm: world position and normal
#   sf    the light factor: shadow (and AO on the mesh pass), exactly 1.0 when they are off
#   rough / metal: the item's roughness and metallic (DrawItem; read by MatPbr)
comptime SURFACE_WGSL = """
struct Surface {
  base : vec3<f32>,
  color : vec3<f32>,
  lit : vec3<f32>,
  uv : vec2<f32>,
  layer : u32,
  wpos : vec3<f32>,
  wnrm : vec3<f32>,
  sf : f32,
  rough : f32,
  metal : f32,
};
"""


trait Material:
    comptime ID: Int
    """The value of DrawItem.material that selects this material."""
    comptime BODY: StaticString
    """The statements of `fn mat_<ID>(s : Surface) -> vec4<f32>`."""
    comptime NAME: StaticString = ""
    """A short name for listing a pass's material pack; the built-in materials leave it empty."""
    # The rest configure the pass, not one item, and are read from the pack's first material only:
    comptime BLEND: Int = 0
    """How the pass's fragments meet what is already in the target (app/gpu_blend.mojo): BLEND_NONE, BLEND_ALPHA,
    BLEND_ADD or BLEND_MULTIPLY."""
    comptime CULL: Int = 0
    """CULL_NONE, CULL_FRONT or CULL_BACK."""
    comptime DEPTH_WRITE: Bool = True
    comptime VERT_WORLD: StaticString = ""
    """WGSL statements in the vertex stage that may move `world` (and read `n`, the world normal, and `v`, the
    vertex input) before it is projected: an outline hull pushed out along the normal, a wobble."""
    comptime VERT_CLIP: StaticString = ""
    """WGSL statements that may change `out.pos`, the clip-space position, after projection: snapping to a grid."""


struct MatColor(Material):
    """Colour only: the look from before textures existed (atmosphere off)."""

    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  let c0 = select(s.color, atmo_lin(s.base) * s.lit, shadow.sky_top.w > 0.5);
  return atmo_out(atmo_fog(c0 * s.sf, s.wpos));"""


struct MatUv(Material):
    """The texture array layer at the mesh's uv, times the item's colour."""

    comptime ID: Int = MAT_UV
    comptime BODY: StaticString = """
  let t = textureSampleLevel(tex, samp, s.uv, s.layer, 0.0);
  return atmo_out(atmo_fog(atmo_lin(s.base) * atmo_lin(t.rgb) * s.lit * s.sf, s.wpos));"""


struct MatTriplanar(Material):
    """The layer projected along the world axes (no uv needed), times the item's colour."""

    comptime ID: Int = MAT_TRIPLANAR
    comptime BODY: StaticString = """
  let t = triplanar(s.wpos, s.wnrm, s.layer, 0.0);
  return atmo_out(atmo_fog(atmo_lin(s.base) * atmo_lin(t.rgb) * s.lit * s.sf, s.wpos));"""


struct MatSky(Material):
    """The sky gradient by view direction (app/textures.mojo atmo_sky); unlit."""

    comptime ID: Int = MAT_SKY
    comptime BODY: StaticString = """
  return atmo_out(atmo_sky(s.wpos));"""


# Cook-Torrance for one light (GGX distribution, Schlick Fresnel, Smith-Schlick geometry), shared by MatPbr. l is the
# unit direction to the light and radiance what arrives from it; the diffuse lobe is Lambert / pi, so a white matte
# surface under radiance pi * k reflects k, the scale of the old lit term.
comptime PBR_WGSL = """
const PBR_PI = 3.14159265;
fn pbr_light(n : vec3<f32>, v : vec3<f32>, l : vec3<f32>, radiance : vec3<f32>, albedo : vec3<f32>, f0 : vec3<f32>, a : f32, metal : f32) -> vec3<f32> {
  let ndl = max(dot(n, l), 0.0);
  if ndl <= 0.0 {
    return vec3<f32>(0.0);
  }
  let h = normalize(v + l);
  let ndv = max(dot(n, v), 1e-4);
  let ndh = max(dot(n, h), 0.0);
  let vdh = max(dot(v, h), 0.0);
  let a2 = a * a;
  let dd = ndh * ndh * (a2 - 1.0) + 1.0;
  let d = a2 / (PBR_PI * dd * dd);
  let k = a * 0.5;
  let g = (ndv / (ndv * (1.0 - k) + k)) * (ndl / (ndl * (1.0 - k) + k));
  let f = f0 + (vec3<f32>(1.0) - f0) * pow(1.0 - vdh, 5.0);
  let spec = d * g * f / max(4.0 * ndv * ndl, 1e-4);
  let kd = (vec3<f32>(1.0) - f) * (1.0 - metal);
  return (kd * albedo / PBR_PI + spec) * radiance * ndl;
}
"""


struct MatPbr(Material):
    """Metallic-roughness from the item's roughness and metallic: the sun (the old 0.6 diffuse scale, shadowed) and the
    point lights through pbr_light, plus the old 0.4 ambient on the diffuse part."""

    comptime ID: Int = MAT_PBR
    comptime BODY: StaticString = """
  let n = normalize(s.wnrm);
  let v = normalize(cam.eye.xyz - s.wpos);
  let albedo = atmo_lin(s.base);
  let f0 = mix(vec3<f32>(0.04), albedo, s.metal);
  let a = max(s.rough * s.rough, 0.002);
  var c = albedo * 0.4 * (1.0 - s.metal);
  c += pbr_light(n, v, normalize(vec3<f32>(0.4, 1.0, 0.6)), vec3<f32>(0.6 * PBR_PI) * s.sf, albedo, f0, a, s.metal);
  let count = min(u32(lights.n.x), 16u);
  for (var i = 0u; i < count; i++) {
    let d = lights.l[i].pos_range.xyz - s.wpos;
    let dist = max(length(d), 1e-4);
    let x = clamp(1.0 - (dist / lights.l[i].pos_range.w) * (dist / lights.l[i].pos_range.w), 0.0, 1.0);
    c += pbr_light(n, v, d / dist, lights.l[i].color.rgb * lights.l[i].color.w * PBR_PI * x * x, albedo, f0, a, s.metal);
  }
  return atmo_out(atmo_fog(c, s.wpos));"""


struct Materials[*Ms: Material]:
    @staticmethod
    def wgsl() -> String:
        """SURFACE_WGSL, one `mat_<ID>` per material, and `shade(mat, s)`."""
        var s = String(SURFACE_WGSL)
        comptime for i in range(len(Self.Ms)):
            s += "fn mat_" + String(Self.Ms[i].ID) + "(s : Surface) -> vec4<f32> {" + Self.Ms[i].BODY + "\n}\n"
        s += "fn shade(mat : u32, s : Surface) -> vec4<f32> {\n"
        comptime for i in range(len(Self.Ms)):
            s += "  if mat == " + String(Self.Ms[i].ID) + "u { return mat_" + String(Self.Ms[i].ID) + "(s); }\n"
        s += "  return mat_" + String(Self.Ms[0].ID) + "(s);\n}\n"
        return s^
