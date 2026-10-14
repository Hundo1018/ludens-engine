# tier: integration
"""Contact friction and softness from a mesh triangle's material (ROADMAP
17.50, `ContactScene6.set_material_friction` / `set_material_softness`).

  1. Ordinary: a box sliding at 3 m/s on mesh triangles of material
     friction 0.05 stops in the same distance (1 %) as on a box floor of
     friction 0.05, near v^2 / (2 mu g) = 9.18 m; the triangle's friction
     replaces the bodies' (0.8 here).
  2. Integration: a box dropped onto triangles of material softness
     (3 Hz, zeta 1) sinks exactly as deep as onto the same mesh with that
     softness set on the mesh body (`set_contact_softness`), and far deeper
     than onto the stiff default; a `RULE_FRICTION` ContactRule on the box
     still wins over the material friction. Snapshot keeps the table.
  3. Extreme: an id above 65535, hertz <= 0 and zeta < 0 raise; triangles
     of a material with no softness keep the default.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.contact6 import ContactRule, RULE_FRICTION
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime SLICK = 1
comptime SOFT = 2


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _floor_mesh(mut sc: ContactScene6[QuatBody6], mat: Int) raises -> Int:
    """A 60 x 20 m floor of 2 triangles at y = 0, both of material `mat`."""
    var v: List[Real] = [-10, 0, -10, -10, 0, 10, 50, 0, -10, 50, 0, 10]
    var ix: List[Int] = [0, 1, 2, 2, 1, 3]
    var id = sc.add_trimesh(_st(ZERO), v, ix)
    sc.set_friction(id.index(), 0.8)
    sc.set_triangle_materials(id, [mat, mat])
    return id.index()


def _box(mut sc: ContactScene6[QuatBody6], y: Real) raises -> Int:
    var b = sc.add(QuatBody6.at_rest(Vec3(0, y, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_friction(b.index(), 0.8)
    sc.set_sleep_thresholds(b, 0, 0)
    return b.index()


def _slide(mut sc: ContactScene6[QuatBody6], b: Int) raises -> Real:
    """Distance from 3 m/s to rest."""
    for _ in range(30):
        sc.step_soft(DT, G)
    sc.set_velocity(sc.bset.id_of(b), Vec3(3, 0, 0, 0), ZERO)
    var x0 = sc.bset.bodies[b].pos[0]
    for _ in range(600):
        sc.step_soft(DT, G)
        if sc.bset.bodies[b].vel[0] < 1e-3:
            break
    return sc.bset.bodies[b].pos[0] - x0


def _drop(mut sc: ContactScene6[QuatBody6], b: Int) raises -> Real:
    """Deepest penetration of the box bottom below y = 0 over 2 s."""
    var deepest = Real(0)
    for _ in range(120):
        sc.step_soft(DT, G)
        deepest = max(deepest, 0.25 - sc.bset.bodies[b].pos[1])
    return deepest


def main() raises:
    var s = Suite("material_contact")

    # ---- friction from the triangle ------------------------------------------------------------------------
    var ms = ContactScene6[QuatBody6]()
    _ = _floor_mesh(ms, SLICK)
    ms.set_material_friction(SLICK, 0.05)
    var mb = _box(ms, 0.25)
    var d_mesh = _slide(ms, mb)
    var bs = ContactScene6[QuatBody6]()
    var f = bs.add(_st(Vec3(0, -1, 0, 0)), Vec3(100, 1, 100, 0), True)
    bs.set_friction(f.index(), 0.05)
    var bb = _box(bs, 0.25)
    bs.set_friction(bb, 0.05)
    var d_box = _slide(bs, bb)
    var d_rule: Real
    var rs = ContactScene6[QuatBody6]()
    _ = _floor_mesh(rs, SLICK)
    rs.set_material_friction(SLICK, 0.05)
    var rb = _box(rs, 0.25)
    _ = rs.add_contact_rule(ContactRule(RULE_FRICTION, rb, ZERO, 0.5))
    d_rule = _slide(rs, rb)
    print("  slide from 3 m/s: material-0.05 mesh", d_mesh, "m, body-0.05 box floor", d_box, "m (v^2/2 mu g = 9.18);  with a 0.5 friction rule", d_rule, "m")
    s.check(abs(d_mesh / d_box - 1) < 0.01 and abs(d_mesh - 9.18) < 0.5, "triangle friction 0.05 replaces the bodies' 0.8: same stop as a 0.05 floor")
    s.check(abs(d_rule - 0.918) < 0.15, "a RULE_FRICTION rule on the box wins over the material friction")

    # ---- softness from the triangle --------------------------------------------------------------------------
    var sm = ContactScene6[QuatBody6]()
    _ = _floor_mesh(sm, SOFT)
    sm.set_material_softness(SOFT, 3, 1)
    var sb = _box(sm, 0.3)
    var pen_mat = _drop(sm, sb)
    var sbody = ContactScene6[QuatBody6]()
    var mesh = _floor_mesh(sbody, SOFT)
    sbody.set_contact_softness(mesh, 3, 1)
    var bbody = _box(sbody, 0.3)
    var pen_body = _drop(sbody, bbody)
    var sd = ContactScene6[QuatBody6]()
    _ = _floor_mesh(sd, SOFT)
    var bd = _box(sd, 0.3)
    var pen_def = _drop(sd, bd)
    print("  drop on 3 Hz material triangles: deepest", pen_mat, "m;  3 Hz on the mesh body", pen_body, "m;  default", pen_def, "m")
    s.check(abs(pen_mat - pen_body) < 1e-6 and pen_mat > 5 * pen_def, "material softness acts as the same softness on the mesh body; far softer than the default")

    var back = scene_from_bytes(scene_to_bytes(sm))
    for _ in range(30):
        sm.step_soft(DT, G)
        back.step_soft(DT, G)
    var same = back.bset.bodies[sb].pos[1] == sm.bset.bodies[sb].pos[1] and back.material_hz[SOFT] == 3 and back.material_zeta[SOFT] == 1
    s.check(same, "the softness table survives the snapshot, bit for bit")

    # ---- extremes ---------------------------------------------------------------------------------------------
    var raised = 0
    try:
        sd.set_material_softness(70000, 3, 1)
    except:
        raised += 1
    try:
        sd.set_material_softness(0, 0, 1)
    except:
        raised += 1
    try:
        sd.set_material_softness(0, 3, -0.1)
    except:
        raised += 1
    s.check(raised == 3, "id > 65535, hertz <= 0 and zeta < 0 raise")
    var od = ContactScene6[QuatBody6]()
    _ = _floor_mesh(od, SLICK)
    od.set_material_softness(SOFT, 3, 1)
    var ob = _box(od, 0.3)
    var pen_other = _drop(od, ob)
    s.check(pen_other == pen_def, "triangles of a material without softness keep the default (bit for bit)")
    s.finish()
