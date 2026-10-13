# tier: integration
"""Cloth on an arbitrary triangle mesh (ROADMAP 17.56).

  1. Ordinary: a 1 m x 1 m sheet of density 0.2 kg/m^2 weighs 0.2 kg; a
     12-triangle fan (not a grid) gives 24 stretch edges and 12 bending
     constraints; a sheet pinned at two corners hangs, stays finite and
     keeps every edge within 10 % of its rest length; a 0.3 m strip clamped
     at one end sags less with stiff bending than with soft bending.
  2. Integration: a sheet dropped on a box rests on it (no vertex inside the
     box); a flag pinned along a vertical pole, under gravity, is pushed
     further by stronger wind; a vertex attached to a kinematic body follows it; tearing cuts
     edges under a low break force and none under the default; the
     `ContinuumSolver` contract (step_checked, state round trip).
  3. Extreme: bad meshes raise (index out of range, density 0, no
     triangles).
"""

from std.math import sqrt, cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from diag.counters import Counters
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import BinWriter, BinReader
from physics.continuum import step_checked
from physics.cloth import MeshCloth, grid_mesh

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _sheet(n: Int, y: Real, density: Real = 0.2, bend: Real = 1e-3) raises -> MeshCloth:
    var m = grid_mesh(n, n, 1, 1, Vec3(-0.5, y, -0.5, 0))
    return MeshCloth(m[0], m[1], density, 0, bend)


def _max_stretch(c: MeshCloth) -> Real:
    var worst = Real(0)
    for e in range(len(c.ea)):
        var d = c.x[c.eb[e]] - c.x[c.ea[e]]
        worst = max(worst, abs(sqrt(dot(d, d)) / c.rest[e] - 1))
    return worst


