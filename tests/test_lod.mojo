# tier: integration
"""Physics LOD and simulation budget (ROADMAP 17.31).

  ordinary     a sliding crate frozen mid-slide stops where it is; unfrozen
               it resumes with exactly the velocity it had; a crate dropped
               on a frozen crate rests on it (frozen = temporarily static).
  seam parity  a DistanceLOD whose radius covers everything plus a budget
               at its ceiling steps bit-identically to the plain solver.
  integration  an observer walking away freezes the far bodies and walking
               back unfreezes them, with hysteresis; a budget fed step times
               above the target degrades iterations then substeps down to
               the floor, fed times well below restores them, and holds
               between the thresholds.
  extreme      freezing a static body or freezing twice is a no-op; an
               invalid id raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.lod import DistanceLOD, SimBudget

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 60, 0.5, 60)), Vec3(60, 0.5, 60, 0), True).index()


def _crate(mut sc: ContactScene6[QuatBody6], p: Vec3, v: Vec3) raises -> Int:
    var b = QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2))
    b.vel = v
    var id = sc.add(b^, Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_can_sleep(id, False)
    return id.index()


def main() raises:
    var s = Suite("lod")

    # ---- freeze / unfreeze -----------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var c = _crate(sc, Vec3(0, 0.2, 0, 0), Vec3(3, 0, 0, 0))
    sc.set_friction(c, 0)
    for _ in range(10):
        sc.step_soft(DT, G)
    var id = sc.bset.id_of(c)
    var v_before = sc.bset.bodies[c].linear_velocity()
    sc.freeze(id)
    var p_frozen = sc.bset.bodies[c].position()
    for _ in range(30):
        sc.step_soft(DT, G)
    var p_after = sc.bset.bodies[c].position()
    s.check(sc.is_frozen(id), "frozen")
    s.check(p_after[0] == p_frozen[0] and p_after[1] == p_frozen[1], "a frozen crate does not move")
    sc.unfreeze(id)
    var v_resume = sc.bset.bodies[c].linear_velocity()
    s.check(v_resume[0] == v_before[0] and v_resume[1] == v_before[1], "unfrozen, it resumes with exactly its velocity")
    sc.step_soft(DT, G)
    s.check(sc.bset.bodies[c].position()[0] > p_frozen[0], "and moves on")

    var st = ContactScene6[QuatBody6]()
    _ = _ground(st)
    var base = _crate(st, Vec3(0, 3, 0, 0), Vec3(0, 0, 0, 0))
    st.freeze(st.bset.id_of(base))  # frozen in mid-air
    var top = _crate(st, Vec3(0, 5, 0, 0), Vec3(0, 0, 0, 0))
    for _ in range(120):
        st.step_soft(DT, G)
    s.check(abs(st.bset.bodies[top].position()[1] - 3.4) < 0.03, "a crate dropped on a frozen crate rests on it")
    s.check(st.bset.bodies[base].position()[1] == 3, "the frozen crate stays in mid-air")

    # ---- parity: LOD covering everything + budget at its ceiling ------------
    var pa = ContactScene6[QuatBody6]()
    var pb = ContactScene6[QuatBody6]()
    _ = _ground(pa)
    _ = _ground(pb)
    for k in range(6):
        _ = _crate(pa, Vec3(Real(k) * 0.3, 0.3 + Real(k) * 0.45, 0, 0), Vec3(0.2, 0, 0, 0))
        _ = _crate(pb, Vec3(Real(k) * 0.3, 0.3 + Real(k) * 0.45, 0, 0), Vec3(0.2, 0, 0, 0))
    var lod = DistanceLOD(1000)
    var bud = SimBudget(1000000000, 1, 4, 1, 4)
    var cfg = SolverConfig()
    for _ in range(120):
        _ = lod.update(pa, Vec3(0, 0, 0, 0))
        var c2 = cfg
        bud.apply(c2)
        pa.step(DT, G, c2)
        pb.step(DT, G, cfg)
    var same = True
    for i in range(len(pa.bset.bodies)):
        var d = pa.bset.bodies[i].position() - pb.bset.bodies[i].position()
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            same = False
    s.check(same, "full-quality LOD + budget == plain solver, bit for bit")

    # ---- integration: walking observer, budget controller ---------------------
    var w = ContactScene6[QuatBody6]()
    _ = _ground(w)
    var near = _crate(w, Vec3(0, 0.2, 0, 0), Vec3(0, 0, 0, 0))
    var far = _crate(w, Vec3(40, 0.2, 0, 0), Vec3(0, 0, 0, 0))
    var dl = DistanceLOD(20, 2)
    var n0 = dl.update(w, Vec3(0, 0, 0, 0))
    s.check(n0 == 1 and w.is_frozen(w.bset.id_of(far)) and not w.is_frozen(w.bset.id_of(near)), "observer at 0: the far crate is frozen")
    var n1 = dl.update(w, Vec3(19, 0, 0, 0))
    s.check(n1 == 1, "observer at 19 (far crate at 21, inside the hysteresis band): still frozen")
    var n2 = dl.update(w, Vec3(21, 0, 0, 0))
    s.check(n2 == 0, "observer at 21: the far crate (19 away) unfrozen, the near one (21 away) not yet frozen")
    var n3 = dl.update(w, Vec3(40, 0, 0, 0))
    s.check(w.is_frozen(w.bset.id_of(near)) and n3 == 1, "walking on: the near crate is frozen instead")

    var b = SimBudget(1000, 1, 4, 1, 4)
    for _ in range(10):
        b.update(5000)
    s.check(b.iters == 1 and b.substeps == 1, "over budget: degrades to the floor (iterations first, then substeps)")
    for _ in range(10):
        b.update(100)
    s.check(b.iters == 4 and b.substeps == 4, "well under budget: restores to the ceiling")
    b.update(5000)
    var it = b.iters
    var sub = b.substeps
    for _ in range(10):
        b.update(900)
    s.check(b.iters == it and b.substeps == sub, "between the thresholds: holds (no oscillation)")

    # ---- extremes -----------------------------------------------------------------
    var gid = w.bset.id_of(0)
    w.freeze(gid)
    s.check(not w.is_frozen(gid), "freezing a static body is a no-op")
    w.freeze(w.bset.id_of(near))
    w.freeze(w.bset.id_of(near))
    w.unfreeze(w.bset.id_of(near))
    s.check(not w.is_frozen(w.bset.id_of(near)), "freezing twice then unfreezing once restores")
    s.check(w.bset.is_dynamic(near), "and the motion type is dynamic again")
    var old = w.bset.id_of(far)
    w.remove_body(old)
    var raised = False
    try:
        w.freeze(old)
    except:
        raised = True
    s.check(raised, "freezing a removed body's stale id raises")
    s.finish()
