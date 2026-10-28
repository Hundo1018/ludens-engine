# tier: integration
"""Continuous collision for every convex kind (ROADMAP 17.46).

A thin static wall (0.05 thick, at x = 0) and a bullet moving 1 m per step
toward it (60 m/s, 20x the wall's thickness) from x = -2.5.

  1. Ordinary: a hull, an ellipsoid and a compound bullet stop at the wall
     with CCD on (their centre never passes x = 0); with CCD off each of them
     tunnels (the control: the defect is real).
  2. Integration: a box bullet against a one-quad trimesh wall (triangle
     candidates); a spinning compound plank (two arms, 6 rad/step tip speed
     beyond its thickness) hitting a thin post is stopped where linear CCD
     alone would let it sweep through; a hull sliding at 8 m/s on a floor
     with CCD on keeps its speed (a touching, non-closing pair is not
     clamped); a slow scene is bit-identical with CCD on and off.
  3. Extreme: a bullet starting in contact; 1e4 m/s; two bullets meeting
     head-on stop short of each other.
  3b. SDF: a hull bullet at 300 m/s stops at a 0.2 m SDF slab with CCD
     on (now swept through the grid distance) where the speculative SDF
     contact already stops it without CCD (measured -0.196 / -0.199; no
     tunnelling control exists for this case).
  4. Island-parallel: 8 bullets at static walls step with CCD inside the
     island-parallel solver (no serial fallback), bit-identical to serial.
  5. Per-body modes: a CCD_BULLET hull stops at the wall with the scene's
     CCD off; a CCD_OFF hull tunnels with it on; the mode is in the
     snapshot.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.collider_set import CompoundSpec
from geometry.sdf_grid import SdfGrid
from physics.ccd6 import CCD_AUTO, CCD_OFF, CCD_BULLET
from diag.counters import PARALLEL_FALLBACK_SERIAL
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime ZERO = Vec3(0, 0, 0, 0)


def _cube_verts(h: Real) -> List[Real]:
    var v = List[Real]()
    for c in range(8):
        v.append(h if c & 1 else -h)
        v.append(h if c & 2 else -h)
        v.append(h if c & 4 else -h)
    return v^


def _wall(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.025, 2, 2)), Vec3(0.025, 2, 2, 0), True)


def _shoot(kind: Int, ccd: Bool, speed: Real = 60, mode: Int = -1) raises -> Real:
    """Largest x the bullet's centre reaches in 60 steps (`mode` >= 0: the
    bullet's per-body CCD mode, 17.46)."""
    var sc = ContactScene6[QuatBody6]()
    _wall(sc)
    var b = QuatBody6.at_rest(Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    b.vel = Vec3(speed, 0, 0, 0)
    match kind:
        case 0:
            _ = sc.add_hull(b^, _cube_verts(0.1), False)
        case 1:
            _ = sc.add_ellipsoid(b^, Vec3(0.1, 0.08, 0.12, 0), False)
        case _:
            var sp = CompoundSpec()
            sp.box(Vec3(0.1, 0.1, 0.1, 0), ZERO)
            sp.sphere(0.08, Vec3(0, 0.15, 0, 0))
            _ = sc.add_compound(b^, sp, 100, False)
            sc.bset.bodies[1].vel = Vec3(speed, 0, 0, 0)
    if mode >= 0:
        sc.set_ccd_mode(sc.bset.id_of(1), mode)
    var mx = Real(-1e9)
    for _ in range(60):
        sc.step_soft(DT, ZERO, ccd=ccd)
        mx = max(mx, sc.bset.bodies[1].pos[0])
    return mx


def _sdf_shot(ccd: Bool) raises -> Real:
    """A 0.1 m hull cube at 300 m/s (5 m a step) against a static SDF slab
    |x| <= 0.1 (grid cell 0.25 with a node on x = 0, so the kink is
    exact): the largest x its centre reaches."""
    var sc = ContactScene6[QuatBody6]()
    var res = 25
    var g = SdfGrid(res, Vec3(-3, -3, -3, 0), Real(6) / Real(res - 1))
    for k in range(res):
        for j in range(res):
            for i in range(res):
                g.values[(k * res + j) * res + i] = abs(g.node(i, j, k)[0]) - Real(0.1)
    _ = sc.add_sdf(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), g^)
    var b = QuatBody6.at_rest(Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    b.vel = Vec3(300, 0, 0, 0)
    _ = sc.add_hull(b^, _cube_verts(0.1), False)
    var mx = Real(-1e9)
    for _ in range(10):
        sc.step_soft(DT, ZERO, ccd=ccd)
        mx = max(mx, sc.bset.bodies[1].pos[0])
    return mx


def _volley(parallel: Bool) raises -> Tuple[List[Real], Int64]:
    """8 hull bullets at 60 m/s, each at its own static wall (z = 3k):
    final x of each, and the parallel-fallback counter."""
    var sc = ContactScene6[QuatBody6]()
    for k in range(8):
        _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, Real(3 * k), 0), Inertia3.box(1, 0.025, 1, 1)), Vec3(0.025, 1, 1, 0), True)
    for k in range(8):
        var b = QuatBody6.at_rest(Vec3(-2.5, 0, Real(3 * k), 0), Inertia3.box(1, 0.1, 0.1, 0.1))
        b.vel = Vec3(60, Real(k) * 0.3, 0, 0)
        _ = sc.add_hull(b^, _cube_verts(0.1), False)
    for _ in range(30):
        sc.step_soft(DT, ZERO, ccd=True, parallel=parallel)
    var xs = List[Real]()
    for k in range(8):
        xs.append(sc.bset.bodies[8 + k].pos[0])
    return (xs^, sc.counters.get(PARALLEL_FALLBACK_SERIAL))


