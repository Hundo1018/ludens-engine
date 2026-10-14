# tier: integration
"""Force elements: exact hull buoyancy, wings, thrusters (ROADMAP 17.74).

  1. Ordinary: a 2 x 0.5 x 2 m box hull of density 500 floats with its
     centre at the waterline within 2 % of the draft; the exact cut volume
     equals `box_submerged_exact` to 1e-5 m^3 where the 8^3 sampling is off by
     up to a layer; a wing at 5 degrees and 20 m/s lifts q A 2 pi alpha to
     1e-4 relative; a half-throttle 100 N thruster on 10 kg gives 5 m/s^2.
  2. Integration: a 0.6 m wide hull with a keel (centre of mass 0.1 m below
     the hull centre: GM +0.095 m upright, -0.105 m inverted) started rolled
     150 degrees rights itself; a tall narrow hull (GM < 0) started 3 degrees
     off upright falls onto its side and stays there; a boat (hull +
     thruster) on a Gerstner sea moves forward and heaves.
  3. Extreme: the CL curve is continuous through the stall blend and falls
     past it; alpha = +-pi is finite; a hull above the water gets no force,
     a sunk one its whole 2 m^3 exactly; zero throttle gives no force; a
     flat (coplanar) hull raises.
"""

from std.math import pi, sin, cos, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import box_submerged_exact
from physics.water import FlatWater, GerstnerWater
from gameplay.force_element import Thruster
from gameplay.watercraft import HullBuoyancy
from gameplay.aircraft import Wing

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _box_pts(hx: Real, hy: Real, hz: Real, lift: Real = 0) -> List[Float64]:
    """Box hull points; `lift` raises the hull above the body's centre of
    mass (ballast in the keel)."""
    var p = List[Float64]()
    for k in range(8):
        p.append(Float64(hx if (k & 4) != 0 else -hx))
        p.append(Float64((hy if (k & 2) != 0 else -hy) + lift))
        p.append(Float64(hz if (k & 1) != 0 else -hz))
    return p^


def _up(sc: ContactScene6[QuatBody6]) raises -> Vec3:
    return sc.pose(sc.bset.id_of(0)).rot.rotate(Vec3(0, 1, 0, 0))


def _float(hx: Real, hy: Real, hz: Real, q: Quat, secs: Real, keel: Real = 0) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var vol = 8 * hx * hy * hz
    var b = QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(500 * vol, hx, hy, hz))
    b.q = q
    var id = sc.add(b^, Vec3(hx, hy, hz, 0), False)
    sc.set_sleep_thresholds(id, 0, 0)
    var hull = HullBuoyancy(_box_pts(hx, hy, hz, keel), FlatWater(0), 1000, 9.8, 2000, 2000)
    for k in range(Int(secs / DT)):
        _ = hull.apply(sc, id, Real(k) * DT)
        sc.step_soft(DT, G)
    return sc^


