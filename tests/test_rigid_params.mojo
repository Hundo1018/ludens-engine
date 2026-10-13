# tier: integration
"""Per-body rigid parameters (ROADMAP 17.48): `ContactScene6` setters.

Zero gravity unless stated, dt = 1/60, m = 1 unless stated.

  1. Ordinary:
     - linear damping c = 2 from 10 m/s: after 60 steps v = 10 / (1 + c dt)^60
       exactly (the implicit form), within 4 % of 10 e^-2; angular the same;
     - gravity_scale 0 floats, 2 falls at 2 g;
     - density -> mass: box 1 m cube at 1000 kg/m^3 = 1000 kg, sphere r 0.5
       = 523.6 kg, capsule r 0.3 hl 0.6 = 452.4 kg; set_mass keeps I / m;
     - force accumulator: FORCE 60 N over one 1/60 s step == IMPULSE 1 N s;
       ACCELERATION is mass-independent; the accumulator clears after a step;
       add_force_at off the centre adds the torque r x f.
  2. Integration:
     - axis locks (2.5D: lz, ax, ay) on a box tumbling onto a floor: z and the
       x / y angular velocity stay exactly 0;
     - max_velocity caps a falling body at 3 m/s and counts VELOCITY_CLAMPED;
     - per-body sleep thresholds: of two resting boxes, the one with
       thresholds 0 never sleeps, the other does;
     - snapshot (format 4) round-trips every new field: the restored scene
       steps bit-identically.
  3. Extreme / parity:
     - setting every parameter to its default (any_props on) is bit-identical
       to never calling a setter;
     - invalid id, mass 0 / NaN, negative damping, density on a hull raise;
     - static bodies ignore forces.
  4. Body6 parity: damping, locks, gravity scale and an off-centre force on
     ScrewBody6 track QuatBody6 to 1.7 mm over 1.5 s, inside the 3.7 mm the
     two representations already differ by in the same scene without them.
"""

from std.math import exp, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, ScrewBody6, Inertia3
from physics.solver6 import (
    ContactScene6,
    FORCE_MODE_FORCE,
    FORCE_MODE_IMPULSE,
    FORCE_MODE_ACCELERATION,
)
from physics.serialize import scene_to_string, scene_from_string
from diag.counters import VELOCITY_CLAMPED

comptime DT: Real = 1.0 / 60.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime G = Vec3(0, -9.8, 0, 0)


def _ball(p: Vec3, m: Real = 1) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.sphere(m, 0.5))


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)


