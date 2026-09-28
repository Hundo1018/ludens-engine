# tier: integration
"""ROADMAP 17.0h: the error-handling policy (docs/ARCHITECTURE.md S2) made
real on the APIs Wave A touches, plus `diag` wired into `ContactScene6`'s
production step path (audit F10, E1-E24).

Three classes, matching docs/design/17.0h-error-wiring.md:

  A. Invalid caller input at a public API -> `raise` (tests assert the raise,
     ordinary valid input still succeeds).
  B. Numerical failure -> recover locally, count, keep stepping.
  C. `diag` wired into the solver: counters (already exercised throughout),
     trace spans, debug-draw.

`self.trace`/`self.draw` are meaningful only under `-D LUDENS_TRACE` /
`-D LUDENS_DEBUG_DRAW` respectively (same `comptime if` idiom as
`tests/test_diag_trace.mojo`) -- this file passes either way `pixi run test`
runs it (both switches off) and under the acceptance run's extra
`-D LUDENS_TRACE -D LUDENS_DEBUG_DRAW` invocation (both on)."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from physics.rigid6 import Inertia3, QuatBody6, Pose6
from physics.solver6 import ContactScene6, Joint6
from physics.solver_config import SolverConfig
from physics.softbody import SoftBody
from physics.chain import Chain, ChainLink
from physics.fem import FemBody, make_beam
from collision.trimesh import TriMesh, HeightField
from collision.broadphase import BoxProxy
from collision.queries import GridQuery
from procedural.anim import AnimClip
from diag.counters import (
    NAN_QUARANTINED, COLOR_OVERFLOW, CG_NOT_CONVERGED,
)
from diag.level import TRACE_ON, DEBUG_DRAW_ON

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _raises[F: def () raises -> None](f: F) -> Bool:
    """Run `f`; True iff it raised. The one helper every Class-A check below
    goes through, so each check is a single line (same
    try/except-and-record-a-Bool idiom `test_serialize
    ._test_truncated_snapshot_raises` already established)."""
    try:
        f()
    except:
        return True
    return False


def main() raises:
    var s = Suite("error_wiring")

    # ============================================================ CLASS A
    # -- SolverConfig.validated() (E5) --
    def ok_cfg() raises:
        var cfg = SolverConfig()
        _ = cfg.validated()
    s.check(not _raises(ok_cfg), "ordinary: default SolverConfig validates")

    def bad_substeps() raises:
        var cfg = SolverConfig()
        cfg.substeps = 0
        _ = cfg.validated()
    s.check(_raises(bad_substeps), "extreme: substeps=0 raises")

    def bad_iters() raises:
        var cfg = SolverConfig()
        cfg.iters = 0
        _ = cfg.validated()
    s.check(_raises(bad_iters), "extreme: iters=0 raises")

    def bad_hertz() raises:
        var cfg = SolverConfig()
        cfg.hertz = 0
        _ = cfg.validated()
    s.check(_raises(bad_hertz), "extreme: hertz=0 raises")

    def bad_zeta() raises:
        var cfg = SolverConfig()
        cfg.zeta = -1
        _ = cfg.validated()
    s.check(_raises(bad_zeta), "extreme: zeta<0 raises")

    # -- Inertia3.validated() (E1/E2) --
    def ok_inertia() raises:
        _ = Inertia3.box(1, 1, 1, 1).validated()
    s.check(not _raises(ok_inertia), "ordinary: a unit box's inertia validates")

    def zero_mass() raises:
        _ = Inertia3.box(0, 1, 1, 1).validated()
    s.check(_raises(zero_mass), "extreme: mass=0 raises")

    def zero_moment() raises:
        _ = Inertia3(1, 0, 1, 1).validated()
    s.check(_raises(zero_moment), "extreme: a zero principal moment raises")

    # -- ContactScene6.add_joint / set_* (E12) --
    def bad_joint_index() raises:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)),
            Vec3(1, 1, 1, 0), False,
        )
        _ = sc.add_joint(Joint6.ball(0, 5, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)))
    s.check(_raises(bad_joint_index), "extreme: add_joint with an out-of-range body index raises")

    def ok_joint() raises:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)),
            Vec3(1, 1, 1, 0), False,
        )
        _ = sc.add(
            QuatBody6.at_rest(Vec3(2, 0, 0, 0), Inertia3.box(1, 1, 1, 1)),
            Vec3(1, 1, 1, 0), False,
        )
        _ = sc.add_joint(Joint6.ball(0, 1, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)))
    s.check(not _raises(ok_joint), "ordinary: add_joint with valid indices succeeds")

    def bad_set_filter() raises:
        var sc = ContactScene6[QuatBody6]()
        sc.set_filter(9, 1, 1)
    s.check(_raises(bad_set_filter), "extreme: set_filter out-of-range index raises")

    def bad_set_sensor() raises:
        var sc = ContactScene6[QuatBody6]()
        sc.set_sensor(9, True)
    s.check(_raises(bad_set_sensor), "extreme: set_sensor out-of-range index raises")

    def bad_set_restitution_index() raises:
        var sc = ContactScene6[QuatBody6]()
        sc.set_restitution(9, 0.5)
    s.check(_raises(bad_set_restitution_index), "extreme: set_restitution out-of-range index raises")

    def bad_restitution_range() raises:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)),
            Vec3(1, 1, 1, 0), False,
        )
        sc.set_restitution(0, 1.5)
    s.check(_raises(bad_restitution_range), "extreme: set_restitution e outside [0,1] raises")

    def bad_set_friction() raises:
        var sc = ContactScene6[QuatBody6]()
        sc.set_friction(9, 0.5)
    s.check(_raises(bad_set_friction), "extreme: set_friction out-of-range index raises")

    # -- SoftBody.box_lattice (E4) --
    def bad_lattice() raises:
        _ = SoftBody.box_lattice(Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0), 1, 1.0, 0.0)
    s.check(_raises(bad_lattice), "extreme: box_lattice(n=1) raises")

    def ok_lattice() raises:
        _ = SoftBody.box_lattice(Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0), 2, 1.0, 0.0)
    s.check(not _raises(ok_lattice), "ordinary: box_lattice(n=2) succeeds")

    # -- TriMesh / HeightField (E13) --
    def bad_tri_stride() raises:
        var v = List[Real]()
        for _ in range(9):
            v.append(0)
        var idx = List[Int]()
        idx.append(0)
        idx.append(1)
        _ = TriMesh(v, idx)
    s.check(_raises(bad_tri_stride), "extreme: indices len % 3 != 0 raises")

    def bad_tri_index() raises:
        var v = List[Real]()
        for _ in range(9):
            v.append(0)
        var idx = List[Int]()
        idx.append(0)
        idx.append(1)
        idx.append(99)
        _ = TriMesh(v, idx)
    s.check(_raises(bad_tri_index), "extreme: an out-of-range vertex index raises")

    def bad_field_len() raises:
        var h = List[Real]()
        h.append(0)
        _ = HeightField(h, 2, 2, 1.0)
    s.check(_raises(bad_field_len), "extreme: len(heights) != nx*nz raises")

    def bad_field_cell() raises:
        var h = List[Real]()
        for _ in range(4):
            h.append(0)
        _ = HeightField(h, 2, 2, 0.0)
    s.check(_raises(bad_field_cell), "extreme: cell <= 0 raises")

    # -- Chain.add_link_to (E18) --
    def bad_parent() raises:
        var c = Chain()
        _ = c.add_link_to(
            -2, ChainLink.revolute(
                Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1,
                Vec3(1, 1, 1, 0),
            ),
        )
    s.check(_raises(bad_parent), "extreme: add_link_to(p < -1) raises")

    # -- AnimClip (E23) --
    def bad_fps() raises:
        _ = AnimClip(4, 4, 0.0, True)
    s.check(_raises(bad_fps), "extreme: AnimClip fps<=0 raises")

    def ok_zero_frames() raises:
        _ = AnimClip(4, 0, 30.0, True)
    s.check(
        not _raises(ok_zero_frames),
        "ordinary: frames=0 is a tested recovery path, not rejected",
    )

    # -- collision.queries._index_boxes via GridQuery.rebuild (E24) --
    def bad_proxy() raises:
        var items = List[BoxProxy[3]]()
        items.append(
            BoxProxy[3](-1, AABB[3](Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0)))
        )
        var q = GridQuery[3]()
        q.rebuild(items)
    s.check(_raises(bad_proxy), "extreme: a negative proxy id raises")

    # ============================================================ CLASS B
    # -- NaN quarantine (E3-adjacent / the table's "Numerical failure" row) --
    # Two independent (far apart, never touching) falling boxes; a reference
    # scene with only the SURVIVING body, stepped identically, is the
    # strongest check the design doc offers: "bit-identical to a run where
    # that body was removed at that step".
    var nsc = ContactScene6[QuatBody6]()
    var na = nsc.add(
        QuatBody6.at_rest(Vec3(-30, 5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)),
        Vec3(0.5, 0.5, 0.5, 0), False,
    )
    var nb = nsc.add(
        QuatBody6.at_rest(Vec3(30, 5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)),
        Vec3(0.5, 0.5, 0.5, 0), False,
    )
    var rsc = ContactScene6[QuatBody6]()
    var rb = rsc.add(
        QuatBody6.at_rest(Vec3(30, 5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)),
        Vec3(0.5, 0.5, 0.5, 0), False,
    )
    nsc.step_soft(DT, G)  # one ordinary step: both bodies fine
    rsc.step_soft(DT, G)
    s.eqi(Int(nsc.counters.get(NAN_QUARANTINED)), 0, "ordinary: no quarantine yet")
    # inject a NaN into body `na`'s velocity, mid-run
    var nan = Float32(0.0) / Float32(0.0)
    nsc.set_velocity(na, Vec3(nan, 0, 0, 0), Vec3(0, 0, 0, 0))
    nsc.step_soft(DT, G)  # stepping must continue, not crash
    rsc.step_soft(DT, G)
    s.eqi(
        Int(nsc.counters.get(NAN_QUARANTINED)), 1,
        "extreme: NaN velocity -> exactly one quarantine",
    )
    var a_pos = nsc.bset.bodies[na.index()].position()
    var a_finite = (
        Float64(a_pos[0]) > -1e30 and Float64(a_pos[0]) < 1e30
        and Float64(a_pos[1]) > -1e30 and Float64(a_pos[1]) < 1e30
    )
    s.check(a_finite, "extreme: the quarantined body is finite afterward")
    s.check(nsc.bset.sleeping[na.index()], "extreme: the quarantined body is force-slept")
    var b_after = nsc.bset.bodies[nb.index()].position()
    var r_after = rsc.bset.bodies[rb.index()].position()
    s.check(
        Float64(b_after[0]) == Float64(r_after[0])
        and Float64(b_after[1]) == Float64(r_after[1])
        and Float64(b_after[2]) == Float64(r_after[2]),
        "extreme: the other body's trajectory is bit-identical to a run where the corrupted body was never there",
    )

    # -- pinned soft particle (w == 0) coupling, E3 --
    var psc = ContactScene6[QuatBody6]()
    _ = psc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    var pbody = psc.add(
        QuatBody6.at_rest(Vec3(0, 0.24, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    var psb = SoftBody.box_lattice(Vec3(0, 0.24, 0, 0), Vec3(0.05, 0.05, 0.05, 0), 2, 0.1, 1e-4)
    for i in range(len(psb.pts)):
        psb.pts[i].w = 0  # pin every particle: infinite mass, deliberately
    _ = psc.add_soft(psb^)
    for _ in range(10):
        psc.step_soft(DT, G)
    var pv = psc.bset.bodies[pbody.index()].linear_velocity()
    var p_finite = (
        Float64(pv[0]) > -1e30 and Float64(pv[0]) < 1e30
        and Float64(pv[1]) > -1e30 and Float64(pv[1]) < 1e30
    )
    s.check(p_finite, "extreme: a pinned (w=0) soft particle never produces an infinite reaction impulse")

    # -- graph-coloring overflow, E7 --
    var csc = ContactScene6[QuatBody6]()
    var plate = csc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(100, 50, 1, 50)),
        Vec3(50, 1, 50, 0), False,
    )
    comptime N_SAT = 65
    comptime PER_ROW = 9
    for i in range(N_SAT):
        var row = i // PER_ROW
        var col = i % PER_ROW
        _ = csc.add(
            QuatBody6.at_rest(
                Vec3(Real(col) * 2.0 - 8.0, 1.15, Real(row) * 2.0 - 8.0, 0),
                Inertia3.box(1, 0.2, 0.2, 0.2),
            ),
            Vec3(0.2, 0.2, 0.2, 0), False,
        )
    var ccfg = SolverConfig()
    ccfg.colored = True
    csc.step(DT, G, ccfg)
    s.eqi(
        Int(csc.counters.get(COLOR_OVERFLOW)), 1,
        "extreme: 65 pairs sharing one dynamic body overflows the 64-colour cap, falls back, and counts once",
    )
    var plate_pos = csc.bset.bodies[plate.index()].position()
    s.check(
        Float64(plate_pos[1]) > -1e30 and Float64(plate_pos[1]) < 1e30,
        "extreme: the fallback step still produces a finite result",
    )

    # -- CG not converged, E19 --
    var fb = FemBody(1.0e6, 0.3, 2.0)
    make_beam(fb, 6, 2, 2, 0.25, 1.0)
    for i in range(fb.node_count()):
        if fb.pos(i)[0] < 1e-6:
            fb.pin(i)
    var x0 = fb.pos(fb.node_count() - 1)
    # tol far tighter than one CG iteration can reach on a ~189-dof system:
    # deterministically not converged.
    var fres = fb.step_implicit(DT, G, tol=1e-30, max_iters=1)
    s.check(not fres.converged, "extreme: one CG iteration does not solve a ~189-dof system")
    s.eqi(Int(fb.counters.get(CG_NOT_CONVERGED)), 1, "extreme: CG_NOT_CONVERGED counted once")
    var x1 = fb.pos(fb.node_count() - 1)
    s.check(
        Float64(x0[0]) == Float64(x1[0]) and Float64(x0[1]) == Float64(x1[1])
        and Float64(x0[2]) == Float64(x1[2]),
        "extreme: an unconverged solve leaves node state untouched",
    )

    # ============================================================ CLASS C
    # -- trace spans (meaningful only under -D LUDENS_TRACE) --
    var tsc = ContactScene6[QuatBody6]()
    _ = tsc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    _ = tsc.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    tsc.step_soft(DT, G)
    comptime if TRACE_ON:
        s.check(len(tsc.trace.events) > 0, "enabled: step recorded trace spans")
        var stats = tsc.trace.stats()
        var saw_solve = False
        var saw_collect = False
        var saw_sleep = False
        var saw_nan_scan = False
        for i in range(len(stats)):
            if stats[i].name == "solve":
                saw_solve = True
            if stats[i].name == "collect_pairs":
                saw_collect = True
            if stats[i].name == "sleep":
                saw_sleep = True
            if stats[i].name == "nan_scan":
                saw_nan_scan = True
        s.check(saw_solve, "enabled: a 'solve' span was recorded")
        s.check(saw_collect, "enabled: a 'collect_pairs' span was recorded")
        s.check(saw_sleep, "enabled: a 'sleep' span was recorded")
        s.check(saw_nan_scan, "enabled: a 'nan_scan' span was recorded")
    else:
        s.eqi(len(tsc.trace.events), 0, "disabled: step recorded no trace spans")

    # -- debug-draw (meaningful only under -D LUDENS_DEBUG_DRAW) --
    var dsc = ContactScene6[QuatBody6]()
    _ = dsc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0), True,
    )
    _ = dsc.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    for _ in range(120):  # settle onto the ground: a flush box-on-box contact
        dsc.step_soft(DT, G)
    dsc.draw.clear()
    dsc.step_soft(DT, G)
    var contact_points = 0
    for i in range(len(dsc.cache)):
        contact_points += dsc.cache[i].m.count
    comptime if DEBUG_DRAW_ON:
        s.eqi(
            dsc.draw.count(), contact_points,
            "enabled: draw command count equals the step's contact-point count on a known stack",
        )
        s.check(contact_points > 0, "enabled: the settled stack actually has contacts to draw")
    else:
        s.eqi(dsc.draw.count(), 0, "disabled: no debug-draw commands are emitted")

    s.finish()
