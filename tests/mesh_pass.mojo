# tier: unit
# The mesh pass's CPU side (app/mesh_pass.mojo): the registry's checks, and the draw-list hash. The GPU side is checked
# by the parity gates (a cube drawn natively and on the web), not here.
from harness.runner import Suite
from app.mesh_pass import MeshRegistry, add_unit_cube, mesh_draw_hash, mesh_probe_hash
from game.arena import DrawItem
from geometry.vec import Real, Vec3


def _cube() -> Tuple[List[Float32], List[Float32], List[Float32], List[UInt32]]:
    var pos = List[Float32]()
    var nrm = List[Float32]()
    var uv = List[Float32]()
    for _ in range(4):
        pos.append(0.0)
        pos.append(0.0)
        pos.append(0.0)
        nrm.append(0.0)
        nrm.append(1.0)
        nrm.append(0.0)
        uv.append(0.0)
        uv.append(0.0)
    var idx = List[UInt32]()
    idx.append(0)
    idx.append(1)
    idx.append(2)
    return (pos^, nrm^, uv^, idx^)


def _item(mesh: Int, x: Float64) -> DrawItem:
    return DrawItem(
        -1, Vec3(Real(x), Real(0.0), Real(0.0), Real(0.0)), 0.0, 0.0, 0.0, 1.0,
        Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.5), Real(0.5), Real(0.5), Real(0.0)), mesh, -1, 0,
    )


def main() raises:
    var s = Suite("mesh_pass")

    var reg = MeshRegistry()
    var c = _cube()
    var id0 = reg.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())
    s.check(id0 == 0 and reg.count() == 1, "the first mesh gets id 0")

    var bad_positions = List[Float32]()
    bad_positions.append(0.0)
    var raised = False
    try:
        var nrm = List[Float32]()
        var uv = List[Float32]()
        var idx = List[UInt32]()
        idx.append(0)
        _ = reg.add_static(bad_positions^, nrm^, uv^, idx^)
    except:
        raised = True
    s.check(raised, "a mesh with positions that are not whole vertices is refused")

    raised = False
    try:
        var c2 = _cube()
        var idx = List[UInt32]()
        idx.append(0)
        idx.append(1)
        idx.append(9)
        _ = reg.add_static(c2[0].copy(), c2[1].copy(), c2[2].copy(), idx^)
    except:
        raised = True
    s.check(raised, "an index outside the vertex range is refused")

    raised = False
    try:
        var c3 = _cube()
        var idx = List[UInt32]()
        idx.append(0)
        idx.append(1)
        _ = reg.add_static(c3[0].copy(), c3[1].copy(), c3[2].copy(), idx^)
    except:
        raised = True
    s.check(raised, "an index list that is not whole triangles is refused")
    s.check(reg.count() == 1, "refused meshes are not kept")

    # the draw-list hash
    var items = List[DrawItem]()
    items.append(_item(0, 1.0))
    items.append(_item(-1, 5.0))  # primitive: not part of the mesh list
    items.append(_item(0, 2.0))
    var h1 = mesh_draw_hash(items, reg)
    var h2 = mesh_draw_hash(items, reg)
    s.check(h1 == h2, "the same draw list hashes the same twice")

    var no_mesh = List[DrawItem]()
    no_mesh.append(_item(-1, 1.0))
    s.check(mesh_draw_hash(no_mesh, reg) == mesh_draw_hash(List[DrawItem](), reg), "primitive items are not part of the mesh hash")

    var moved = List[DrawItem]()
    moved.append(_item(0, 1.5))
    moved.append(_item(-1, 5.0))
    moved.append(_item(0, 2.0))
    s.check(mesh_draw_hash(moved, reg) != h1, "moving the first instance changes the hash")

    var more = List[DrawItem]()
    more.append(_item(0, 1.0))
    more.append(_item(0, 1.0))
    s.check(mesh_draw_hash(more, reg) != mesh_draw_hash(List[DrawItem](), reg), "one more instance changes the hash")

    # the unit cube the probe and the arena use: 6 faces of 4 vertices, 12 triangles
    var cube_reg = MeshRegistry()
    var cube_id = add_unit_cube(cube_reg)
    s.check(cube_id == 0 and len(cube_reg.meshes[0].positions) == 72 and len(cube_reg.meshes[0].indices) == 36,
            "the unit cube has 24 vertices and 36 indices")
    s.check(mesh_probe_hash() == mesh_probe_hash(), "the probe hash is the same on every call")

    s.finish()
