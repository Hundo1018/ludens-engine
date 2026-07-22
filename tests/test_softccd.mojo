from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _wall_scene() -> ContactScene6[QuatBody6]:
    """Soft cube fired at 120 m/s at a thin static wall. Per-substep travel
    (0.5 m) clears the wall's inflated thickness (0.12 m) at every lattice
    plane's sampling phase, so the discrete particle-vs-box test never sees
    a hit: without CCD all 64 particles fly straight through."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, 1, 0), Inertia3.box(1, 0.01, 2, 2)),
        Vec3(0.01, 2, 2),
        True,
    )
    var sb = SoftBody.box_lattice(
        Vec3(-1, 1, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    for i in range(len(sb.pts)):
        var p = sb.pts[i]
        p.v = Vec3(120, 0, 0)
        sb.pts[i] = p
    _ = sc.add_soft(sb^)
    return sc^


def _max_x(sc: ContactScene6[QuatBody6]) -> Float64:
    var mx = Float64(-1e30)
    for i in range(len(sc.softs[0].pts)):
        var x = Float64(sc.softs[0].pts[i].x[0])
        if x > mx:
            mx = x
    return mx


def _jelly(alpha: Real, damp: Real) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var sb = SoftBody.box_lattice(
        Vec3(0, 1.0, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, alpha
    )
    sb.damp = damp
    _ = sc.add_soft(sb^)
    return sc^


def _plate_slam(ccd: Bool) raises -> Vec3:
    """Settle a stiff dissipative cube, then slam a thin light plate into it
    at 40 m/s: per-substep travel (16.7 cm) clears the plate's inflated
    thickness (14 cm), so the discrete test can skip every particle plane —
    a 40-cm-thick box can't show this (its faces always get sampled; the
    sweep provably matches the discrete answer there). Returns (lowest plate
    bottom over the run, final cube top)."""
    var sc = _jelly(1e-5, 0.97)
    for _ in range(240):
        sc.step_soft(DT, G, ccd=ccd)
    var top = Float64(sc.softs[0].top_y())
    var plate = sc.add(
        QuatBody6.at_rest(
            Vec3(0, Real(top) + 0.5, 0), Inertia3.box(0.3, 0.25, 0.02, 0.25)
        ),
        Vec3(0.25, 0.02, 0.25),
        False,
    )
    sc.bodies[plate].vel = Vec3(0, -40, 0)
    var min_bot = Float64(1e30)
    for _ in range(240):
        sc.step_soft(DT, G, ccd=ccd)
        var bb = Float64(sc.bodies[plate].pos[1]) - 0.02
        if bb < min_bot:
            min_bot = bb
    return Vec3(Real(min_bot), sc.softs[0].top_y(), 0)


def main() raises:
    var s = Suite("softccd")

    # 1. Control: the discrete test really does miss (the gate bites).
    var ctrl = _wall_scene()
    for _ in range(5):
        ctrl.step_soft(DT, G)
    var thru = _max_x(ctrl)
    print("  no-ccd max particle x:", thru)
    s.check(thru > 0.5, "without ccd the bullet cube tunnels the wall")

    # 2. With ccd every particle is swept and stops at the wall face.
    var wsc = _wall_scene()
    for _ in range(5):
        wsc.step_soft(DT, G, ccd=True)
    var stopped = _max_x(wsc)
    print("  ccd max particle x:", stopped)
    s.check(stopped < 0.0, "ccd stops every particle at the wall")

    # 3. Fast thin DYNAMIC plate vs settled cube: the moving-box side of the
    #    sweep (relative motion carries the plate's own displacement).
    var pc = _plate_slam(True)
    print(
        "  plate ccd: min bottom", Float64(pc[0]), "cube top", Float64(pc[1])
    )
    s.check(pc[0] > 0.15, "ccd: plate caught by the cube, never nears floor")
    s.check(pc[1] > 0.3, "ccd: cube survives the plate impact")
    var pn = _plate_slam(False)
    print("  plate no-ccd: min bottom", Float64(pn[0]))
    s.check(pn[0] < 0.05, "without ccd the plate slices through (test bites)")

    # 4. Zero-regression: on a slow scene the sweep never fires, so
    #    ccd=True and ccd=False are bit-identical (rigid swept advance
    #    already guarantees the same for slow bodies).
    var ga = _jelly(1e-3, 0.999)
    var gb = _jelly(1e-3, 0.999)
    for _ in range(240):
        ga.step_soft(DT, G)
        gb.step_soft(DT, G, ccd=True)
    var ra = ga.add(
        QuatBody6.at_rest(Vec3(0, 0.85, 0), Inertia3.box(1.0, 0.2, 0.2, 0.2)),
        Vec3(0.2, 0.2, 0.2),
        False,
    )
    var rb = gb.add(
        QuatBody6.at_rest(Vec3(0, 0.85, 0), Inertia3.box(1.0, 0.2, 0.2, 0.2)),
        Vec3(0.2, 0.2, 0.2),
        False,
    )
    for _ in range(300):
        ga.step_soft(DT, G)
        gb.step_soft(DT, G, ccd=True)
    var same = True
    var dp = ga.bodies[ra].pos - gb.bodies[rb].pos
    if dp[0] != 0 or dp[1] != 0 or dp[2] != 0:
        same = False
    for i in range(len(ga.softs[0].pts)):
        var d = ga.softs[0].pts[i].x - gb.softs[0].pts[i].x
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            same = False
    s.check(same, "slow scene: ccd on/off bit-identical (zero regression)")

    s.finish()
