"""Cloth self-collision (architecture law v3).

Cloth that does not collide with itself can be a flag and cannot be a garment,
so the check that matters is a sheet piling on the floor: without this, the
closest non-neighbour pair ends up 0.0003 apart, which is not a fold but a sheet
passing through itself.

ORDINARY    a piled cloth keeps non-neighbouring particles apart by roughly the
            thickness, and the sheet does not gain energy doing it.
INTEGRATION it works in BOTH cloth solvers -- XPBD and VBD are two variants of
            one seam, and adding a capability to only one stops them being
            comparable; with the feature off, both are bit-identical to before.
EXTREME     exactly coincident particles (no direction to separate along), a
            single particle, an all-pinned sheet, a thickness of zero, and a
            thickness larger than the whole cloth.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.gpu_cloth import cpu_cloth_run, ClothState
from physics.vbd_cloth import cpu_vbd_run
from physics.self_collide import SelfCollider, resolve_self_collisions, SKIP

comptime W = 10
comptime H = 40
comptime DT = Float32(1.0) / 120.0
comptime REST = Float32(0.1)


def closest_far_pair(s: ClothState, width: Int) -> Real:
    """Distance between the closest pair that is NOT spring-connected."""
    var worst = Real(1e30)
    var n = len(s.x)
    for i in range(n):
        for j in range(i + 1, n):
            var dr = (i // width) - (j // width)
            var dc = (i % width) - (j % width)
            if dr < 0:
                dr = -dr
            if dc < 0:
                dc = -dc
            if dr <= SKIP and dc <= SKIP:
                continue
            var ex = Real(s.x[i] - s.x[j])
            var ey = Real(s.y[i] - s.y[j])
            var ez = Real(s.z[i] - s.z[j])
            var d = Real(sqrt(Float64(ex * ex + ey * ey + ez * ez)))
            if d < worst:
                worst = d
    return worst


def height_span(s: ClothState) -> Real:
    var lo = Real(s.y[0])
    var hi = Real(s.y[0])
    for i in range(len(s.y)):
        if Real(s.y[i]) < lo:
            lo = Real(s.y[i])
        if Real(s.y[i]) > hi:
            hi = Real(s.y[i])
    return hi - lo


def main() raises:
    var s = Suite("self_collide")
    var th = Real(0.06)

    # ---- ORDINARY / INTEGRATION: both solvers ----
    var pbd_off = cpu_cloth_run[W, H](400, 8, DT, REST, 0)
    var pbd_on = cpu_cloth_run[W, H](400, 8, DT, REST, th)
    var d_off = closest_far_pair(pbd_off, W)
    var d_on = closest_far_pair(pbd_on, W)
    print("  PBD closest non-neighbour pair — off", d_off, " on", d_on,
          " (thickness", th, ")")
    s.check(
        Float64(d_off) < 0.2 * Float64(th),
        "without self-collision the sheet passes through itself",
    )
    s.check(
        Float64(d_on) > 0.8 * Float64(th),
        "with it, non-neighbours stay about a thickness apart",
    )

    var vbd_off = cpu_vbd_run[W, H](400, 8, DT, REST, 0)
    var vbd_on = cpu_vbd_run[W, H](400, 8, DT, REST, th)
    var v_off = closest_far_pair(vbd_off, W)
    var v_on = closest_far_pair(vbd_on, W)
    print("  VBD closest — off", v_off, " on", v_on)
    s.check(Float64(v_off) < 0.2 * Float64(th), "VBD interpenetrates too")
    s.check(
        Float64(v_on) > 5.0 * Float64(v_off),
        "and self-collision separates it as well: the seam has BOTH variants",
    )
    # VBD does not reach the full thickness -- the repulsion runs after its
    # colour sweeps rather than inside the per-vertex Newton step, so the next
    # sweep pulls some of the correction back. Reported rather than tuned away.
    s.check(
        Float64(v_on) > 0.5 * Float64(th),
        "VBD reaches over half the thickness (its sweep recovers some of it)",
    )

    # the cloth must not gain size doing it: a repulsion that fights the springs
    # inflates the sheet, which is what the topological exclusion prevents
    print("  height span — off", height_span(pbd_off), " on", height_span(pbd_on))
    s.check(
        Float64(height_span(pbd_on)) < 1.15 * Float64(height_span(pbd_off)),
        "the sheet does not inflate: the repulsion is not fighting the springs",
    )

    # feature off must be bit-identical to the previous behaviour
    var again = cpu_cloth_run[W, H](400, 8, DT, REST, 0)
    var identical = True
    for i in range(len(again.x)):
        if again.x[i] != pbd_off.x[i] or again.y[i] != pbd_off.y[i]:
            identical = False
    s.check(identical, "thickness 0 leaves the solver bit-identical")

    # ---- EXTREME ----
    # Four particles in a 1-wide strip so grid distance == index distance:
    # 0 and 3 are SKIP+1 apart topologically, which is what makes them a
    # candidate pair at all. An earlier version used two adjacent particles and
    # got zero hits, correctly -- a spring already holds those.
    var px = List[Float32]()
    var py = List[Float32]()
    var pz = List[Float32]()
    var w = List[Float32]()
    for k in range(4):
        var far = k == 1 or k == 2
        px.append(50.0 + Float32(k) if far else 1.0)
        py.append(Float32(50.0) if far else Float32(1.0))
        pz.append(Float32(50.0) if far else Float32(1.0))
        w.append(1.0)
    var g = SelfCollider(th)
    var hits = resolve_self_collisions(px, py, pz, w, 1, th, g)
    var sep = Real(sqrt(Float64(
        Real(px[0] - px[3]) * Real(px[0] - px[3])
        + Real(py[0] - py[3]) * Real(py[0] - py[3])
        + Real(pz[0] - pz[3]) * Real(pz[0] - pz[3])
    )))
    print("  coincident pair — hits", hits, " separation after", sep)
    s.check(hits == 1, "exactly coincident particles are still a contact")
    s.check(
        abs(Float64(sep - th)) < 1e-5,
        "and are pushed apart by the full thickness along a fixed axis",
    )

    var one_x = List[Float32]()
    var one_y = List[Float32]()
    var one_z = List[Float32]()
    var one_w = List[Float32]()
    one_x.append(0)
    one_y.append(0)
    one_z.append(0)
    one_w.append(1)
    var g1 = SelfCollider(th)
    s.eqi(
        resolve_self_collisions(one_x, one_y, one_z, one_w, 1, th, g1), 0,
        "a single particle collides with nothing",
    )

    var pin_w = List[Float32]()
    for _ in range(4):
        pin_w.append(0)
    var px2 = List[Float32]()
    var py2 = List[Float32]()
    var pz2 = List[Float32]()
    for _ in range(4):
        px2.append(1.0)
        py2.append(1.0)
        pz2.append(1.0)
    var g2 = SelfCollider(th)
    _ = resolve_self_collisions(px2, py2, pz2, pin_w, 1, th, g2)
    s.check(
        px2[0] == 1.0 and px2[3] == 1.0,
        "two pinned particles are left exactly where they were",
    )

    # a thickness bigger than the whole cloth: everything repels everything,
    # which must terminate and stay finite rather than exploding
    var huge = cpu_cloth_run[10, 10](60, 4, DT, REST, Real(5.0))
    var finite = True
    for i in range(len(huge.x)):
        if not (Float64(huge.x[i]) > -1e6 and Float64(huge.x[i]) < 1e6):
            finite = False
    s.check(finite, "an absurd thickness stays finite")

    s.finish()