def main() raises:
    var s = Suite("cloth_mesh")
    var empty = ContactScene6[QuatBody6]()

    var c = _sheet(10, 0)
    print("  10 x 10 sheet: vertices", c.vertex_count(), " mass", c.total_mass(), " edges", len(c.ea), " bending", len(c.ba))
    s.check(abs(c.total_mass() - 0.2) < 1e-5, "mass from area: 1 m^2 x 0.2 kg/m^2")

    var fv: List[Real] = [0, 0, 0]
    var ft = List[Int]()
    for k in range(12):
        var a = Real(k) * 6.2831853 / 12
        fv.append(0.5 * cos(a))
        fv.append(0)
        fv.append(0.5 * sin(a))
        ft.append(0)
        ft.append(1 + k)
        ft.append(1 + (k + 1) % 12)
    var fan = MeshCloth(fv, ft, 0.2)
    s.check(len(fan.ea) == 24 and len(fan.ba) == 12, "12-triangle fan: 24 edges, 12 bending constraints")

    # ---- drape -------------------------------------------------------------------
    var d = _sheet(10, 1)
    d.pin(0)
    d.pin(10)
    for _ in range(120):
        d.step(empty, DT, G)
    var low = Real(1e9)
    for p in d.x:
        low = min(low, p[1])
    print("  hung by two corners, 2 s: lowest y", low, " worst edge stretch", _max_stretch(d))
    s.check(d.health().nonfinite == 0 and low < 0.6 and _max_stretch(d) < 0.1, "drape: finite, hangs, edges within 10 %")

    # ---- bending ---------------------------------------------------------------------
    var sags = List[Real]()
    for bend in [Real(1.0), Real(1e-7)]:
        var m = grid_mesh(6, 2, 0.3, 0.1, Vec3(0, 1, 0, 0))
        var st = MeshCloth(m[0], m[1], 0.2, 0, bend)
        for j in range(3):
            st.pin(j * 7)
            st.pin(j * 7 + 1)
        for _ in range(120):
            st.step(empty, DT, G)
        sags.append(1 - st.x[6][1])
    print("  clamped strip, free-end sag: soft bending", sags[0], " stiff", sags[1])
    s.check(sags[1] < sags[0], "stiff bending sags less than soft bending")

    # ---- collision with a box ---------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), True)
    var cb = _sheet(12, 0.6)
    cb.thickness = 0.01
    for _ in range(120):
        cb.step(sc, DT, G)
    var inside = 0
    var top = Real(1e9)
    for p in cb.x:
        if abs(p[0]) < 0.29 and abs(p[2]) < 0.29:
            top = min(top, p[1])
            if p[1] < 0.3:
                inside += 1
    print("  sheet dropped on a 0.6 m box: lowest vertex over the box", top, " inside", inside)
    s.check(inside == 0 and top > 0.29, "rests on the box, no vertex inside")

    # ---- wind ---------------------------------------------------------------------------------
    var push = List[Real]()
    for wz in [Real(0), Real(4), Real(8)]:
        var m = grid_mesh(8, 8, 1, 1, Vec3(0, 0, 0, 0))
        var verts = m[0].copy()
        for k in range(len(verts) // 3):  # stand the sheet up in the xy plane
            var z = verts[3 * k + 2]
            verts[3 * k + 1] = 1 - z
            verts[3 * k + 2] = 0
        var flag = MeshCloth(verts, m[1], 0.2)
        for j in range(9):
            flag.pin(j * 9)
        flag.wind = Vec3(0, 0, wz, 0)
        flag.drag = 0.2
        for _ in range(120):
            flag.step(empty, DT, G)
        var mz = Real(0)
        for p in flag.x:
            mz += p[2]
        push.append(mz / Real(len(flag.x)))
    print("  flag mean z after 2 s: wind 0", push[0], " 4 m/s", push[1], " 8 m/s", push[2])
    s.check(abs(push[0]) < 1e-6 and push[1] > 0.05 and push[2] > push[1], "stronger wind pushes the flag further")

    # ---- attachment ------------------------------------------------------------------------------
    var sa = ContactScene6[QuatBody6]()
    var kb = sa.add(QuatBody6.at_rest(Vec3(-0.5, 1, -0.5, 0), Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), False)
    sa.set_kinematic(kb)
    sa.set_velocity(kb, Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0))
    var ca = _sheet(6, 1)
    ca.attach(0, sa, kb.index())
    for _ in range(60):
        sa.step_soft(DT, Vec3(0, 0, 0, 0))
        ca.step(sa, DT, G)
    print("  vertex attached to a body moving 1 m/s: x after 1 s", ca.x[0][0], " body x", sa.pose(kb).pos[0])
    s.check(abs(ca.x[0][0] - sa.pose(kb).pos[0]) < 1e-5, "attached vertex follows the body")

    # ---- tearing ------------------------------------------------------------------------------------
    var weak = _sheet(10, 1, 2.0)
    weak.pin(0)
    weak.pin(10)
    weak.break_force = 0.5
    var strong = _sheet(10, 1, 2.0)
    strong.pin(0)
    strong.pin(10)
    for _ in range(120):
        weak.step(empty, DT, G)
        strong.step(empty, DT, G)
    print("  torn edges: break force 0.5 N", weak.torn_count(), " default", strong.torn_count())
    s.check(weak.torn_count() > 0 and strong.torn_count() == 0, "low break force tears, default does not")

    # ---- contract ------------------------------------------------------------------------------------
    var x1 = _sheet(8, 1)
    var x2 = _sheet(8, 1)
    x1.pin(0)
    x2.pin(0)
    var cn = Counters()
    for _ in range(30):
        _ = step_checked(x1, DT, G, cn)
    var w = BinWriter()
    x1.write_state(w)
    var r = BinReader(w.b.copy())
    x2.read_state(r)
    for _ in range(30):
        _ = step_checked(x1, DT, G, cn)
        _ = step_checked(x2, DT, G, cn)
    var w1 = BinWriter()
    var w2 = BinWriter()
    x1.write_state(w1)
    x2.write_state(w2)
    s.check(w1.b == w2.b, "ContinuumSolver: state round trip continues byte-identically")

    # ---- extremes ------------------------------------------------------------------------------------
    var raised = 0
    var v3: List[Real] = [0, 0, 0, 1, 0, 0, 0, 0, 1]
    var bad: List[Int] = [0, 1, 5]
    var ok: List[Int] = [0, 1, 2]
    var none = List[Int]()
    try:
        _ = MeshCloth(v3, bad, 0.2)
    except:
        raised += 1
    try:
        _ = MeshCloth(v3, ok, 0)
    except:
        raised += 1
    try:
        _ = MeshCloth(v3, none, 0.2)
    except:
        raised += 1
    s.check(raised == 3, "bad index, zero density, no triangles raise")
    s.finish()

