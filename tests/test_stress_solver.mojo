# tier: stress
"""Solver stress scenes (17.19): mass ratio, a dense tower and a large island.

The scenes are measured first (see the constants below); the assertions are
set from those numbers, so a regression shows up as a bound being crossed.

  mass ratio  heavy box on a light one on a static floor. Penetration grows
              with the ratio because the soft contact's effective mass is the
              light body's: 10:1 gives 3 mm, 100:1 gives 3 cm, 300:1 gives 10 cm,
              and 1000:1 pushes the light box into the floor (25 cm, a full
              half-height). More iterations do not change it (60 gives the same
              collapse), so this is compliance, not an unconverged solve. The
              300:1 and 1000:1 cases are characterized, not bounded: they assert
              only that the state stays finite. This is the default path
              (`max_mass_ratio = 0`). The opt-in `SolverConfig.max_mass_ratio`
              removes the sink; `test_solver_stress` bounds it (1:1000 under
              1 cm). Its contact and joint reports are corrected by load
              propagation (17.19 A2, `stack_floor`, `hang_rig`): the true load
              within 1%, and a break threshold between the true and the scaled
              load does not trip.
  tower       ten 0.5 m boxes. The top settles to 0.029 m below its ideal height
              and then stops moving (drift over the second half < 1e-3 m).
  pile        64 boxes in a 4 x 4 x 4 block. After settling, the largest
              displacement over the last second is 0 m and the lowest box stays
              on the floor. Step time is recorded, not asserted.
"""

from std.math import isfinite
from std.time import perf_counter_ns
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.joints6 import Joint6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime MAX_SAG_100: Real = 0.05  # measured 0.0295 at 100:1
comptime MAX_DRIFT_TOWER: Real = 1e-3  # measured 0.0 over the second half
comptime MAX_TOWER_SAG: Real = 0.05  # measured 0.029
comptime MAX_PILE_MOTION: Real = 1e-3  # measured 0.0
comptime MIN_PILE_LOW: Real = 0.24  # measured 0.2488 (box half-height 0.25)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)), Vec3(10, 1, 10, 0), True)


