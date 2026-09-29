# tier: integration
"""Heightfield deformation at run time (ROADMAP 17.30).

  ordinary     digging a crater under a crate that had fallen asleep on
               flat terrain wakes it and it settles at the crater floor; a
               world-query ray reads the new height.
  seam parity  the field's world AABB after a sequence of edits (raise a
               peak, dig it back out, dig elsewhere) is identical whether
               re-derived from the block summary or by rescanning every
               height.
  extreme      an edit entirely outside the grid, and a zero radius, change
               nothing; deforming a non-heightfield body raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _flat(mut sc: ContactScene6[QuatBody6]) raises -> Int:
    var h = List[Real](length=64 * 64, fill=0)
    return sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), h, 64, 64, 0.5, -16, -16).index()


def main() raises:
    var s = Suite("terrain_deform")

    var sc = ContactScene6[QuatBody6]()
    var hf = _flat(sc)
    var cr = sc.add(QuatBody6.at_rest(Vec3(0.1, 0.25, 0.1, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    for _ in range(120):
        sc.step_soft(DT, G)
    s.check(sc.bset.sleeping[cr.index()], "(setup) the crate sleeps on flat terrain")
    var edited = sc.deform_heightfield(sc.bset.id_of(hf), 0, 0, 2, -1)
    s.check(edited > 0, "the crater edits corners")
    s.check(not sc.bset.sleeping[cr.index()], "digging under a sleeping crate wakes it")
    for _ in range(180):
        sc.step_soft(DT, G)
    var y = sc.bset.bodies[cr.index()].position()[1]
    print("  crate after the crater:", y, " edited corners", edited)
    s.check(y < -0.6, "and it settles into the crater")
    var hit = sc.ray_cast(Vec3(1.5, 5, 0.3, 0), Vec3(0, -1, 0, 0), 20, QueryFilter.ignoring(cr.index()))
    var want = Real(-1 * (1 - (1.5 * 1.5 + 0.3 * 0.3) / 4))
    s.check(hit.hit and abs(hit.point[1] - want) < 0.1, "a ray reads the dug surface")

    # ---- parity: incremental vs full bounds ---------------------------------
    var a = ContactScene6[QuatBody6]()
    var b = ContactScene6[QuatBody6]()
    var ha = _flat(a)
    var hb = _flat(b)
    var same = True
    var edits = List[Tuple[Real, Real, Real, Real]]()
    edits.append((Real(3), Real(3), Real(2), Real(4)))  # a peak
    edits.append((Real(3), Real(3), Real(2), Real(-4)))  # dig it back out (the max must SHRINK)
    edits.append((Real(-6), Real(2), Real(3), Real(-2)))
    edits.append((Real(10), Real(-10), Real(5), Real(1.5)))
    for k in range(len(edits)):
        var e = edits[k]
        _ = a.colliders.deform_heightfield(ha, e[0], e[1], e[2], e[3], True)
        _ = b.colliders.deform_heightfield(hb, e[0], e[1], e[2], e[3], False)
        var ba = a.colliders.world_aabb[ha]
        var bb = b.colliders.world_aabb[hb]
        for c in range(3):
            if ba.min[c] != bb.min[c] or ba.max[c] != bb.max[c]:
                same = False
    s.check(same, "block-summary AABB == full rescan AABB after every edit (incl. a shrinking max)")
    s.check(abs(a.colliders.world_aabb[ha].max[1] - 1.5) < 1e-4, "the max tracks the remaining bump after the peak is dug out")

    # ---- extremes -----------------------------------------------------------------
    var before = a.colliders.world_aabb[ha]
    s.eqi(a.deform_heightfield(a.bset.id_of(ha), 500, 500, 3, -5), 0, "edit outside the grid: nothing edited")
    s.eqi(a.deform_heightfield(a.bset.id_of(ha), 0, 0, 0, -5), 0, "zero radius: nothing edited")
    var after = a.colliders.world_aabb[ha]
    s.check(before.min[1] == after.min[1] and before.max[1] == after.max[1], "and the bounds are unchanged")
    var raised = False
    try:
        _ = sc.deform_heightfield(cr, 0, 0, 1, -1)
    except:
        raised = True
    s.check(raised, "deforming a non-heightfield body raises")

    s.finish()
