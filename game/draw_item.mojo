"""What a game hands the renderer each frame: one DrawItem per thing to draw, and the built-in material IDs.

Renderer code imports this module, not a game; `game.arena` re-exports both names for existing hosts."""
from geometry.vec import Real, Vec3


# DrawItem.material: the built-in materials (app/material.mojo has their shading; a game may add more IDs there)
comptime MAT_COLOR = 0  # colour only
comptime MAT_UV = 1  # a texture array layer at the mesh's uv
comptime MAT_TRIPLANAR = 2  # a layer projected along the world axes
comptime MAT_SKY = 3  # the sky gradient (unlit, casts no shadow)


struct DrawItem(Copyable, Movable):
    """One thing to draw: a box (kind 0) or a sphere (kind 1, radius in half[0]).

    mesh_id >= 0 draws an indexed mesh from the mesh registry instead of the primitive path (step 5, PR A);
    -1 keeps the primitive path, so existing producers are unchanged. pose_id and material are read by the
    skinned and texture passes (PRs B and C); PR A ignores them.
    """

    var kind: Int
    var pos: Vec3
    var qx: Float64
    var qy: Float64
    var qz: Float64
    var qw: Float64
    var half: Vec3
    var color: Vec3
    var mesh_id: Int
    var pose_id: Int
    var material: Int  # MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY or a game's own material ID
    var layer: Int  # the texture array layer a textured item samples (material > 0); 1 is the placeholder wall

    def __init__(
        out self,
        kind: Int,
        pos: Vec3,
        qx: Float64,
        qy: Float64,
        qz: Float64,
        qw: Float64,
        half: Vec3,
        color: Vec3,
        mesh_id: Int = -1,
        pose_id: Int = -1,
        material: Int = 0,
        layer: Int = 1,
    ):
        self.kind = kind
        self.pos = pos
        self.qx = qx
        self.qy = qy
        self.qz = qz
        self.qw = qw
        self.half = half
        self.color = color
        self.mesh_id = mesh_id
        self.pose_id = pose_id
        self.material = material
        self.layer = layer
