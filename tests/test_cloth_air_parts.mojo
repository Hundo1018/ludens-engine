# tier: integration
"""Cloth <-> lattice air through `Coupler` (ROADMAP 17.61,
`physics.cloth_air_parts`).

Same setup as `test_cloth_air`: a 24^3 periodic lattice (dx 2 cm, 1 ms
per lattice step, rho 1.2, lattice viscosity 0.05) and a 0.2 m sheet
(6 x 6 cells, 0.1 kg/m^2) falling through it, drag k = 2 kg/(m^2 s).

  1. Parity: `Coupler[ClothPart, AirPart]`, EXPLICIT, ratio 1, gives the
     cloth positions, velocities and lattice populations of
     `ClothAir.step` bit for bit after 200 steps.
  2. Conservation: per step the coupler's imbalance (|cloth impulse + air
     impulse|) stays at rounding level with EXPLICIT; the cloth's and the
     air's running totals are equal and opposite. With ratio 2 (cloth
     2 ms, lattice 1 ms) EXPLICIT still conserves; INTERP blends the
     impulse between steps and the imbalance it records is printed.
  3. Snapshot: `Coupler.write_state` after 100 steps, 100 more; a fresh
     pair restored from the bytes and run 100 steps matches bit for bit.
     A lattice substep that is not one lattice step raises.
  4. Three solvers, one coupler: the sheet and a 4 g rigid ball 0.1 m
     below it (`BallPart`, linear drag 0.08 kg/s) in one lattice through
     `Both[ClothPart, BallPart]`. Per step the imbalance (cloth + ball +
     air impulses) stays at rounding level and the air's momentum changes
     by minus what cloth and ball received. The ball in the sheet's
     wake falls faster than the same ball alone in still air.
  5. Strands: `Coupler[StrandPart, AirPart]` at ratio 1 equals
     `StrandAir.step` bit for bit over 200 steps (a 6 x 6 brush of
     8-particle strands in a lattice flowing at 0.02), strands and
     populations.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from fluid.lbm import Lbm
from diag.counters import Counters
from physics.cloth import MeshCloth, grid_mesh
from physics.cloth_air import ClothAir, lattice_momentum
from physics.cloth_air_parts import ClothPart, AirPart, BallPart, StrandPart
from physics.strand import StrandSet
from physics.strand_air import StrandAir
from physics.rigid6 import Pose6
from geometry.quat import Quat
from physics.coupler import Coupler, Both, EXPLICIT, INTERP
from physics.serialize import BinWriter, BinReader

comptime NL = 24
comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime RHO: Real = 1.2
comptime G = Vec3(0, -9.8, 0, 0)


def air() -> Lbm:
    var l = Lbm(NL, NL, NL, 0.05)
    l.init_uniform(1.0, 0.0, 0.0, 0.0)
    return l^


def sheet() raises -> MeshCloth:
    var m = grid_mesh(6, 6, 0.2, 0.2, Vec3(0.14, 0.30, 0.14, 0))
    var c = MeshCloth(m[0], m[1], 0.1, 0, 1e-3)
    c.damping = 1.0
    return c^


def pair(ratio: Int, scheme: Int) raises -> Coupler[ClothPart, AirPart]:
    var c = sheet()
    var x = c.x.copy()
    return Coupler[ClothPart, AirPart](
        ClothPart(c^, 2.0, G), AirPart(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, ratio, x), ratio, scheme
    )


def flowing() -> Lbm:
    var l = Lbm(NL, NL, NL, 0.05)
    l.init_uniform(1.0, 0.02, 0.0, 0.0)
    return l^


def brush(bones: List[Pose6]) raises -> StrandSet:
    var ss = StrandSet(0.0, 20.0)
    for i in range(6):
        for k in range(6):
            _ = ss.add(0, bones[0], Vec3(0.19 + Real(i) * 0.02, 0.40, 0.19 + Real(k) * 0.02, 0), Vec3(0, -1, 0, 0), 8, 0.03)
    return ss^


def same_cloth(a: MeshCloth, b: MeshCloth) -> Bool:
    for i in range(len(a.x)):
        for c in range(3):
            if a.x[i][c] != b.x[i][c] or a.v[i][c] != b.v[i][c]:
                return False
    return True


def same_f(a: Lbm, b: Lbm) -> Bool:
    for i in range(len(a.f)):
        if a.f[i] != b.f[i]:
            return False
    return True


def main() raises:
    var s = Suite("cloth_air_parts")
    var counters = Counters()

    # 1. parity with ClothAir
    var ref_c = sheet()
    var ref_a = ClothAir(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 2.0)
    var cp = pair(1, EXPLICIT)
    var worst = Real(0)
    var scale = Real(0)
    for _ in range(200):
        ref_a.step(ref_c, G)
        cp.step(DT, counters)
        worst = max(worst, cp.imbalance)
        scale = max(scale, length(cp.a.received))
    s.check(same_cloth(ref_c, cp.a.cloth), "EXPLICIT ratio 1: cloth equals ClothAir.step bit for bit (200 steps)")
    s.check(same_f(ref_a.lbm, cp.b.lbm), "EXPLICIT ratio 1: lattice populations equal bit for bit")
    var tot = cp.a.total + cp.b.total
    print("  EXPLICIT 1:1: max per-step imbalance", worst, "N s vs per-step impulse up to", scale, "; totals", cp.a.total[1], cp.b.total[1])
    s.check(worst <= 1e-6 * scale, "EXPLICIT: per-step imbalance at rounding level (<= 1e-6 of the impulse)")
    s.check(length(tot) <= 1e-5 * length(cp.a.total), "cloth and air totals equal and opposite")

    # 2. ratio 2: cloth 2 ms, lattice 1 ms
    var e2 = pair(2, EXPLICIT)
    var i2 = pair(2, INTERP)
    var sc2 = Real(0)
    for _ in range(100):
        e2.step(2 * DT, counters)
        i2.step(2 * DT, counters)
        sc2 = max(sc2, length(e2.a.received))
    print("  ratio 2: EXPLICIT max imbalance", e2.max_imbalance, " INTERP", i2.max_imbalance, " per-step impulse up to", sc2)
    s.check(e2.max_imbalance <= 1e-6 * sc2, "ratio 2 EXPLICIT: conserves to rounding")
    s.check(i2.max_imbalance > 100 * e2.max_imbalance, "ratio 2 INTERP: blends impulses, imbalance recorded")
    print("  after 0.2 s, vertex 0 vy: ratio 2 EXPLICIT", e2.a.cloth.v[0][1], " ratio 1", cp.a.cloth.v[0][1])

    # 3. snapshot
    var live = pair(1, EXPLICIT)
    for _ in range(100):
        live.step(DT, counters)
    var w = BinWriter()
    live.write_state(w)
    for _ in range(100):
        live.step(DT, counters)
    var back = pair(1, EXPLICIT)
    var r = BinReader(w.b.copy())
    back.read_state(r)
    for _ in range(100):
        back.step(DT, counters)
    print("  snapshot after 100 steps:", len(w.b), "bytes")
    s.check(same_cloth(live.a.cloth, back.a.cloth) and same_f(live.b.lbm, back.b.lbm), "restored pair continues bit for bit (100 steps)")
    s.check(live.max_imbalance == back.max_imbalance, "conservation record restored")

    var raised = False
    try:
        var bad = pair(1, EXPLICIT)
        bad.step(2 * DT, counters)  # lattice substep 2 ms, lattice step is 1 ms
    except:
        raised = True
    s.check(raised, "a lattice substep that is not dt_lat raises")

    # 4. cloth + ball + air
    var c3 = sheet()
    var pts = c3.x.copy()
    var nc = len(pts)
    var ball_x = Vec3(0.24, 0.20, 0.24, 0)
    pts.append(ball_x)
    var three = Coupler[Both[ClothPart, BallPart], AirPart](
        Both[ClothPart, BallPart](ClothPart(c3^, 2.0, G), BallPart(ball_x, 0.004, 0.08, G), 3 * nc),
        AirPart(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1, pts),
        1, EXPLICIT,
    )
    var lone_pts: List[Vec3] = [ball_x]
    var lone = Coupler[BallPart, AirPart](
        BallPart(ball_x, 0.004, 0.08, G), AirPart(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1, lone_pts), 1, EXPLICIT
    )
    var p0 = lattice_momentum(three.b.lbm, RHO, DX, DT)
    var sc3 = Real(0)
    for _ in range(300):
        three.step(DT, counters)
        lone.step(DT, counters)
        sc3 = max(sc3, length(three.a.a.received) + length(three.a.b.j))
    var gave = three.a.a.total + three.a.b.total
    var dp = lattice_momentum(three.b.lbm, RHO, DX, DT) - p0
    var rel = length(dp + gave) / length(gave)
    print("  three-way, 0.3 s: max imbalance", three.max_imbalance, " per-step impulses up to", sc3)
    print("  air momentum change", dp[1], " cloth + ball received", gave[1], " relative mismatch", rel)
    print("  ball vy: under the sheet", three.a.b.v[1], " alone", lone.a.v[1])
    s.check(three.max_imbalance <= 1e-6 * sc3, "three-way: per-step imbalance at rounding level")
    s.check(rel < 1e-3, "three-way: air momentum change = -(cloth + ball impulses) within 1e-3")
    s.check(three.a.b.v[1] < lone.a.v[1], "the ball in the sheet's wake falls faster than alone")

    # 5. strands
    var bones: List[Pose6] = [Pose6(Vec3(0, 0, 0, 0), Quat.identity())]
    var ref_s = brush(bones)
    var ref_air = StrandAir(flowing(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1e-4)
    var bs = brush(bones)
    var sx = bs.x.copy()
    var sp = Coupler[StrandPart, AirPart](
        StrandPart(bs^, bones.copy(), G, 1e-4), AirPart(flowing(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1, sx), 1, EXPLICIT
    )
    for _ in range(200):
        ref_air.step(ref_s, G, bones)
        sp.step(DT, counters)
    var same_s = True
    for i in range(len(ref_s.x)):
        for c in range(3):
            same_s = same_s and ref_s.x[i][c] == sp.a.strands.x[i][c] and ref_s.v[i][c] == sp.a.strands.v[i][c]
    print("  strands: 36 strands x 8 particles, 200 steps; strand impulse", ref_air.strand_impulse[0], sp.a.total[0])
    s.check(same_s and same_f(ref_air.lbm, sp.b.lbm), "StrandPart + AirPart equal StrandAir.step bit for bit (200 steps)")
    s.finish()