def mass_ratio(ratio: Real, steps: Int, max_mass_ratio: Real = 0) raises -> Real:
    """Worst offset of either box from its ideal position, over the run.
    `max_mass_ratio` (17.19, 0 = off) is the opt-in mass scaling."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var light = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var heavy = sc.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(ratio, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var worst = Real(0)
    for _ in range(steps):
        sc.step_soft(DT, G, max_mass_ratio=max_mass_ratio)
        var yl = sc.bset.bodies[light.index()].position()[1]
        var yh = sc.bset.bodies[heavy.index()].position()[1]
        worst = max(worst, abs(Real(0.25) - yl), abs((yh - yl) - Real(0.5)))
    print("  mass ratio", ratio, "worst offset", worst, "final light y", sc.bset.bodies[light.index()].position()[1])
    return worst


def stack_floor(heavy: Real, lights: Int, ratio: Real, push: Real = 0) raises -> Real:
    """Floor force (N, upward) on the bottom box of a column: `lights` 1 kg
    boxes under one `heavy` box, with a downward `push` on the heavy one.
    The true floor load is (heavy + lights) g + push; with `max_mass_ratio`
    on, the report must match it (17.19 A2), not the scaled (m_c) load."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    cfg.lin_sleep_tol = 0  # a sleeping stack reports no contact impulses
    cfg.ang_sleep_tol = 0
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var bottom = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for k in range(1, lights):
        _ = sc.add(QuatBody6.at_rest(Vec3(0, Real(0.25) + Real(k) * Real(0.5), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var top = sc.add(QuatBody6.at_rest(Vec3(0, Real(0.25) + Real(lights) * Real(0.5), 0, 0), Inertia3.box(heavy, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(60):
        if push != 0:
            sc.add_force(top, Vec3(0, -push, 0, 0))
        sc.step(DT, G, cfg)
    var f = Real(0)
    for r in sc.contacts_of(bottom):
        if r.other == 0:
            f += r.force[1]
    print("  stack", heavy, "on", lights, "light, ratio", ratio, "push", push, "floor", f, "true", (heavy + Real(lights)) * 9.8 + push)
    return f


def hang_rig(ratio: Real, break_force: Real, steps: Int) raises -> List[Real]:
    """Returns [upward joint force on the light box, 1 if the top joint broke
    after it settled]. A static ceiling holds a 1 kg box by a ball joint, and
    that box holds a 1000 kg box by a second one. The top joint's true load is
    1001 g. At `ratio` the light box's mass in the solve is 100 kg, so the raw
    joint load is about 10780 N; the report must correct that to 9810 N (17.19
    A2). The break threshold arms after 120 steps: the start from rest
    overshoots (10412 N at step 1), and that transient is not the steady load."""
    var cfg = SolverConfig()
    cfg.max_mass_ratio = ratio
    var sc = ContactScene6[QuatBody6]()
    var ceil = sc.add(QuatBody6.at_rest(Vec3(0, 10, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
    var light = sc.add(QuatBody6.at_rest(Vec3(0, 9.5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var heavy = sc.add(QuatBody6.at_rest(Vec3(0, 8.5, 0, 0), Inertia3.box(1000, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add_joint(Joint6.ball(ceil.index(), light.index(), Vec3(0, 0, 0, 0), Vec3(0, 0.5, 0, 0)))
    _ = sc.add_joint(Joint6.ball(light.index(), heavy.index(), Vec3(0, -0.5, 0, 0), Vec3(0, 0.5, 0, 0)))
    var broke = Real(0)
    var f = Real(0)
    for s in range(steps):
        if s == 120:
            sc.set_joint_break(0, break_force, 1e9)
        sc.step(DT, G, cfg)
        if len(sc.broken_joints) > 0:
            broke = 1
        f = sc.joint_reaction(0)[0][1]
    print("  hang ratio", ratio, "break", break_force, "top joint up", f, "broke", broke)
    var out = List[Real]()
    out.append(f)
    out.append(broke)
    return out^


def tower(n: Int, steps: Int) raises -> List[Real]:
    """Returns [top sag below its ideal height, drift over the second half]."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var ids = List[Int]()
    for k in range(n):
        var y = Real(0.25) + Real(k) * Real(0.5) + Real(0.01)
        ids.append(sc.add(QuatBody6.at_rest(Vec3(0, y, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False).index())
    var y_mid = Real(0)
    var t0 = Int(perf_counter_ns())
    for s in range(steps):
        sc.step_soft(DT, G)
        if s == steps // 2:
            y_mid = sc.bset.bodies[ids[n - 1]].position()[1]
    var ms = Real(Int(perf_counter_ns()) - t0) / Real(steps) / 1e6
    var y_end = sc.bset.bodies[ids[n - 1]].position()[1]
    var ideal = Real(0.25) + Real(n - 1) * Real(0.5)
    print("  tower", n, "top y", y_end, "ideal", ideal, "drift second half", abs(y_end - y_mid), "ms/step", ms)
    var out = List[Real]()
    out.append(ideal - y_end)
    out.append(abs(y_end - y_mid))
    out.append(ms)
    return out^


def pile(side: Int, steps: Int) raises -> List[Real]:
    """Returns [largest displacement over the last second, lowest y, ms/step]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 20, 1, 20)), Vec3(20, 1, 20, 0), True)
    var ids = List[Int]()
    for i in range(side):
        for j in range(side):
            for k in range(side):
                var p = Vec3(Real(i) * 0.6 - Real(side) * 0.3, Real(0.3) + Real(j) * 0.6 + Real(0.1), Real(k) * 0.6 - Real(side) * 0.3, 0)
                ids.append(sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False).index())
    var t0 = Int(perf_counter_ns())
    var mid = List[Vec3]()
    for s in range(steps):
        sc.step_soft(DT, G)
        if s == steps - 60:
            for q in range(len(ids)):
                mid.append(sc.bset.bodies[ids[q]].position())
    var ms = Real(Int(perf_counter_ns()) - t0) / Real(steps) / 1e6
    var motion = Real(0)
    var lowest = Real(100)
    for q in range(len(ids)):
        var p = sc.bset.bodies[ids[q]].position()
        var d = p - mid[q]
        motion = max(motion, abs(d[0]), abs(d[1]), abs(d[2]))
        lowest = min(lowest, p[1])
    print("  pile", len(ids), "bodies: motion over last second", motion, "lowest y", lowest, "ms/step", ms)
    var out = List[Real]()
    out.append(motion)
    out.append(lowest)
    out.append(ms)
    return out^


def main() raises:
    var s = Suite("stress_solver")

    var w10 = mass_ratio(10, 600)
    var w100 = mass_ratio(100, 600)
    var w300 = mass_ratio(300, 600)
    var w1000 = mass_ratio(1000, 600)
    s.check(w10 < 0.01, "mass ratio 10:1 keeps the stack within 1 cm")
    s.check(w100 < MAX_SAG_100, "mass ratio 100:1 keeps the stack within 5 cm (measured 3 cm)")
    s.check(isfinite(w300) and isfinite(w1000), "mass ratio 300:1 and 1000:1 stay finite (characterized: 10 cm and 25 cm, not bounded)")
    s.check(w300 > w100 and w1000 > w300, "penetration grows with the mass ratio")
    # 17.19 opt-in through step_soft: the same 1000:1 stack with max_mass_ratio = 10
    var w1000_on = mass_ratio(1000, 600, 10)
    print("  mass ratio 1000:1 with max_mass_ratio 10, worst offset", w1000_on)
    s.check(w1000_on < 0.01, "mass ratio 1000:1 with max_mass_ratio 10 stays within 1 cm (step_soft opt-in)")
    # 17.19 A2: the floor reading carries the true load, not the scaled one
    # (measured before the correction: 1200 g at 2 lights, ratio 10)
    var c3 = stack_floor(1000, 2, 10)
    var c2 = stack_floor(1000, 1, 100)
    var cp = stack_floor(1000, 1, 10, 500)
    s.check(abs(c3 - 1002 * 9.8) < 0.01 * 1002 * 9.8, "stack 1000 on 2 kg at ratio 10: floor within 1% of the true 1002 g")
    s.check(abs(c2 - 1001 * 9.8) < 0.01 * 1001 * 9.8, "stack 1000 on 1 kg at ratio 100: floor within 1% of the true 1001 g")
    s.check(abs(cp - (1001 * 9.8 + 500)) < 0.01 * (1001 * 9.8 + 500), "stack 1000 on 1 kg with a 500 N push at ratio 10: floor within 1%")

    # 17.19 A2 joints: the top joint of a hanging rig reads its true load, and a
    # break threshold above that load does not trip. Uncorrected, the raw load
    # (~10780 N) would trip the 10000 N threshold at ratio 10.
    # (ratio 0 is not a reference here: its 1000:1 soft joint rings with
    # peaks near 13500 N, the known compliance of test_solver_stress above)
    var h10 = hang_rig(10, 10000, 240)
    var hb = hang_rig(10, 9500, 240)
    s.check(abs(h10[0] - 1001 * 9.8) < 0.01 * 1001 * 9.8, "hanging rig at ratio 10: top joint reads the true 1001 g within 1%")
    s.check(h10[1] == 0, "hanging rig at ratio 10: 10000 N break threshold does not trip (raw load 10780 N would)")
    s.check(hb[1] == 1, "hanging rig at ratio 10: 9500 N threshold (below the true 9810 N) trips")

    var t = tower(10, 900)
    s.check(t[0] < MAX_TOWER_SAG, "ten-box tower settles within 5 cm of its ideal height (measured 3 cm)")
    s.check(t[1] < MAX_DRIFT_TOWER, "ten-box tower is still over its second half (drift < 1 mm)")

    var p = pile(4, 600)
    s.check(p[0] < MAX_PILE_MOTION, "64-box pile is still after settling (motion over the last second < 1 mm)")
    s.check(p[1] > MIN_PILE_LOW, "no box in the 64-box pile sinks into the floor")
    s.finish()
