# tier: unit
# The mesh pass's CPU side (app/mesh_pass.mojo): the registry's checks, and the draw-list hash. The GPU side is checked
# by the parity gates (a cube drawn natively and on the web), not here.
from harness.runner import Suite
from app.mesh_pass import MeshRegistry, add_unit_cube, mesh_draw_hash, mesh_probe_hash, unit_cube_arrays, RenderCaps, vertex_normals
from game.draw_item import DrawItem
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

    # skinned meshes: 4 joints and 4 weights per vertex, refused otherwise
    var sk_reg = MeshRegistry()
    var sc = unit_cube_arrays()
    var nv = len(sc[0]) // 3
    var sj = List[UInt16]()
    var sw = List[Float32]()
    for _ in range(nv):
        for j in range(4):
            sj.append(0)
            sw.append(Float32(1.0) if j == 0 else Float32(0.0))
    var sid = sk_reg.add_skinned(sc[0].copy(), sc[1].copy(), sc[2].copy(), sj.copy(), sw.copy(), sc[3].copy())
    s.check(sid == 0 and len(sk_reg.skinned) == 1 and len(sk_reg.meshes) == 0, "a skinned mesh goes to the skinned list")
    var short_joints = List[UInt16]()
    short_joints.append(0)
    var sk_raised = False
    try:
        _ = sk_reg.add_skinned(sc[0].copy(), sc[1].copy(), sc[2].copy(), short_joints^, sw.copy(), sc[3].copy())
    except:
        sk_raised = True
    s.check(sk_raised, "a skinned mesh without 4 joints per vertex is refused")

    # ludens-engine#71: the capacities are chosen at creation; the defaults are the former constants
    var d = RenderCaps.default()
    s.check(d.arena_instances == 8192 and d.mesh_instances == 8192 and d.palette_matrices == 4096,
            "RenderCaps defaults: 8192 arena items, 8192 mesh instances, 4096 palette matrices")
    var bad = 0
    try:
        RenderCaps(8192, 0, 4096).check()
    except:
        bad += 1
    try:
        RenderCaps(8192, 8192, 16384).check()
    except:
        bad += 10
    s.check(bad == 1, "a zero capacity raises, a larger one is accepted")
    # ludens-engine#73: a dynamic mesh (a 2 x 2 quad grid that bends), normals from vertex_normals
    var gp = List[Float32]()
    var guv = List[Float32]()
    for j in range(3):
        for i2 in range(3):
            gp.append(Float32(i2)); gp.append(0.0); gp.append(Float32(j))
            guv.append(Float32(i2) / 2.0); guv.append(Float32(j) / 2.0)
    var gi = List[UInt32]()
    for j in range(2):
        for i2 in range(2):
            var a = UInt32(j * 3 + i2)
            gi.append(a); gi.append(a + 3); gi.append(a + 1)
            gi.append(a + 1); gi.append(a + 3); gi.append(a + 4)
    var gn = vertex_normals(gp, gi)
    var up = True
    for v in range(9):
        up = up and gn[3 * v] == 0.0 and gn[3 * v + 1] == 1.0 and gn[3 * v + 2] == 0.0
    s.check(up, "vertex_normals of a flat grid in y = 0 wound counter-clockwise from above: every normal (0, 1, 0)")
    var dreg = MeshRegistry()
    var still = dreg.add_static(gp.copy(), gn.copy(), guv.copy(), gi.copy())
    var dyn = dreg.add_dynamic(gp.copy(), gn.copy(), guv.copy(), gi.copy())
    s.check(dreg.versions[still] == 0 and dreg.versions[dyn] == 1, "add_static is version 0, add_dynamic starts at 1")
    var bent = gp.copy()
    bent[3 * 4 + 1] = 0.5  # lift the centre
    dreg.update_dynamic(dyn, bent.copy(), vertex_normals(bent, gi))
    s.check(dreg.versions[dyn] == 2 and dreg.meshes[dyn].positions[13] == 0.5, "update_dynamic replaces the positions and bumps the version")
    var refused = 0
    try:
        dreg.update_dynamic(still, bent.copy(), gn.copy())
    except:
        refused += 1
    try:
        var short = List[Float32]()
        short.append(0.0); short.append(0.0); short.append(0.0)
        dreg.update_dynamic(dyn, short.copy(), short.copy())
    except:
        refused += 1
    s.check(refused == 2, "update_dynamic refuses a static mesh and a different vertex count")
    s.finish()
