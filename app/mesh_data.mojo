"""The meshes a game registers, on the CPU: static meshes (positions, normals, uv, indices), dynamic meshes whose
positions change, and skinned meshes (4 joints and 4 weights per vertex). The GPU copies are made by
app/gpu_mesh.mojo's GpuMeshCache; app/mesh_pass.mojo re-exports these names."""


@fieldwise_init
struct MeshData(Copyable, Movable):
    """One static mesh on the CPU: positions, normals, uv and a triangle index list."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var indices: List[UInt32]


def _check_mesh(positions: List[Float32], normals: List[Float32], uv: List[Float32], indices: List[UInt32]) raises:
    """The boundary check for every mesh: arrays that agree, and indices inside the vertex range."""
    var nv = len(positions) // 3
    if len(positions) % 3 != 0 or nv == 0:
        raise Error("mesh: positions must be a non-empty multiple of 3 floats")
    if len(normals) != len(positions):
        raise Error("mesh: normals must have one vector per position")
    if len(uv) != nv * 2:
        raise Error("mesh: uv must have one pair per position")
    if len(indices) == 0 or len(indices) % 3 != 0:
        raise Error("mesh: indices must be a non-empty list of triangles")
    for i in indices:
        if Int(i) >= nv:
            raise Error("mesh: an index is outside the vertex range")


@fieldwise_init
struct SkinnedMeshData(Copyable, Movable):
    """A mesh with joints: 4 joint indices (u16) and 4 weights per vertex. The joint indices are relative to the pose's
    palette base (the draw item's pose_id)."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var joints: List[UInt16]
    var weights: List[Float32]
    var indices: List[UInt32]


struct MeshRegistry(Movable):
    """The meshes a game registers. Static meshes are indexed by the mesh_id a draw item carries; skinned meshes by the
    id add_skinned returns. A draw item with pose_id >= 0 refers to a skinned mesh."""

    var meshes: List[MeshData]
    var skinned: List[SkinnedMeshData]
    var versions: List[Int]  # per static mesh: 0 static; a dynamic mesh starts at 1 and counts its updates

    def __init__(out self):
        self.meshes = List[MeshData]()
        self.skinned = List[SkinnedMeshData]()
        self.versions = List[Int]()

    def add_skinned(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var joints: List[UInt16],
        var weights: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """As add_static, plus 4 joints and 4 weights per vertex. Returns the skinned id."""
        _check_mesh(positions, normals, uv, indices)
        if len(joints) != 4 * (len(positions) // 3) or len(weights) != 4 * (len(positions) // 3):
            raise Error("mesh: a skinned mesh needs 4 joints and 4 weights per vertex")
        for w in weights:
            if w < 0.0:
                raise Error("mesh: skinning weights are not negative")
        self.skinned.append(SkinnedMeshData(positions^, normals^, uv^, joints^, weights^, indices^))
        return len(self.skinned) - 1

    def add_static(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """Check the arrays at the boundary (an invalid mesh raises), then keep it. Returns its id."""
        _check_mesh(positions, normals, uv, indices)
        self.meshes.append(MeshData(positions^, normals^, uv^, indices^))
        self.versions.append(0)
        return len(self.meshes) - 1

    def add_dynamic(
        mut self,
        var positions: List[Float32],
        var normals: List[Float32],
        var uv: List[Float32],
        var indices: List[UInt32],
    ) raises -> Int:
        """A mesh whose positions and normals change (cloth, a rope; ludens-engine#73): as add_static, and
        update_dynamic replaces them each frame; the passes re-upload a mesh whose version changed. The vertex count,
        uv and indices stay fixed."""
        var id = self.add_static(positions^, normals^, uv^, indices^)
        self.versions[id] = 1
        return id

    def update_dynamic(mut self, id: Int, var positions: List[Float32], var normals: List[Float32]) raises:
        """Replace a dynamic mesh's positions and normals (same vertex count)."""
        if id < 0 or id >= len(self.meshes) or self.versions[id] == 0:
            raise Error("mesh: update_dynamic needs a mesh made by add_dynamic")
        if len(positions) != len(self.meshes[id].positions) or len(normals) != len(positions):
            raise Error("mesh: update_dynamic keeps the vertex count (3 floats per position and per normal)")
        self.meshes[id].positions = positions^
        self.meshes[id].normals = normals^
        self.versions[id] += 1

    def count(self) -> Int:
        return len(self.meshes)