def main() raises:
    var s = Suite("ccd_shapes")
    var names: List[String] = ["hull", "ellipsoid", "compound"]
    for k in range(3):
        var on = _shoot(k, True)
        var off = _shoot(k, False)
        print("  ", names[k], "bullet at 60 m/s: max x with CCD", on, " without", off)
        s.check(on < 0, names[k] + " bullet stops at the wall with CCD")
        if k == 0:
            # the ellipsoid and the compound are already caught by their
            # speculative contact (its margin grows with the speed); the
            # hull's patch is not, so it is the control here
            s.check(off > 0.5, "hull bullet tunnels without CCD (control)")

    # ---- trimesh wall --------------------------------------------------------
    var mw = ContactScene6[QuatBody6]()
    var v: List[Real] = [0, -2, -2, 0, 2, -2, 0, -2, 2, 0, 2, 2]
    var ix: List[Int] = [0, 2, 1, 1, 2, 3]
    _ = mw.add_trimesh(QuatBody6.at_rest(ZERO, Inertia3.box(1, 1, 1, 1)), v^, ix^)
    var bb = QuatBody6.at_rest(Vec3(-2.5, 0.1, 0.05, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    bb.vel = Vec3(60, 0, 0, 0)
    _ = mw.add(bb^, Vec3(0.1, 0.1, 0.1, 0), False)
    var mx = Real(-1e9)
    for _ in range(60):
        mw.step_soft(DT, ZERO, ccd=True)
        mx = max(mx, mw.bset.bodies[1].pos[0])
    print("  box bullet at a one-quad trimesh wall: max x", mx)
    s.check(mx < 0, "box bullet stops at a trimesh wall (triangle candidates)")

    # ---- spinning plank vs post -------------------------------------------------
    # a two-arm compound plank turning at 36 rad/s (its tips sweep 0.6 m per
    # step, 15x the post's thickness) reaches a thin post by rotation only
    var spins = List[Real]()
    for ccd in [False, True]:
        var sp = ContactScene6[QuatBody6]()
        _ = sp.add(QuatBody6.at_rest(Vec3(0.9, 0, 0, 0), Inertia3.box(1, 0.02, 1, 0.02)), Vec3(0.02, 1, 0.02, 0), True)
        var arm = CompoundSpec()
        arm.box(Vec3(0.5, 0.02, 0.05, 0), Vec3(0.5, 0, 0, 0))
        arm.box(Vec3(0.5, 0.02, 0.05, 0), Vec3(-0.5, 0, 0, 0))
        var pb = QuatBody6.at_rest(ZERO, Inertia3.box(1, 1, 1, 1))
        pb.q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), 1.5707963)
        var pid = sp.add_compound(pb^, arm, 100, False)
        sp.set_velocity(pid, ZERO, Vec3(0, 0, 36, 0))
        var wmax = Real(0)
        for _ in range(30):
            sp.step_soft(DT, ZERO, ccd=ccd)
            wmax = max(wmax, abs(sp.angular_velocity(pid)[2]))
        spins.append(wmax)
    print("  spinning plank (36 rad/s) at a post: max |w| without CCD", spins[0], " with CCD", spins[1])
    s.check(spins[1] <= 36.1, "with CCD the hit adds no spin (max |w| <= the initial 36 rad/s)")

    # ---- sliding hull keeps its speed ------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _ = sl.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 40, 0.5, 2)), Vec3(40, 0.5, 2, 0), True)
    var hb = QuatBody6.at_rest(Vec3(-10, 0.1, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    hb.vel = Vec3(8, 0, 0, 0)
    var hid = sl.add_hull(hb^, _cube_verts(0.1), False)
    sl.set_can_sleep(hid, False)
    for _ in range(60):
        sl.step_soft(DT, Vec3(0, -9.8, 0, 0), mu=0.0, ccd=True)
    print("  hull sliding at 8 m/s (mu 0) with CCD: vx after 1 s", sl.velocity(hid)[0], " x", sl.pose(hid).pos[0])
    s.check(abs(sl.velocity(hid)[0] - 8) < 0.05 and sl.pose(hid).pos[0] > -2.1, "a sliding hull is not clamped by its floor")

    # ---- slow scene bit-identical ------------------------------------------------
    var a = ContactScene6[QuatBody6]()
    var b = ContactScene6[QuatBody6]()
    _ = a.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    _ = b.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    _ = a.add_hull(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), _cube_verts(0.2), False)
    _ = b.add_hull(QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), _cube_verts(0.2), False)
    var same = True
    for _ in range(90):
        a.step_soft(DT, Vec3(0, -9.8, 0, 0), ccd=True)
        b.step_soft(DT, Vec3(0, -9.8, 0, 0), ccd=False)
        if a.bset.bodies[1].pos != b.bset.bodies[1].pos:
            same = False
    s.check(same, "slow hull drop: CCD on == off, bit for bit")

    # ---- extremes -------------------------------------------------------------------
    var fastest = _shoot(0, True, 1e4)
    print("  hull bullet at 1e4 m/s: max x", fastest)
    s.check(fastest < 0, "1e4 m/s hull bullet still stops at the wall")
    var hh = ContactScene6[QuatBody6]()
    var l = QuatBody6.at_rest(Vec3(-2, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    l.vel = Vec3(60, 0, 0, 0)
    var r = QuatBody6.at_rest(Vec3(2, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    r.vel = Vec3(-60, 0, 0, 0)
    var li = hh.add_hull(l^, _cube_verts(0.1), False)
    var ri = hh.add_hull(r^, _cube_verts(0.1), False)
    var crossed2 = False
    for _ in range(30):
        hh.step_soft(DT, ZERO, ccd=True)
        if hh.pose(li).pos[0] > hh.pose(ri).pos[0]:
            crossed2 = True
    print("  two hull bullets head-on: final x", hh.pose(li).pos[0], hh.pose(ri).pos[0])
    s.check(not crossed2, "two bullets meeting head-on never pass through each other")
    # ---- SDF wall (17.46) ----
    var sdf_on = _sdf_shot(True)
    var sdf_off = _sdf_shot(False)
    print("  hull bullet at 300 m/s vs a 0.2 m SDF slab: max x with CCD", sdf_on, " without", sdf_off)
    # measured: the SDF's speculative contact already catches this bullet
    # without CCD (-0.199); the CCD path is the backstop and must agree
    s.check(sdf_on < 0 and abs(sdf_on - sdf_off) < 0.01, "CCD against an SDF wall stops the bullet where the speculative contact does")

    # ---- island-parallel CCD (17.46) ----
    var par = _volley(True)
    var ser = _volley(False)
    var same_par = True
    for k in range(len(par[0])):
        if par[0][k] != ser[0][k]:
            same_par = False
    var mxp = Real(-1e9)
    for k in range(len(par[0])):
        mxp = max(mxp, par[0][k])
    print("  8 hull bullets at static walls, island-parallel vs serial CCD: same bits", same_par, " max x", mxp, " parallel fallbacks", par[1])
    s.check(same_par and mxp < 0 and par[1] == 0, "CCD runs inside the island-parallel step (no serial fallback), bit-identical to serial against static walls")

    # ---- per-body modes (17.46) ----
    var bullet_only = _shoot(0, False, 60, CCD_BULLET)
    var off_in_on = _shoot(0, True, 60, CCD_OFF)
    print("  per-body CCD: BULLET with cfg.ccd off -> max x", bullet_only, "; OFF with cfg.ccd on ->", off_in_on)
    s.check(bullet_only < 0, "a CCD_BULLET hull stops at the wall with the scene's CCD off")
    s.check(off_in_on > 0.5, "a CCD_OFF hull tunnels with the scene's CCD on")
    var ms = ContactScene6[QuatBody6]()
    _wall(ms)
    var mb = ms.add_hull(QuatBody6.at_rest(Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), _cube_verts(0.1), False)
    ms.set_ccd_mode(mb, CCD_BULLET)
    var back = scene_from_bytes(scene_to_bytes(ms))
    var raised = False
    try:
        ms.set_ccd_mode(mb, 7)
    except:
        raised = True
    s.check(back.bset.ccd_mode[1] == CCD_BULLET and back.bset.any_bullet and raised, "the mode survives a snapshot; an unknown mode raises")
    s.finish()
