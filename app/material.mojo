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
from game.arena import MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY

# What a material reads, filled by the fragment shader of each pass:
#   base  the item's colour (sRGB), color = base * lit, lit the sun's diffuse term (0.4 .. 1.0)
#   uv / layer: the texture coordinates and array layer; wpos / wnrm: world position and normal
#   sf    the light factor: shadow (and AO on the mesh pass), exactly 1.0 when they are off
comptime SURFACE_WGSL = """
struct Surface {
  base : vec3<f32>,
  color : vec3<f32>,
  lit : f32,
  uv : vec2<f32>,
  layer : u32,
  wpos : vec3<f32>,
  wnrm : vec3<f32>,
  sf : f32,
};
"""


trait Material:
    comptime ID: Int
    """The value of DrawItem.material that selects this material."""
    comptime BODY: StaticString
    """The statements of `fn mat_<ID>(s : Surface) -> vec4<f32>`."""


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