def main() raises:
    var s = Suite("force_elements")

    # ---- exact buoyancy ----------------------------------------------------------------------------
    var calm = _float(1, 0.25, 1, Quat(0, 0, 0, 1), 10)
    var yc = calm.pose(calm.bset.id_of(0)).pos[1]
    print("  box hull density 500 after 10 s: centre y", yc, "(waterline 0, draft 0.25)")
    s.check(abs(yc) < 0.02 * 0.25, "floats half submerged within 2 % of the draft")
    var probe = ContactScene6[QuatBody6]()
    var pid = probe.add(QuatBody6.at_rest(Vec3(0.3, 0.1, -0.2, 0), Inertia3.box(1, 1, 0.25, 1)), Vec3(1, 0.25, 1, 0), False)
    var hb = HullBuoyancy(_box_pts(1, 0.25, 1), FlatWater(0))
    var ex = hb.submerged(probe, pid, 0)
    var ref_v = box_submerged_exact(Vec3(0.3, 0.1, -0.2, 0), Vec3(1, 0.25, 1, 0), 0)
    print("  submerged volume: polytope cut", ex[0], " closed form", ref_v[0], " centroid y", ex[1][1], ref_v[1][1])
    s.check(abs(ex[0] - ref_v[0]) < 1e-5 and abs(ex[1][1] - ref_v[1][1]) < 1e-5, "exact cut == closed-form box volume and centroid")

    # ---- metacentric stability --------------------------------------------------------------------
    # a symmetric box is the same shape upside down; the keel (centre of
    # mass 0.1 m below the hull's centre) is what makes "capsized" a state.
    # 0.6 m wide, draft 0.25: KB 0.125 + BM 0.12 = KM 0.245; KG 0.15 upright
    # (GM +0.095), 0.35 inverted (GM -0.105). A 2 m wide hull has BM 1.33
    # and is stable both ways up (measured: it stays inverted).
    var wide = _float(0.3, 0.25, 1, Quat.from_axis_angle(Vec3(0, 0, 1, 0), 2.618), 20, 0.1)
    var tall = _float(0.25, 1, 1, Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.05), 20)
    var uw = _up(wide)
    var ut = _up(tall)
    print("  keeled hull (GM > 0 upright, < 0 inverted) from 150 deg: up.y", uw[1], "   tall hull (GM < 0) from 3 deg: up.y", ut[1])
    s.check(uw[1] > 0.95, "GM > 0: rights itself from 150 degrees")
    s.check(abs(ut[1]) < 0.2, "GM < 0: falls onto its side")

    # ---- wing ----------------------------------------------------------------------------------------
    var ws = ContactScene6[QuatBody6]()
    var a5 = Real(5.0 / 180.0) * Real(pi)
    var wb = QuatBody6.at_rest(Vec3(0, 10, 0, 0), Inertia3.box(100, 1, 0.1, 1))
    wb.vel = Vec3(20 * cos(a5), -20 * sin(a5), 0, 0)
    var wid = ws.add(wb^, Vec3(1, 0.1, 1, 0), False)
    var wing = Wing.simple(Vec3(0, 0, 0, 0), 2)
    var f = wing.apply(ws, wid, 0)
    var lift_dir = Vec3(sin(a5), cos(a5), 0, 0)
    var want = Real(0.5) * 1.225 * 400 * 2 * 2 * Real(pi) * a5
    var lift = dot(f, lift_dir)
    print("  wing 2 m^2 at 5 deg, 20 m/s: lift", lift, " q A 2 pi alpha", want, " drag", -dot(f, Vec3(cos(a5), -sin(a5), 0, 0)))
    s.check(abs(lift / want - 1) < 1e-4, "pre-stall lift = q A 2 pi alpha")
    var c14 = wing.coefficients(0.25)[0]
    var cs0 = wing.coefficients(0.26 - 1e-4)[0]
    var cs1 = wing.coefficients(0.26 + 1e-4)[0]
    var cb0 = wing.coefficients(0.36 - 1e-4)[0]
    var cb1 = wing.coefficients(0.36 + 1e-4)[0]
    var c30 = wing.coefficients(0.52)[0]
    print("  CL: 14.3 deg", c14, " stall", cs0, cs1, " end of blend", cb0, cb1, " 30 deg", c30)
    s.check(abs(cs0 - cs1) < 1e-2 and abs(cb0 - cb1) < 1e-2 and c30 < c14, "CL continuous through the stall blend and lower past it")
    var tumble = wing.coefficients(Real(pi))
    var tumble2 = wing.coefficients(-Real(pi))
    s.check(isfinite(tumble[0]) and isfinite(tumble[1]) and isfinite(tumble2[0]), "alpha = +-pi finite")

    # ---- thruster ---------------------------------------------------------------------------------------
    var ts = ContactScene6[QuatBody6]()
    var tid = ts.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(10, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    ts.set_sleep_thresholds(tid, 0, 0)
    var thr = Thruster(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 100, 0.5)
    for _ in range(60):
        _ = thr.apply(ts, tid, 0)
        ts.step_soft(DT, Vec3(0, 0, 0, 0))
    print("  half-throttle 100 N on 10 kg for 1 s: v", ts.velocity(tid)[0])
    s.check(abs(ts.velocity(tid)[0] - 5) < 0.05, "thrust 50 N on 10 kg: 5 m/s after 1 s")
    var off = Thruster(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 100, 0)
    s.check(length(off.apply(ts, tid, 0)) == 0, "zero throttle: no force")

    # ---- boat on a sea ------------------------------------------------------------------------------------
    var sea = GerstnerWater(0)
    sea.add(1, 0.3, 0.3, 20)
    var bs = ContactScene6[QuatBody6]()
    var bid = bs.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1000, 2, 0.25, 1)), Vec3(2, 0.25, 1, 0), False)
    bs.set_sleep_thresholds(bid, 0, 0)
    var boat_hull = HullBuoyancy(_box_pts(2, 0.25, 1), sea.copy(), 1000, 9.8, 500, 2000)
    var prop = Thruster(Vec3(-2, -0.2, 0, 0), Vec3(1, 0, 0, 0), 2000, 1)
    var ylo = Real(1e9)
    var yhi = Real(-1e9)
    for k in range(600):
        _ = boat_hull.apply(bs, bid, Real(k) * DT)
        _ = prop.apply(bs, bid, Real(k) * DT)
        bs.step_soft(DT, G)
        if k > 120:
            ylo = min(ylo, bs.pose(bid).pos[1])
            yhi = max(yhi, bs.pose(bid).pos[1])
    var bx = bs.pose(bid).pos[0]
    print("  boat with a 2 kN propeller on a 0.3 m swell, 10 s: x", bx, " heave", yhi - ylo)
    s.check(bx > 5 and yhi - ylo > 0.1 and isfinite(bx), "the boat moves forward and heaves")

    # ---- extremes ----------------------------------------------------------------------------------------
    var hi = ContactScene6[QuatBody6]()
    var hid = hi.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 1, 0.25, 1)), Vec3(1, 0.25, 1, 0), False)
    var lo = ContactScene6[QuatBody6]()
    var lid = lo.add(QuatBody6.at_rest(Vec3(0, -5, 0, 0), Inertia3.box(1, 1, 0.25, 1)), Vec3(1, 0.25, 1, 0), False)
    s.check(hb.submerged(hi, hid, 0)[0] == 0 and abs(hb.submerged(lo, lid, 0)[0] - 2) < 1e-6, "above water: 0; sunk: the whole 2 m^3")
    var raised = False
    try:
        var flat: List[Float64] = [0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1]
        _ = HullBuoyancy(flat, FlatWater(0))
    except:
        raised = True
    s.check(raised, "a flat hull raises")
    s.finish()
