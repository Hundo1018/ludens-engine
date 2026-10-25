# tier: integration
"""Hair strands <-> lattice air, two-way (ROADMAP 17.61,
`physics.strand_air`).

Air: `Lbm` 24^3, periodic, dx 2 cm, 1 ms per lattice step, rho 1.2,
lattice viscosity 0.05, initial wind 0.4 m/s along +x. Strands: a 6 x 6
brush hanging down from roots 2 cm apart at y 0.40 m, 8 particles 3 cm
apart, drag rate 20 /s, 0.1 g per particle (25 g in all).

  1. Ordinary: the wind bends the brush downstream (tips move +x); with
     the air slowed by the brush (two-way) the tips bend less than with
     an untouched wind (one-way); the air downstream of the brush is
     slower than the air beside it (wake).
  2. Integration: two-way, the air's momentum changes by the impulse it
     got (1e-3) and that impulse is the strands' with the sign flipped;
     one-way, the air's momentum changes only by rounding (1e-5).
  3. Extreme: particle_mass <= 0 raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from fluid.lbm import Lbm
from physics.rigid6 import Pose6
from physics.strand import StrandSet
from physics.strand_air import StrandAir

comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime G = Vec3(0, -9.8, 0, 0)


def air() -> Lbm:
    var l = Lbm(24, 24, 24, 0.05)
    l.init_uniform(1.0, 0.02, 0.0, 0.0)
    return l^


def brush(bones: List[Pose6]) raises -> StrandSet:
    var ss = StrandSet(0.0, 20.0)
    for i in range(6):
        for k in range(6):
            _ = ss.add(0, bones[0], Vec3(0.19 + Real(i) * 0.02, 0.40, 0.19 + Real(k) * 0.02, 0), Vec3(0, -1, 0, 0), 8, 0.03)
    return ss^


def mean_tip_x(ss: StrandSet) -> Real:
    var s = Real(0)
    for k in range(ss.strands()):
        s += ss.tip(k)[0]
    return s / Real(ss.strands())


def main() raises:
    var s = Suite("strand_air")
    var bones: List[Pose6] = [Pose6(Vec3(0, 0, 0, 0), Quat.identity())]
    var b1 = brush(bones)
    var a1 = StrandAir(air(), Vec3(0, 0, 0, 0), DX, DT, 1.2, 1e-4, two_way=False)
    var b2 = brush(bones)
    var a2 = StrandAir(air(), Vec3(0, 0, 0, 0), DX, DT, 1.2, 1e-4)
    var p1 = a1.air_momentum()
    var p2 = a2.air_momentum()
    var x0 = mean_tip_x(b1)
    for _ in range(400):
        a1.step(b1, G, bones)
        a2.step(b2, G, bones)
    var t1 = mean_tip_x(b1) - x0
    var t2 = mean_tip_x(b2) - x0
    print("after 0.4 s: mean tip shift +x  one-way", t1, " two-way", t2)
    var d2 = a2.air_momentum() - p2
    print("  two-way: air momentum change x", d2[0], " air impulse", a2.air_impulse[0], " strand impulse", a2.strand_impulse[0])
    var behind = a2.air_velocity(Vec3(0.34, 0.30, 0.24, 0))[0]
    var beside = a2.air_velocity(Vec3(0.34, 0.30, 0.02, 0))[0]
    print("  air vx downstream of the brush", behind, " beside it", beside, "  one-way air momentum change", length(a1.air_momentum() - p1))
    s.check(t1 > 0.01 and t2 > 0, "the wind bends the brush downstream")
    s.check(t2 < t1, "two-way: the slowed air bends the brush less")
    s.check(behind < beside, "two-way: a wake downstream of the brush")
    s.check(d2[0] < 0 and abs(d2[0] - a2.air_impulse[0]) < 1e-3 * abs(a2.air_impulse[0]), "two-way: air momentum changes by its impulse (1e-3)")
    s.check(length(a2.air_impulse + a2.strand_impulse) < 1e-6 * length(a2.air_impulse), "two-way: impulses equal and opposite")
    # a moving uniform lattice drifts by f32 rounding alone (7.5e-8 N s of 0.05)
    s.check(length(a1.air_momentum() - p1) < 1e-5 * length(p1), "one-way: air momentum unchanged (1e-5, rounding)")
    var raised = False
    try:
        _ = StrandAir(air(), Vec3(0, 0, 0, 0), DX, DT, 1.2, 0.0)
    except:
        raised = True
    s.check(raised, "particle_mass <= 0 raises")
    s.finish()
