# tier: integration
"""Force fields and water volumes (ROADMAP 17.27 / 17.28).

  ordinary     a zero-g room holds a crate still while one outside falls; a
               radial blast pushes near crates harder than far ones and
               leaves crates beyond its radius untouched; wind accelerates a
               weightless crate toward the wind speed along 1 - exp(-kt/m);
               a drag zone damps velocity by exp(-kt).
  seam parity  a wind grid filled with one constant velocity steps
               bit-identically to the constant wind; sampled vs closed-form
               submerged volume of an axis-aligned box agree to the sampling
               error at every waterline.
  integration  a box half as dense as water floats with its centre at the
               surface; a sphere a quarter as dense floats with a quarter of
               its volume submerged; a dense sphere sinks to the floor.
  extreme      a sleeping crate inside a field is woken and moved; static
               bodies are never pushed; overlapping fields add.
"""

from std.math import exp
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import (
    ForceField, WindGrid, WaterVolume, apply_fields, apply_buoyancy,
    sphere_submerged, box_submerged_exact, box_submerged_sampled,
)

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime PI: Real = 3.14159265358979


def _crate(mut sc: ContactScene6[QuatBody6], c: Vec3, m: Real = 1) raises -> Int:
    var id = sc.add(QuatBody6.at_rest(c, Inertia3.box(m, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_can_sleep(id, False)
    return id.index()


def _al(mut s: Suite, got: Real, want: Real, tol: Real, label: String):
    s.almost(Float64(got), Float64(want), label, Float64(tol))


def _frames(mut sc: ContactScene6[QuatBody6], fields: List[ForceField], grids: List[WindGrid], n: Int) raises:
    for _ in range(n):
        apply_fields(sc, fields, grids, G, DT)
        sc.step_soft(DT, G)


def main() raises:
    var s = Suite("fields")
    var no_grids = List[WindGrid]()

    # ---- gravity zone ------------------------------------------------------------
    var gz = ContactScene6[QuatBody6]()
    var inside = _crate(gz, Vec3(0, 5, 0, 0))
    var outside = _crate(gz, Vec3(10, 5, 0, 0))
    var zf = List[ForceField]()
    zf.append(ForceField.gravity_zone(Vec3(-2, 0, -2, 0), Vec3(2, 10, 2, 0), Vec3(0, 0, 0, 0)))
    _frames(gz, zf, no_grids, 60)
    _al(s, gz.bset.bodies[inside].position()[1], 5, 1e-3, "zero-g room: the crate stays put")
    _al(s, gz.bset.bodies[outside].position()[1], 5 - 4.9, 0.05, "outside the room it falls freely (5 - g/2 after 1 s)")

    # ---- radial blast --------------------------------------------------------------
    var rb = ContactScene6[QuatBody6]()
    var c1 = _crate(rb, Vec3(1, 5, 0, 0))
    var c2 = _crate(rb, Vec3(2, 5, 0, 0))
    var c4 = _crate(rb, Vec3(4, 5, 0, 0))
    var blast = List[ForceField]()
    blast.append(ForceField.radial(Vec3(0, 5, 0, 0), 3, 600))
    apply_fields(rb, blast, no_grids, G, DT)
    var v1 = rb.bset.bodies[c1].linear_velocity()[0]
    var v2 = rb.bset.bodies[c2].linear_velocity()[0]
    s.check(v1 > v2 and v2 > 0, "blast: nearer crates pushed harder")
    s.check(rb.bset.bodies[c4].linear_velocity()[0] == 0, "blast: beyond the radius untouched")
    _al(s, v1, 600 * (1 - 1.0 / 3.0) * DT, 1e-5, "blast: impulse = strength x falloff x dt")

    # ---- wind and drag (weightless) -------------------------------------------------
    var room = ForceField.gravity_zone(Vec3(-50, -50, -50, 0), Vec3(50, 50, 50, 0), Vec3(0, 0, 0, 0))
    var wc = ContactScene6[QuatBody6]()
    var wcr = _crate(wc, Vec3(0, 5, 0, 0))
    var wf = List[ForceField]()
    wf.append(room)
    wf.append(ForceField.wind(Vec3(-50, -50, -50, 0), Vec3(50, 50, 50, 0), Vec3(5, 0, 0, 0), 2))
    _frames(wc, wf, no_grids, 60)
    var vw = wc.bset.bodies[wcr].linear_velocity()[0]
    _al(s, vw, 5 * (1 - exp(Real(-2))), 0.02 * 5, "wind: v = w (1 - exp(-k t / m)) after 1 s")

    var dc = ContactScene6[QuatBody6]()
    var dcr = _crate(dc, Vec3(0, 5, 0, 0))
    dc.bset.bodies[dcr].vel = Vec3(4, 0, 0, 0)
    var df = List[ForceField]()
    df.append(room)
    df.append(ForceField.drag(Vec3(-50, -50, -50, 0), Vec3(50, 50, 50, 0), 1.5))
    _frames(dc, df, no_grids, 60)
    _al(s, dc.bset.bodies[dcr].linear_velocity()[0], 4 * exp(Real(-1.5)), 0.02 * 4, "drag zone: v = v0 exp(-k t)")

    # ---- seam parity: constant wind vs constant grid ---------------------------------
    var ga = ContactScene6[QuatBody6]()
    var gb = ContactScene6[QuatBody6]()
    _ = _crate(ga, Vec3(0.3, 1, 0.2, 0))
    _ = _crate(gb, Vec3(0.3, 1, 0.2, 0))
    var grids = List[WindGrid]()
    grids.append(WindGrid(4, 4, 4, Vec3(-5, -5, -5, 0), 2.5, Vec3(3, 1, -2, 0)))
    var fa = List[ForceField]()
    fa.append(ForceField.wind(Vec3(-5, -5, -5, 0), Vec3(5, 5, 5, 0), Vec3(3, 1, -2, 0), 1.5))
    var fb = List[ForceField]()
    fb.append(ForceField.wind(Vec3(-5, -5, -5, 0), Vec3(5, 5, 5, 0), Vec3(0, 0, 0, 0), 1.5, 0))
    for _ in range(60):
        apply_fields(ga, fa, no_grids, G, DT)
        ga.step_soft(DT, G)
        apply_fields(gb, fb, grids, G, DT)
        gb.step_soft(DT, G)
    var dp = ga.bset.bodies[0].position() - gb.bset.bodies[0].position()
    s.check(dp[0] == 0 and dp[1] == 0 and dp[2] == 0, "constant wind grid == constant wind, bit for bit")

    var ok = True
    var body = QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.3, 0.2, 0.4))
    for w in range(11):
        var surface = Real(0.7) + Real(w) * 0.06
        var ex = box_submerged_exact(Vec3(0, 1, 0, 0), Vec3(0.3, 0.2, 0.4, 0), surface)
        var sm = box_submerged_sampled(body, Vec3(0.3, 0.2, 0.4, 0), surface, 16)
        var vol = Real(8 * 0.3 * 0.2 * 0.4)
        if abs(ex[0] - sm[0]) > vol / 16 + 1e-6:
            ok = False
    s.check(ok, "sampled vs exact submerged box volume within 1/16 of the volume at every waterline")

    # ---- buoyancy ------------------------------------------------------------------------
    var waters = List[WaterVolume]()
    waters.append(WaterVolume(Vec3(-10, -5, -10, 0), Vec3(10, 2, 10, 0), 1000, 2, 2))
    var bw = ContactScene6[QuatBody6]()
    _ = bw.add(QuatBody6.at_rest(Vec3(0, -5.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    var vbox = Real(0.4 * 0.4 * 0.4)
    var fl = bw.add(QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(500 * vbox, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    bw.set_can_sleep(fl, False)
    var r = Real(0.3)
    var vs = 4 * PI * r * r * r / 3
    var sp = QuatBody6.at_rest(Vec3(3, 3, 0, 0), Inertia3.sphere(250 * vs, r))
    var fs = bw.add_sphere(sp^, r, False)
    bw.set_can_sleep(fs, False)
    var sk = QuatBody6.at_rest(Vec3(-3, 1, 0, 0), Inertia3.sphere(2000 * vs, r))
    var fk = bw.add_sphere(sk^, r, False)
    bw.set_can_sleep(fk, False)
    for _ in range(1200):
        apply_buoyancy(bw, waters, G, DT)
        bw.step_soft(DT, G)
    _al(s, bw.bset.bodies[fl.index()].position()[1], 2, 0.02, "box at half density floats with its centre at the surface")
    var sub = sphere_submerged(bw.bset.bodies[fs.index()].position(), r, 2)
    _al(s, sub[0] / vs, 0.25, 0.02, "sphere at quarter density: a quarter submerged")
    _al(s, bw.bset.bodies[fk.index()].position()[1], -5 + r, 0.02, "dense sphere sinks to the floor")

    # ---- extremes ----------------------------------------------------------------------
    var sl = ContactScene6[QuatBody6]()
    _ = sl.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    var sid = sl.add(QuatBody6.at_rest(Vec3(0, 0.2, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    for _ in range(120):
        sl.step_soft(DT, G)
    s.check(sl.bset.sleeping[sid.index()], "(setup) the crate has fallen asleep")
    var push = List[ForceField]()
    push.append(ForceField.wind(Vec3(-5, -5, -5, 0), Vec3(5, 5, 5, 0), Vec3(20, 0, 0, 0), 50))
    _frames(sl, push, no_grids, 30)
    s.check(sl.bset.bodies[sid.index()].position()[0] > 0.1, "a sleeping crate inside a field is woken and moved")
    s.check(sl.bset.bodies[0].position()[0] == 0, "static bodies are never pushed")
    var two = ContactScene6[QuatBody6]()
    var tc = _crate(two, Vec3(0, 5, 0, 0))
    var twin = List[ForceField]()
    twin.append(ForceField.radial(Vec3(-1, 5, 0, 0), 3, 300))
    twin.append(ForceField.radial(Vec3(-1, 5, 0, 0), 3, 300))
    apply_fields(two, twin, no_grids, G, DT)
    _al(s, two.bset.bodies[tc].linear_velocity()[0], 2 * 300 * (1 - 1.0 / 3.0) * DT, 1e-5, "overlapping fields add")

    s.finish()
