# tier: integration
"""Cloth attached to a rigid body through `Coupler` (ROADMAP 17.61,
`physics.cloth_anchor`).

A 6 x 6 sheet (0.2 m, 0.1 kg/m^2) whose left edge (7 vertices) is welded
to an anchor point; the anchor is a translation-only body of mass M with
those 7 points at fixed offsets. Gravity 9.8 m/s^2 along -y.

  1. Weight: a heavy anchor (M 1000 kg, no gravity of its own) holds the
     sheet. Over 10 s (10 ms steps, no damping) the impulse the cloth gives
     the anchor sums to the sheet's weight times the time within 5 %, and
     the anchor moves under 1 cm.
  2. Momentum: with a light free anchor (M 0.05 kg) the total momentum of
     cloth + anchor changes by (m_cloth + M) g dt per step to within 1e-3
     of that step's impulse, for ratio 1 and ratio 2 (the anchor takes the
     cloth's impulse in `ratio` substeps). The coupler's imbalance is zero.
  3. Free fall: the attached pair falls as one body. After 0.2 s the anchor's
     speed is within 1 % of g t (measured 0.07 %); the reaction it feels is
     about 1e-4 of its weight per step, the one-step target lag.
  4. Snapshot: `Coupler.write_state` after 100 steps, 100 more; a fresh pair
     restored from the bytes and run 100 steps matches bit for bit.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from diag.counters import Counters
from physics.cloth import MeshCloth, grid_mesh
from physics.cloth_anchor import ClothAnchorPart, AnchorPart
from physics.coupler import Coupler, EXPLICIT
from physics.serialize import BinWriter, BinReader

comptime DT: Real = 1e-3
comptime DT_W: Real = 1e-2
comptime DT_M: Real = 2e-2
comptime G = Vec3(0, -9.8, 0, 0)
comptime ANCHOR = Vec3(0.14, 0.30, 0.04, 0)


def sheet(damping: Real) raises -> MeshCloth:
    var m = grid_mesh(6, 6, 0.2, 0.2, Vec3(0.14, 0.30, 0.14, 0))
    var c = MeshCloth(m[0], m[1], 0.1, 0, 1e-3)
    c.damping = damping
    return c^


def edge(c: MeshCloth) -> List[Int]:
    """Vertices on the x = 0.14 edge (the attachment line)."""
    var out = List[Int]()
    for i in range(len(c.x)):
        if abs(c.x[i][0] - 0.14) < 1e-6:
            out.append(i)
    return out^


def offsets(c: MeshCloth, att: List[Int]) -> List[Vec3]:
    var r = List[Vec3]()
    for i in att:
        r.append(c.x[i] - ANCHOR)
    return r^


def pair(M: Real, anchor_g: Vec3, ratio: Int, damping: Real) raises -> Coupler[ClothAnchorPart, AnchorPart]:
    var c = sheet(damping)
    var att = edge(c)
    var r = offsets(c, att)
    var a = ClothAnchorPart(c^, att, G)
    var b = AnchorPart(ANCHOR, M, r^, anchor_g, ratio)
    return Coupler[ClothAnchorPart, AnchorPart](a^, b^, ratio, EXPLICIT)


def cloth_momentum(c: MeshCloth) -> Vec3:
    var p = Vec3(0, 0, 0, 0)
    for i in range(len(c.x)):
        if c.w[i] > 0:
            p = p + c.v[i] * (1 / c.w[i])
    return p


def same_vec(a: Vec3, b: Vec3) -> Bool:
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2]


def case_weight(mut s: Suite) raises:
    """A 1000 kg anchor, no gravity of its own. The sheet swings about its
    equilibrium while the damping-free momentum stays bounded, so the
    impulse it gives the anchor, summed over 10 s, equals its weight times
    the time: cumulative error = (p_end - p_0) / weight time."""
    var cp = pair(1000, Vec3(0, 0, 0, 0), 1, 1.0)
    var counters = Counters()
    var weight = cp.a.cloth.total_mass() * 9.8
    var up: Real = 0
    var steps = 1000
    for _ in range(steps):
        cp.step(DT_W, counters)
        up += cp.a.received[1]
    var target = weight * DT_W * Real(steps)
    var rel = abs(up - target) / target
    print("  weight x time", target, "cloth impulse summed", up, "rel", rel)
    print("  anchor drift after 10 s", cp.b.x[1] - ANCHOR[1])
    s.check(rel < 0.05, "held sheet: cumulative impulse = weight x time within 5 % (10 s)")
    s.check(abs(cp.b.x[1] - ANCHOR[1]) < 1e-2, "heavy anchor (1000 kg) moves < 1 cm in 10 s")


def case_momentum(mut s: Suite) raises:
    """Light free anchor. The step is 20 ms: `MeshCloth` recovers velocity as
    (x - prev) / h, and at 1 ms the substep displacement g h^2 ~ 1.5e-7 m
    is too close to the f32 ulp of the positions (~3e-8 m) to show a clean
    momentum balance even for the bare sheet."""
    var M: Real = 0.05
    for ratio in [1, 2]:
        var cp = pair(M, G, ratio, 1.0)
        var counters = Counters()
        var dp_expect = (cp.a.cloth.total_mass() + M) * G * DT_M
        var worst: Real = 0
        var p_before = cloth_momentum(cp.a.cloth) + cp.b.v * M
        for _ in range(100):
            cp.step(DT_M, counters)
            var p_after = cloth_momentum(cp.a.cloth) + cp.b.v * M
            var dp = p_after - p_before
            var err = dp - dp_expect
            var e = (err[0] * err[0] + err[1] * err[1] + err[2] * err[2]) ** 0.5
            if e > worst:
                worst = e
            p_before = p_after
        var scale = abs(dp_expect[1])
        print("  ratio", ratio, "worst momentum error", worst, "vs step impulse", scale)
        s.check(worst <= 1e-3 * scale, "ratio " + String(ratio) + ": momentum changes only by gravity")
        s.check(cp.max_imbalance <= 1e-12, "ratio " + String(ratio) + ": coupler imbalance is zero")


def case_free_fall(mut s: Suite) raises:
    var cp = pair(0.05, G, 1, 1.0)
    var counters = Counters()
    var worst_rel: Real = 0
    for k in range(200):
        cp.step(DT, counters)
        var t = Real(k + 1) * DT
        var rel = abs(cp.b.v[1] + 9.8 * t) / (9.8 * t)
        if rel > worst_rel:
            worst_rel = rel
    var t_end = 200 * DT
    var vy = cp.b.v[1]
    var rel_end = abs(vy + 9.8 * t_end) / (9.8 * t_end)
    var reaction = abs(cp.b.j[1]) / (cp.b.m * 9.8 * DT)
    print("  free fall: anchor vy", vy, "vs -g t", -9.8 * t_end, "rel", rel_end, "worst over steps", worst_rel)
    print("  last reaction / (M g dt)", reaction)
    s.check(rel_end < 0.01, "attached pair falls at g (anchor speed within 1 % at 0.2 s)")


def case_snapshot(mut s: Suite) raises:
    var counters = Counters()
    var live = pair(0.05, G, 2, 1.0)
    for _ in range(100):
        live.step(DT, counters)
    var w = BinWriter()
    live.write_state(w)
    for _ in range(100):
        live.step(DT, counters)
    var back = pair(0.05, G, 2, 1.0)
    var r = BinReader(w.b.copy())
    back.read_state(r)
    for _ in range(100):
        back.step(DT, counters)
    var same = True
    for i in range(len(live.a.cloth.x)):
        if not same_vec(live.a.cloth.x[i], back.a.cloth.x[i]):
            same = False
    s.check(same and same_vec(live.b.x, back.b.x), "restored pair continues bit for bit (100 steps, ratio 2)")
    print("  snapshot", len(w.b), "bytes")


def main() raises:
    var s = Suite("cloth_anchor")
    case_weight(s)
    case_momentum(s)
    case_free_fall(s)
    case_snapshot(s)
    s.finish()
