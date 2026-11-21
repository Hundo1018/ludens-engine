"""Pass lists and materials that draw surface data instead of a lit colour: what `Aux[...]` (app/render_pass.mojo)
puts in the aux target for the post stages, and the outline hull.

    SceneRendererOf[Lit, Stage[MyStyle], Aux[NormalPasses]]    # the stages' gnormal / gedge read true normals
    comptime Outlined = Then[MyMeshPass, HullPass]                # an ink line as geometry, not as an edge filter
"""
from game.draw_item import MAT_COLOR, MAT_SKY
from app.material import Material
from app.mesh_pass import MeshPassOf


struct MatNormalOut(Material):
    """rgb = 0.5 + 0.5 world normal (the vertex normals, interpolated: smooth on a sphere), a = 1."""

    comptime NAME: StaticString = "normal"
    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  return vec4<f32>(0.5 + 0.5 * normalize(s.wnrm), 1.0);"""


struct MatAlbedoOut(Material):
    """rgb = the item's own colour with no light on it, a = 1: what a stage needs to light the scene again."""

    comptime NAME: StaticString = "albedo"
    comptime ID: Int = MAT_COLOR
    comptime BODY: StaticString = """
  return vec4<f32>(s.base, 1.0);"""


struct MatNothing(Material):
    """Draws nothing: the sky in a surface-data pass."""

    comptime ID: Int = MAT_SKY
    comptime BODY: StaticString = """
  discard;
  return vec4<f32>(0.0);"""


comptime NormalPasses = MeshPassOf[MatNormalOut, MatNothing]
comptime AlbedoPasses = MeshPassOf[MatAlbedoOut, MatNothing]


struct MatHull(Material):
    """The outline as geometry: every mesh again, pushed out from its item's centre by 0.5 % of its distance to the
    eye (so the line keeps its width on screen), in ink, with the faces that look toward the eye dropped (by their
    normal, so the mesh's winding does not matter). What shows is the shell's inside, only where it sticks out past
    the mesh itself: a line round each form, in front of what is behind it and behind what is in front, with the depth
    buffer deciding. A filter over the finished frame cannot tell those apart."""

    comptime ID: Int = MAT_COLOR
    comptime NAME: StaticString = "hull, back faces"
    comptime VERT_WORLD: StaticString = "world = world + normalize(world - m[3].xyz) * 0.005 * length(world - cam.eye.xyz);"
    comptime BODY: StaticString = """
  if dot(s.wnrm, cam.eye.xyz - s.wpos) > 0.0 { discard; }
  return vec4<f32>(0.05, 0.04, 0.07, 1.0);"""


comptime HullPass = MeshPassOf[MatHull, MatNothing]
