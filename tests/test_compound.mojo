# tier: integration
"""Compound shapes: one body, several convex children (ROADMAP 17.44).

  1. Ordinary:
     - mass properties: a box (half 0.5, 0.1, 0.1) plus a sphere (r 0.2)
       at (0.5, 0.3, 0): total mass, centre of mass and principal moments
       against the same sums done by hand in Float64 (parallel axis theorem,
       products of inertia included, eigenvalues of the 3x3 tensor);
     - an L (two boxes) dropped on a floor comes to rest with its lowest
       point on the floor.
  2. Integration:
     - a single-child compound is bit-identical to the plain box
       (same density, same drop);
     - two half-boxes side by side rest at the height of the whole box
       (within the penetration slop: 8 soft contact points sink less than 4);
     - brute pair loop and BVH broadphase give bit-identical trajectories;
     - snapshot round trip steps bit-identically;
     - a removed compound's slot reused by a sphere keeps no children.
  3. Extreme: no children, a non-unit child rotation, a zero-size child and
     density 0 raise; 1000 sphere children build and rest.
"""

from std.math import sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.mat3 import Mat3x3, sym_eigen3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from collision.collider_set import CompoundSpec, SHAPE_COMPOUND
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)


def _body(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _lowest(sc: ContactScene6[QuatBody6], i: Int) -> Real:
    """Lowest world y over the corners of every box child of compound i."""
    var low = Real(1e9)
    var pose = sc.bset.bodies[i]
    var cid = sc.colliders.mesh_id[i]
    for k in range(sc.colliders.comp_n[cid]):
        var r = sc.colliders.comp_first[cid] + k
        var h = sc.colliders.kid_desc[r].half
        for c in range(8):
            var l = Vec3(h[0] * Real(1 if c & 1 else -1), h[1] * Real(1 if c & 2 else -1), h[2] * Real(1 if c & 4 else -1), 0)
            var w = pose.act(sc.colliders.kid_pos[r] + sc.colliders.kid_rot[r].rotate(l))
            low = min(low, w[1])
    return low


def _l_spec() -> CompoundSpec:
    var sp = CompoundSpec()
    sp.box(Vec3(0.5, 0.1, 0.1, 0), Vec3(0, 0, 0, 0))
    sp.box(Vec3(0.1, 0.4, 0.1, 0), Vec3(-0.4, 0.5, 0, 0))
    return sp^


def _roll(kind: Int) raises -> Real:
    """Speed after 2 s of rolling from 3 m/s: 0 a sphere body, 1 a compound
    of two r 0.5 spheres on an axle along z, 2 a compound of one capsule
    (r 0.5) lying along z."""
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    _ = f
    var id = sc.add_sphere(_body(Vec3(-5, 0.5, 0, 0)), 0.5, False)
    if kind == 1:
        var sp = CompoundSpec()
        sp.sphere(0.5, Vec3(0, 0, 0.3, 0))
        sp.sphere(0.5, Vec3(0, 0, -0.3, 0))
        sc.remove_body(id)
        id = sc.add_compound(_body(Vec3(-5, 0.5, 0, 0)), sp, 100, False)
    elif kind == 2:
        var sp = CompoundSpec()
        sp.capsule(0.5, 0.4, Vec3(0, 0, 0, 0), Quat.from_axis_angle(Vec3(1, 0, 0, 0), 1.5707963))
        sc.remove_body(id)
        id = sc.add_compound(_body(Vec3(-5, 0.5, 0, 0)), sp, 100, False)
    sc.set_sleep_thresholds(id, 0, 0)
    sc.set_velocity(id, Vec3(3, 0, 0, 0), Vec3(0, 0, -6, 0))
    for _ in range(120):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    return sc.velocity(id)[0]


def main() raises:
    var s = Suite("compound")

    # ---- mass properties against a hand sum --------------------------------
    var sp = CompoundSpec()
    sp.box(Vec3(0.5, 0.1, 0.1, 0), Vec3(0, 0, 0, 0))
    sp.sphere(0.2, Vec3(0.5, 0.3, 0, 0))
    var sc = ContactScene6[QuatBody6]()
    var id = sc.add_compound(_body(Vec3(0, 2, 0, 0)), sp, 1000, False)
    ref b = sc.bset.bodies[id.index()]
    var mb = Float64(1000 * 8 * 0.5 * 0.1 * 0.1)
    var ms = Float64(1000) * 4.0 / 3.0 * pi * 0.008
    var mt = mb + ms
    var cx = ms * 0.5 / mt
    var cy = ms * 0.3 / mt
    # tensor about the centre of mass, Float64
    var t = Mat3x3()
    var ib = (mb / 12 * (0.04 + 0.04), mb / 12 * (1.0 + 0.04), mb / 12 * (1.0 + 0.04))
    var isph = 0.4 * ms * 0.04
    var dbx = -cx
    var dby = -cy
    var dsx = 0.5 - cx
    var dsy = 0.3 - cy
    t.set(0, 0, Real(ib[0] + mb * dby * dby + isph + ms * dsy * dsy))
    t.set(1, 1, Real(ib[1] + mb * dbx * dbx + isph + ms * dsx * dsx))
    t.set(2, 2, Real(ib[2] + mb * (dbx * dbx + dby * dby) + isph + ms * (dsx * dsx + dsy * dsy)))
    t.set(0, 1, Real(-(mb * dbx * dby + ms * dsx * dsy)))
    t.set(1, 0, t.get(0, 1))
    var eig = sym_eigen3(t)
    var got = b.get_inertia()
    var gm = List[Real]()
    gm.append(got.ix)
    gm.append(got.iy)
    gm.append(got.iz)
    var wm = List[Real]()
    wm.append(eig[0][0])
    wm.append(eig[0][1])
    wm.append(eig[0][2])
    sort(gm)
    sort(wm)
    var com = b.position() - Vec3(0, 2, 0, 0)
    print("  box + sphere: mass", 1 / b.inv_mass(), "want", mt, " com", com[0], com[1], "want", cx, cy)
    print("  principal moments", gm[0], gm[1], gm[2], " hand sum", wm[0], wm[1], wm[2], " product of inertia", t.get(0, 1))
    s.check(abs(Float64(1 / b.inv_mass()) - mt) < 1e-4 * mt, "total mass = box + sphere")
    s.check(abs(Float64(com[0]) - cx) < 1e-5 and abs(Float64(com[1]) - cy) < 1e-5, "centre of mass = the mass-weighted mean")
    var ok = True
    for k in range(3):
        if abs(gm[k] - wm[k]) > 1e-4 * wm[2]:
            ok = False
    s.check(ok, "principal moments = eigenvalues of the hand-summed tensor (products included)")
    s.check(abs(t.get(0, 1)) > 1e-3, "the case has a product of inertia (a diagonal-only sum would be wrong)")

    # ---- L at rest ------------------------------------------------------------
    var ls = ContactScene6[QuatBody6]()
    _floor(ls)
    var li = ls.add_compound(_body(Vec3(0, 0.6, 0, 0)), _l_spec(), 500, False)
    ls.set_can_sleep(li, False)
    for _ in range(240):
        ls.step_soft(DT, G)
    var low = _lowest(ls, li.index())
    var v = ls.velocity(li)
    print("  L after 4 s: lowest corner y", low, " speed", sqrt(dot(v, v)))
    s.check(abs(low) < 3e-3 and sqrt(dot(v, v)) < 1e-2, "L rests with its lowest corner on the floor")

    # ---- single child == plain box -------------------------------------------
    var h1 = Vec3(0.3, 0.2, 0.25, 0)
    var rho = Real(700)
    var mass1 = rho * 8 * h1[0] * h1[1] * h1[2]
    var pa = ContactScene6[QuatBody6]()
    _floor(pa)
    var tilt = Quat.from_axis_angle(Vec3(1, 0, 1, 0), 0.3)
    var ba = QuatBody6.at_rest(Vec3(0.1, 0.8, -0.2, 0), Inertia3.box(mass1, h1[0], h1[1], h1[2]))
    ba.q = tilt
    var ia = pa.add(ba^, h1, False)
    var pb = ContactScene6[QuatBody6]()
    _floor(pb)
    var one = CompoundSpec()
    one.box(h1, Vec3(0, 0, 0, 0))
    var bb = _body(Vec3(0.1, 0.8, -0.2, 0))
    bb.q = tilt
    var ib1 = pb.add_compound(bb^, one, rho, False)
    var same = True
    for _ in range(120):
        pa.step_soft(DT, G)
        pb.step_soft(DT, G)
        if pa.bset.bodies[ia.index()].pos != pb.bset.bodies[ib1.index()].pos:
            same = False
    print("  single child vs plain box after 2 s: y", pa.pose(ia).pos[1], pb.pose(ib1).pos[1])
    s.check(same, "single-child compound == plain box, bit for bit")

    # ---- two halves == whole -------------------------------------------------
    var hw = ContactScene6[QuatBody6]()
    _floor(hw)
    var two = CompoundSpec()
    two.box(Vec3(0.25, 0.25, 0.5, 0), Vec3(-0.25, 0, 0, 0))
    two.box(Vec3(0.25, 0.25, 0.5, 0), Vec3(0.25, 0, 0, 0))
    var ihalf = hw.add_compound(_body(Vec3(0, 0.3, 0, 0)), two, 400, False)
    var iw = hw.add(QuatBody6.at_rest(Vec3(3, 0.3, 0, 0), Inertia3.box(400, 0.5, 0.25, 0.5)), Vec3(0.5, 0.25, 0.5, 0), False)
    hw.set_can_sleep(ihalf, False)
    hw.set_can_sleep(iw, False)
    for _ in range(120):
        hw.step_soft(DT, G)
    print("  two halves y", hw.pose(ihalf).pos[1], " whole box y", hw.pose(iw).pos[1])
    # 8 contact points (two 4-point patches) carry the weight where the
    # whole box has 4, so each soft contact sinks less: both rest inside
    # the penetration slop (0.005), 2.6e-4 apart
    s.check(abs(hw.pose(ihalf).pos[1] - 0.25) < 5e-3 and abs(hw.pose(iw).pos[1] - 0.25) < 5e-3, "two half-boxes and the whole box both rest at y = 0.25 within the slop")
    s.check(abs(hw.pose(ihalf).pos[1] - hw.pose(iw).pos[1]) < 1e-3, "and within 1 mm of each other")

    # ---- brute vs broadphase, snapshot ---------------------------------------
    var sa = ContactScene6[QuatBody6]()
    var sb2 = ContactScene6[QuatBody6]()
    _floor(sa)
    _floor(sb2)
    for k in range(4):
        var p = Vec3(Real(k) * 0.3 - 0.45, 0.6 + Real(k) * 0.7, Real(k % 2) * 0.2, 0)
        _ = sa.add_compound(_body(p), _l_spec(), 500, False)
        _ = sb2.add_compound(_body(p), _l_spec(), 500, False)
    for _ in range(90):
        sa.step_soft(DT, G)
        sb2.step_soft(DT, G, broadphase=True)
    var bp_same = True
    for k in range(1, 5):
        if sa.bset.bodies[k].pos != sb2.bset.bodies[k].pos or sa.bset.bodies[k].q.w != sb2.bset.bodies[k].q.w:
            bp_same = False
    s.check(bp_same, "4 L shapes piling up: brute == BVH broadphase, bit for bit")
    var blob = scene_to_string(sa)
    var rs = scene_from_string(blob)
    s.check(scene_to_string(rs) == blob, "snapshot with compounds: re-serialised blob identical")
    var snap_same = True
    for _ in range(60):
        sa.step_soft(DT, G)
        rs.step_soft(DT, G)
    for k in range(1, 5):
        if sa.bset.bodies[k].pos != rs.bset.bodies[k].pos:
            snap_same = False
    s.check(snap_same, "restored compound scene steps bit-identically")

    # ---- slot reuse --------------------------------------------------------------
    var ru = ContactScene6[QuatBody6]()
    _floor(ru)
    var ci = ru.add_compound(_body(Vec3(0, 1, 0, 0)), _l_spec(), 500, False)
    ru.remove_body(ci)
    var si = ru.add_sphere(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.sphere(1, 0.3)), 0.3, False)
    s.check(si.index() == ci.index() and ru.colliders.shape[si.index()] != SHAPE_COMPOUND, "reused slot is a plain sphere")
    for _ in range(90):
        ru.step_soft(DT, G)
    s.check(abs(ru.pose(si).pos[1] - 0.3) < 3e-3, "and rests at y = r (no stale children)")

    # ---- queries -------------------------------------------------------------------
    var qs = ContactScene6[QuatBody6]()
    var qi = qs.add_compound(_body(Vec3(0, 0, 0, 0)), _l_spec(), 500, True)
    # the static L keeps its frame where the centre of mass is: child
    # placements in the world are what the spec said
    var down = qs.ray_cast(Vec3(-0.4, 3, 0, 0), Vec3(0, -1, 0, 0), 10, QueryFilter(0xFFFFFFFF, -1, False))
    var side = qs.ray_cast(Vec3(3, 0, 0, 0), Vec3(-1, 0, 0, 0), 10, QueryFilter(0xFFFFFFFF, -1, False))
    var pd = qs.closest_point(qi.index(), Vec3(0.2, 1.0, 0, 0))
    print("  L queries: ray down onto the upright t", down.t, " ray along -x t", side.t, " distance from (0.2, 1, 0)", pd.dist)
    s.check(down.hit and abs(down.t - 2.1) < 1e-4, "ray down hits the upright's top (y = 0.9) at t = 2.1")
    s.check(side.hit and abs(side.t - 2.5) < 1e-4, "ray along -x hits the bar's end (x = 0.5) at t = 2.5")
    s.check(abs(pd.dist - sqrt(Real(0.26))) < 1e-4, "point (0.2, 1, 0): sqrt(0.5^2 + 0.1^2) from the upright's top corner")

    # ---- extremes --------------------------------------------------------------
    var raised = 0
    var ex = ContactScene6[QuatBody6]()
    try:
        _ = ex.add_compound(_body(Vec3(0, 1, 0, 0)), CompoundSpec(), 1, False)
    except:
        raised += 1
    var nq = CompoundSpec()
    nq.box(Vec3(0.1, 0.1, 0.1, 0), Vec3(0, 0, 0, 0), Quat(0, 0, 0, 2))
    try:
        _ = ex.add_compound(_body(Vec3(0, 1, 0, 0)), nq, 1, False)
    except:
        raised += 1
    var zs = CompoundSpec()
    zs.box(Vec3(0.1, 0, 0.1, 0), Vec3(0, 0, 0, 0))
    try:
        _ = ex.add_compound(_body(Vec3(0, 1, 0, 0)), zs, 1, False)
    except:
        raised += 1
    try:
        _ = ex.add_compound(_body(Vec3(0, 1, 0, 0)), _l_spec(), 0, False)
    except:
        raised += 1
    s.eqi(raised, 4, "no children / non-unit rotation / zero size / zero density raise")
    var big = CompoundSpec()
    for k in range(1000):
        big.sphere(0.05, Vec3(Real(k % 10) * 0.1 - 0.45, Real((k // 10) % 10) * 0.1, Real(k // 100) * 0.1 - 0.45, 0))
    var bs = ContactScene6[QuatBody6]()
    _floor(bs)
    var bi = bs.add_compound(_body(Vec3(0, 0.2, 0, 0)), big, 100, False)
    bs.set_can_sleep(bi, False)
    for _ in range(60):
        bs.step_soft(DT, G)
    var bv = bs.velocity(bi)
    print("  1000-sphere compound after 1 s: y", bs.pose(bi).pos[1], " speed", sqrt(dot(bv, bv)))
    s.check(sqrt(dot(bv, bv)) < 0.05 and bs.pose(bi).pos[1] > 0.4, "1000 children build and rest")
    # ---- rolling round children (17.44): anchors follow the rolling surface ----
    var roll_s = _roll(0)
    var roll_c = _roll(1)
    var roll_p = _roll(2)
    print("  rolling at 3 m/s for 2 s on a 20 m floor: sphere body", roll_s, " two-sphere compound", roll_c, " capsule-child compound", roll_p, "m/s")
    s.check(abs(roll_c - 3) < 0.03 and abs(roll_p - 3) < 0.03, "compounds with sphere / capsule children roll on without friction drag (within 1 %)")
    s.finish()