def main() raises:
    var s = Suite("rigid_params")

    # ---- damping -------------------------------------------------------
    var sd = ContactScene6[QuatBody6]()
    var b = _ball(ZERO)
    b.vel = Vec3(10, 0, 0, 0)
    b.omega = Vec3(0, 10, 0, 0)
    var d = sd.add_sphere(b^, 0.5, False)
    sd.set_damping(d, 2, 2)
    for _ in range(60):
        sd.step_soft(DT, ZERO)
    var v = sd.velocity(d)[0]
    var w = sd.angular_velocity(d)[1]
    var disc = Real(10) / ((1 + 2 * DT) ** 60)
    print("  damping c = 2: v after 1 s", v, " discrete", disc, " continuous", 10 * exp(Real(-2)))
    s.check(abs(v - disc) < 1e-4 * disc, "linear damping = 10 / (1 + c dt)^60")
    s.check(abs(v - 10 * exp(Real(-2))) < 0.04 * 10 * exp(Real(-2)), "within 4 % of 10 e^-2")
    s.check(abs(w - disc) < 1e-4 * disc, "angular damping, same law")

    # ---- gravity scale -------------------------------------------------
    var sg = ContactScene6[QuatBody6]()
    var g0 = sg.add_sphere(_ball(Vec3(0, 10, 0, 0)), 0.5, False)
    var g2 = sg.add_sphere(_ball(Vec3(5, 10, 0, 0)), 0.5, False)
    var g1 = sg.add_sphere(_ball(Vec3(10, 10, 0, 0)), 0.5, False)
    sg.set_gravity_scale(g0, 0)
    sg.set_gravity_scale(g2, 2)
    for _ in range(30):
        sg.step_soft(DT, G)
    print("  gravity scale 0 / 2 / 1: vy", sg.velocity(g0)[1], sg.velocity(g2)[1], sg.velocity(g1)[1])
    s.check(sg.velocity(g0)[1] == 0 and sg.pose(g0).pos[1] == 10, "gravity_scale 0: floats")
    s.check(abs(sg.velocity(g2)[1] - 2 * sg.velocity(g1)[1]) < 1e-5, "gravity_scale 2: falls at 2 g")

    # ---- mass from density / set_mass ----------------------------------
    var sm = ContactScene6[QuatBody6]()
    var mb = sm.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    var ms = sm.add_sphere(_ball(Vec3(3, 0, 0, 0)), 0.5, False)
    var mc = sm.add_capsule(QuatBody6.at_rest(Vec3(6, 0, 0, 0), Inertia3.capsule(1, 0.3, 0.6)), 0.3, 0.6, False)
    sm.set_mass_from_density(mb, 1000)
    sm.set_mass_from_density(ms, 1000)
    sm.set_mass_from_density(mc, 1000)
    var mbox = sm.bset.bodies[mb.index()].inertia.mass
    var msph = sm.bset.bodies[ms.index()].inertia.mass
    var mcap = sm.bset.bodies[mc.index()].inertia.mass
    print("  density 1000: box", mbox, " sphere", msph, " capsule", mcap)
    s.check(abs(mbox - 1000) < 1e-2, "box 1 m^3 -> 1000 kg")
    s.check(abs(msph - 523.599) < 1e-2, "sphere r 0.5 -> 523.6 kg")
    s.check(abs(mcap - 452.389) < 1e-2, "capsule r 0.3 hl 0.6 -> 452.4 kg")
    s.check(abs(sm.bset.bodies[mb.index()].inertia.ix - 1000 * 0.5 / 3) < 1e-2, "box inertia from the same formula")
    sm.set_mass(ms, 2 * msph)
    s.check(abs(sm.bset.bodies[ms.index()].inertia.ix - 0.4 * 2 * msph * 0.25) < 1e-2, "set_mass doubles the inertia with the mass")

    # ---- force accumulator --------------------------------------------
    var sf = ContactScene6[QuatBody6]()
    var fa = sf.add_sphere(_ball(ZERO), 0.5, False)
    var fb = sf.add_sphere(_ball(Vec3(5, 0, 0, 0)), 0.5, False)
    var fc = sf.add_sphere(_ball(Vec3(10, 0, 0, 0), 5), 0.5, False)
    var fd = sf.add_sphere(_ball(Vec3(15, 0, 0, 0)), 0.5, False)
    sf.add_force(fa, Vec3(60, 0, 0, 0), FORCE_MODE_FORCE)
    sf.add_force(fb, Vec3(1, 0, 0, 0), FORCE_MODE_IMPULSE)
    sf.add_force(fc, Vec3(60, 0, 0, 0), FORCE_MODE_ACCELERATION)
    sf.add_force_at(fd, Vec3(0, 60, 0, 0), Vec3(15.5, 0, 0, 0), FORCE_MODE_FORCE)
    sf.step_soft(DT, ZERO)
    print("  60 N for 1/60 s:", sf.velocity(fa)[0], " impulse 1:", sf.velocity(fb)[0], " accel 60 on 5 kg:", sf.velocity(fc)[0])
    s.check(abs(sf.velocity(fa)[0] - 1) < 1e-6 and abs(sf.velocity(fb)[0] - 1) < 1e-6, "FORCE 60 N x 1/60 s == IMPULSE 1 N s")
    s.check(abs(sf.velocity(fc)[0] - 1) < 1e-6, "ACCELERATION is mass-independent")
    var want_wz = Real(0.5 * 60.0 / 60.0) / Real(0.4 * 0.25)  # (r x f) dt / I
    s.check(abs(sf.velocity(fd)[1] - 1) < 1e-6 and abs(sf.angular_velocity(fd)[2] - want_wz) < 1e-4, "add_force_at: force plus r x f")
    sf.step_soft(DT, ZERO)
    s.check(abs(sf.velocity(fa)[0] - 1) < 1e-6, "the accumulator clears after the step")

    # ---- axis locks ----------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _floor(sl)
    var lb = QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(1, 0.5, 0.3, 0.2))
    lb.q = Quat.from_axis_angle(Vec3(0.3, 0.5, 0.8, 0), 0.7)
    lb.vel = Vec3(1, 0, 2, 0)
    lb.omega = Vec3(3, -2, 1, 0)
    var li = sl.add(lb^, Vec3(0.5, 0.3, 0.2, 0), False)
    sl.set_axis_locks(li, False, False, True, True, True, False)
    var lock_ok = True
    for _ in range(120):
        sl.step_soft(DT, G)
        var wv = sl.angular_velocity(li)
        if sl.velocity(li)[2] != 0 or wv[0] != 0 or wv[1] != 0 or sl.pose(li).pos[2] != 0:
            lock_ok = False
    print("  2.5D locked box after 2 s: pos", sl.pose(li).pos[0], sl.pose(li).pos[1], sl.pose(li).pos[2])
    s.check(lock_ok, "locks lz, ax, ay: z, wx, wy stay exactly 0 through contact")
    s.check(sl.pose(li).pos[1] < 1 and sl.pose(li).pos[1] > 0.1, "locked box still lands on the floor")

    # ---- velocity cap --------------------------------------------------
    var sv = ContactScene6[QuatBody6]()
    var vi = sv.add_sphere(_ball(Vec3(0, 100, 0, 0)), 0.5, False)
    sv.set_max_velocity(vi, 3, 0)
    var c0 = sv.counters.get(VELOCITY_CLAMPED)
    var vmax = Real(0)
    for _ in range(60):
        sv.step_soft(DT, G)
        var vv = sv.velocity(vi)
        vmax = max(vmax, sqrt(vv[0] * vv[0] + vv[1] * vv[1] + vv[2] * vv[2]))
    var nclamp = sv.counters.get(VELOCITY_CLAMPED) - c0
    print("  capped fall: max speed", vmax, " clamps counted", nclamp)
    s.check(vmax <= 3 + 1e-5, "max_velocity 3 m/s holds")
    s.check(nclamp > 40, "VELOCITY_CLAMPED counts the capped steps")

    # ---- sleep thresholds ----------------------------------------------
    var ss = ContactScene6[QuatBody6]()
    _floor(ss)
    var sa = ss.add(QuatBody6.at_rest(Vec3(-3, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var sb = ss.add(QuatBody6.at_rest(Vec3(3, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    ss.set_sleep_thresholds(sb, 0, 0)
    for _ in range(120):
        ss.step_soft(DT, G)
    s.check(ss.bset.sleeping[sa.index()], "default thresholds: the resting box sleeps")
    s.check(not ss.bset.sleeping[sb.index()], "thresholds 0: the other never sleeps")

    # ---- snapshot round trip -------------------------------------------
    var sp = ContactScene6[QuatBody6]()
    _floor(sp)
    var p1 = sp.add_sphere(_ball(Vec3(0, 3, 0, 0)), 0.5, False)
    var p2 = sp.add(QuatBody6.at_rest(Vec3(2, 3, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sp.set_damping(p1, 0.5, 0.3)
    sp.set_gravity_scale(p2, 0.5)
    sp.set_axis_locks(p2, False, False, True, True, True, False)
    sp.set_max_velocity(p1, 4, 10)
    sp.set_sleep_thresholds(p2, 0, 0)
    sp.add_force(p1, Vec3(5, 0, 0, 0))
    var blob = scene_to_string(sp)
    var rp = scene_from_string(blob)
    s.check(scene_to_string(rp) == blob, "format 4: re-serialised blob is identical")
    for _ in range(90):
        sp.step_soft(DT, G)
        rp.step_soft(DT, G)
    var same = True
    for i in range(3):
        for a in range(3):
            if sp.bset.bodies[i].pos[a] != rp.bset.bodies[i].pos[a] or sp.bset.bodies[i].vel[a] != rp.bset.bodies[i].vel[a]:
                same = False
    s.check(same, "restored scene (forces, damping, locks, caps pending) steps bit-identically")

    # ---- parity: defaults set explicitly == never set ------------------
    var pa = ContactScene6[QuatBody6]()
    var pb = ContactScene6[QuatBody6]()
    _floor(pa)
    _floor(pb)
    for k in range(4):
        var bx = QuatBody6.at_rest(Vec3(Real(k) * 0.3, 0.6 + Real(k) * 0.55, 0.1 * Real(k), 0), Inertia3.box(1, 0.25, 0.25, 0.25))
        bx.omega = Vec3(0.2, 0.1 * Real(k), 0, 0)
        var by = bx.copy()
        _ = pa.add(bx^, Vec3(0.25, 0.25, 0.25, 0), False)
        var id = pb.add(by^, Vec3(0.25, 0.25, 0.25, 0), False)
        pb.set_damping(id, 0, 0)
        pb.set_gravity_scale(id, 1)
        pb.set_axis_locks(id, False, False, False, False, False, False)
        pb.set_max_velocity(id, 0, 0)
        pb.set_sleep_thresholds(id, -1, -1)
    for _ in range(120):
        pa.step_soft(DT, G)
        pb.step_soft(DT, G)
    var bit = True
    for i in range(5):
        for a in range(3):
            if pa.bset.bodies[i].pos[a] != pb.bset.bodies[i].pos[a] or pa.bset.bodies[i].omega[a] != pb.bset.bodies[i].omega[a]:
                bit = False
    s.check(bit, "every parameter at its default == no setter called, bit for bit")

    # ---- raises / ignored ----------------------------------------------
    var se = ContactScene6[QuatBody6]()
    var e1 = se.add_sphere(_ball(ZERO), 0.5, False)
    var hull: List[Real] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
    var eh = se.add_hull(QuatBody6.at_rest(Vec3(5, 0, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), hull^, False)
    var gone = se.add_sphere(_ball(Vec3(9, 0, 0, 0)), 0.5, False)
    se.remove_body(gone)
    var raised = 0
    try:
        se.set_damping(gone, 1, 1)
    except:
        raised += 1
    try:
        se.set_mass(e1, 0)
    except:
        raised += 1
    try:
        se.set_mass(e1, Real(0) / Real(0))
    except:
        raised += 1
    try:
        se.set_damping(e1, -1, 0)
    except:
        raised += 1
    try:
        se.set_mass_from_density(eh, 1000)
    except:
        raised += 1
    s.eqi(raised, 5, "invalid id, mass 0, mass NaN, negative damping, density on a hull: all raise")
    var st = ContactScene6[QuatBody6]()
    var sid = st.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
    st.add_force(sid, Vec3(100, 0, 0, 0), FORCE_MODE_IMPULSE)
    st.add_torque(sid, Vec3(0, 100, 0, 0))
    st.step_soft(DT, G)
    s.check(st.velocity(sid)[0] == 0 and st.angular_velocity(sid)[1] == 0, "static bodies ignore forces and torques")

    # ---- more extremes ---------------------------------------------------
    var sx = ContactScene6[QuatBody6]()
    var big = _ball(ZERO)
    big.vel = Vec3(5, 0, 0, 0)
    var xb = sx.add_sphere(big^, 0.5, False)
    sx.set_damping(xb, 1e9, 1e9)
    sx.step_soft(DT, ZERO)
    var vx = sx.velocity(xb)[0]
    s.check(vx > 0 and vx < 1e-5, "damping c = 1e9: speed to ~0, never reversed")
    var all_locked = sx.add_sphere(_ball(Vec3(4, 0, 0, 0)), 0.5, False)
    sx.set_axis_locks(all_locked, True, True, True, True, True, True)
    for _ in range(30):
        sx.step_soft(DT, G)
    s.check(sx.pose(all_locked).pos[1] == 0 and sx.velocity(all_locked)[1] == 0, "every axis locked: gravity does not move it")
    var many = sx.add_sphere(_ball(Vec3(8, 0, 0, 0)), 0.5, False)
    for _ in range(1000):
        sx.add_force(many, Vec3(0.06, 0, 0, 0))
    sx.step_soft(DT, ZERO)
    s.check(abs(sx.velocity(many)[0] - 1) < 1e-4, "1000 x 0.06 N in one step == 60 N")

    var sk = ContactScene6[QuatBody6]()
    _floor(sk)
    var sleeper = sk.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(120):
        sk.step_soft(DT, G)
    var was_asleep = sk.bset.sleeping[sleeper.index()]
    sk.add_force(sleeper, Vec3(0, 0, 30, 0), FORCE_MODE_IMPULSE)
    s.check(was_asleep and not sk.bset.sleeping[sleeper.index()] and sk.velocity(sleeper)[2] > 29, "a force on a sleeping body wakes it and acts")
    var kin = QuatBody6.at_rest(Vec3(5, 2, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    var ki = sk.add(kin^, Vec3(0.25, 0.25, 0.25, 0), False)
    sk.set_kinematic(ki)
    sk.add_force(ki, Vec3(100, 0, 0, 0), FORCE_MODE_IMPULSE)
    s.check(sk.velocity(ki)[0] == 0, "kinematic bodies ignore forces (their velocity is caller-set)")

    # ---- Body6 parity: the same parameters on ScrewBody6 ------------------
    var q6 = ContactScene6[QuatBody6]()
    var s6 = ContactScene6[ScrewBody6]()
    _floor(q6)
    _ = s6.add(ScrewBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var qi = q6.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.5, 0.3, 0.2)), Vec3(0.5, 0.3, 0.2, 0), False)
    var si = s6.add(ScrewBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.5, 0.3, 0.2)), Vec3(0.5, 0.3, 0.2, 0), False)
    q6.set_damping(qi, 0.8, 1.5)
    s6.set_damping(si, 0.8, 1.5)
    q6.set_axis_locks(qi, False, False, True, True, True, False)
    s6.set_axis_locks(si, False, False, True, True, True, False)
    q6.set_gravity_scale(qi, 0.7)
    s6.set_gravity_scale(si, 0.7)
    q6.add_force_at(qi, Vec3(30, 0, 0, 0), Vec3(0, 1.2, 0, 0))
    s6.add_force_at(si, Vec3(30, 0, 0, 0), Vec3(0, 1.2, 0, 0))
    var worst = Real(0)
    for _ in range(90):
        q6.step_soft(DT, G)
        s6.step_soft(DT, G)
        var dq = q6.pose(qi).pos - s6.pose(si).pos
        worst = max(worst, sqrt(dq[0] * dq[0] + dq[1] * dq[1] + dq[2] * dq[2]))
    # control: the same drop and push without any 17.48 parameter
    var q7 = ContactScene6[QuatBody6]()
    var s7 = ContactScene6[ScrewBody6]()
    _floor(q7)
    _ = s7.add(ScrewBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var qc = q7.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.5, 0.3, 0.2)), Vec3(0.5, 0.3, 0.2, 0), False)
    var sc7 = s7.add(ScrewBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.5, 0.3, 0.2)), Vec3(0.5, 0.3, 0.2, 0), False)
    q7.apply_impulse(qc, Vec3(0.5, 0, 0, 0), Vec3(0, 1.2, 0, 0))
    s7.apply_impulse(sc7, Vec3(0.5, 0, 0, 0), Vec3(0, 1.2, 0, 0))
    var worst0 = Real(0)
    for _ in range(90):
        q7.step_soft(DT, G)
        s7.step_soft(DT, G)
        var dq = q7.pose(qc).pos - s7.pose(sc7).pos
        worst0 = max(worst0, sqrt(dq[0] * dq[0] + dq[1] * dq[1] + dq[2] * dq[2]))
    print("  QuatBody6 vs ScrewBody6 with damping / locks / scale / force: worst position gap", worst, " control without parameters", worst0)
    s.check(worst <= worst0, "the parameters do not widen the QuatBody6 / ScrewBody6 gap (control: same scene without them)")
    s.check(s6.pose(si).pos[2] == 0 and s6.angular_velocity(si)[0] == 0, "locks hold on ScrewBody6 too")
    s.finish()
