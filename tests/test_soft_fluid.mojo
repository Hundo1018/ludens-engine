# tier: integration
"""Soft body <-> lattice fluid, two-way (ROADMAP 17.59,
`physics.cloth_air_parts.SoftPart`).

A 3 x 3 x 3 XPBD soft cube (0.12 m, 50 g) falling through a still 24^3
periodic lattice (dx 2 cm, 1 ms per step, rho 1.2), drag rate 5 /s, 0.3 s,
through `Coupler[SoftPart, AirPart]`.

  1. Ordinary: the cube falls slower than free fall (drag) but keeps
     falling (vy between -g t and 0); per step the coupler's momentum
     imbalance is at rounding level.
  2. Integration: the air's momentum changes by minus what the cube
     received (relative 1e-3) and points down (the cube drags the air
     with it); a pinned particle (w = 0) takes no drag impulse and stays
     put.
  3. Snapshot: `Coupler.write_state` at 0.15 s, a fresh pair read from
     the bytes and run 0.15 s matches the uninterrupted run bit for bit.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from fluid.lbm import Lbm
from diag.counters import Counters
from physics.softbody import SoftBody
from physics.cloth_air import lattice_momentum
from physics.cloth_air_parts import SoftPart, AirPart
from physics.coupler import Coupler, EXPLICIT
from physics.serialize import BinWriter, BinReader

comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime RHO: Real = 1.2
comptime G = Vec3(0, -9.8, 0, 0)


def air() -> Lbm:
    var l = Lbm(24, 24, 24, 0.05)
    l.init_uniform(1.0, 0.0, 0.0, 0.0)
    return l^


def pair(pin: Bool) raises -> Coupler[SoftPart, AirPart]:
    var b = SoftBody.box_lattice(Vec3(0.24, 0.30, 0.24, 0), Vec3(0.06, 0.06, 0.06, 0), 3, 0.05, 1e-5)
    if pin:
        b.pts[26].w = 0
    var xs = List[Vec3]()
    for p in b.pts:
        xs.append(p.x)
    return Coupler[SoftPart, AirPart](SoftPart(b^, 5.0, G), AirPart(air(), Vec3(0, 0, 0, 0), DX, DT, RHO, 1, xs), 1, EXPLICIT)


def mean_vy(c: Coupler[SoftPart, AirPart]) -> Real:
    var s = Real(0)
    var n = 0
    for p in c.a.body.pts:
        if p.w > 0:
            s += p.v[1]
            n += 1
    return s / Real(n)


def main() raises:
    var s = Suite("soft_fluid")
    var counters = Counters()
    var c = pair(False)
    var p0 = lattice_momentum(c.b.lbm, RHO, DX, DT)
    var scale = Real(0)
    for _ in range(300):
        c.step(DT, counters)
        scale = max(scale, length(c.a.received))
    var vy = mean_vy(c)
    print("  0.3 s: mean vy", vy, " free fall", -9.8 * 0.3, " max per-step imbalance", c.max_imbalance, " of impulses up to", scale)
    s.check(vy < 0 and vy > -9.8 * 0.3, "falls, slower than free fall")
    s.check(c.max_imbalance <= 1e-6 * scale, "per-step momentum imbalance at rounding level")
    var dp = lattice_momentum(c.b.lbm, RHO, DX, DT) - p0
    var rel = length(dp + c.a.total) / length(c.a.total)
    print("  air momentum change", dp[1], " cube received", c.a.total[1], " relative mismatch", rel)
    s.check(rel < 1e-3 and dp[1] < 0, "air momentum change = -(cube's drag impulse), pointing down")

    var pc = pair(True)
    var x26 = pc.a.body.pts[26].x
    var jmax = Real(0)
    for _ in range(100):
        pc.step(DT, counters)
        jmax = max(jmax, length(pc.a.jv[26]))
    s.check(jmax == 0 and length(pc.a.body.pts[26].x - x26) == 0, "a pinned particle takes no drag and stays put")

    var live = pair(False)
    for _ in range(150):
        live.step(DT, counters)
    var w = BinWriter()
    live.write_state(w)
    for _ in range(150):
        live.step(DT, counters)
    var back = pair(False)
    var r = BinReader(w.b.copy())
    back.read_state(r)
    for _ in range(150):
        back.step(DT, counters)
    var same = True
    for i in range(len(live.a.body.pts)):
        for k in range(3):
            same = same and live.a.body.pts[i].x[k] == back.a.body.pts[i].x[k] and live.a.body.pts[i].v[k] == back.a.body.pts[i].v[k]
    for i in range(len(live.b.lbm.f)):
        same = same and live.b.lbm.f[i] == back.b.lbm.f[i]
    print("  snapshot at 0.15 s:", len(w.b), "bytes")
    s.check(same, "snapshot -> fresh pair -> 0.15 s: bit for bit")
    s.finish()
