# tier: integration
"""Strand vs rope vs the hanging-chain mode (ROADMAP 17.57).

A chain of 16 x 2 cm links hanging from a fixed point, released from a
5 degree tilt; the period of the tip's swing (zero crossings over 4 s) is
compared with the first mode of a continuous hanging chain,
T1 = 2 pi / (1.2025 sqrt(g / L)) = 0.944 s (Bessel J0's first zero / 2).

  1. Ordinary: `Rope` (XPBD, one end pinned) swings with T1 within 3 %
     (16 discrete links; 0.964 s measured).
  2. Integration (finding): `StrandSet` (Follow-The-Leader) does not: its
     swing period is set by `ftl_damping`, not by g and L -- 0.79 s at 0.5,
     2.22 s at the default 0.9 (> 2 T1), monotone in it. The value that
     matches T1 depends on resolution (0.62 here; 0.53 at dt 1/60, 0.68 with
     32 links: measured, ROADMAP 17.57), so it is not a calibration. Use
     `Rope` where swing timing matters; strands are for looks.
  3. Extreme: with `ftl_damping` 1 the strand does not swing back through
     the vertical within 4 s.
"""

from std.math import sqrt, sin, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet
from physics.rope import Rope

comptime N = 16
comptime SEG: Real = 0.02
comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 960


def period(xs: List[Real]) -> Real:
    var cross = List[Real]()
    for k in range(1, len(xs)):
        if xs[k - 1] < 0 and xs[k] >= 0:
            var f = -xs[k - 1] / (xs[k] - xs[k - 1])
            cross.append((Real(k - 1) + f) * DT)
    if len(cross) < 2:
        return -1
    return (cross[len(cross) - 1] - cross[0]) / Real(len(cross) - 1)


def tilt() -> Vec3:
    return Vec3(sin(Real(0.087)), -cos(Real(0.087)), 0, 0)


def strand_period(fd: Real) raises -> Real:
    var s = StrandSet(0.0, 0.0, fd, 0.002, 0)
    var bone: List[Pose6] = [Pose6(Vec3(0, 1, 0, 0), Quat.identity())]
    _ = s.add(0, bone[0], Vec3(0, 0, 0, 0), tilt(), N + 1, SEG)
    var xs = List[Real]()
    for _ in range(STEPS):
        s.step(DT, G, bone)
        xs.append(s.tip(0)[0])
    return period(xs)


def main() raises:
    var st = Suite("strand_rope_parity")
    var L = Real(N) * SEG
    var t1 = 2 * Real(pi) / (1.2025 * sqrt(9.8 / L))
    var r = Rope(Vec3(0, 1, 0, 0), Vec3(0, 1, 0, 0) + tilt() * L, N, 0.1)
    r.pin(0, Vec3(0, 1, 0, 0))
    var xr = List[Real]()
    for _ in range(STEPS):
        r.advance(DT, G)
        xr.append(r.x[N][0])
    var tr = period(xr)
    var p5 = strand_period(0.5)
    var p9 = strand_period(0.9)
    var p10 = strand_period(1.0)
    print("first mode T1", t1, ";  rope", tr, ";  strand ftl_damping 0.5", p5, " 0.9 (default)", p9, " 1.0", p10)
    st.check(abs(tr / t1 - 1) < 0.03, "the rope swings at the hanging chain's first mode (3 %)")
    st.check(p5 < t1 and p9 > 2 * t1, "the strand's period is set by ftl_damping: below T1 at 0.5, over 2 T1 at the default")
    st.check(p10 < 0, "ftl_damping 1: no swing back within 4 s")
    st.finish()
