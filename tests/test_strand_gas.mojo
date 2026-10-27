# tier: integration
"""Hair strand <-> 2-D grid gas, two-way (ROADMAP 17.61, `physics.strand_gas`
`StrandGas2`). One strand, the 2-D counterpart of `test_strand_air`.

Gas: `MacFluid2` 32^2, periodic, dx 0.02, nu 1e-3, dt 1/240, uniform +x flow
0.4 m/s. Strand: one hanging strand from (0.20, 0.50), 8 particles 0.03 apart,
drag rate 20 /s, bend 0, 1e-4 kg per particle, gravity 9.8 /s^2 down. The run
is 0.4 s (96 steps).

Predictions, written before the run:

  1. Exact reaction: each `couple` call moves the gas momentum by minus the
     strands' impulse. Largest |dp_gas + J| over 40 calls, relative to the
     largest |J|, below 1e-3 (f32 storage of the faces).
  2. Ordinary: the tip moves +x in both configurations (> 1 mm). The gas
     slowed by the strand gives the two-way tip a smaller shift than the
     one-way tip.
  3. Wake: after 0.4 s the gas just downstream of the strand (x 0.23, y 0.40)
     is slower than the gas beside it at the same x (y 0.10).
  4. The strand stays in the gas plane: largest |z| after the run below 1e-9.
  5. Extreme: particle_mass <= 0 raises.

Measured: recorded in the run output and the ROADMAP 17.61 progress note.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.mac_fluid import MacFluid2
from physics.rigid6 import Pose6
from physics.strand import StrandSet
from physics.strand_gas import StrandGas2

comptime N = 32
comptime DX: Real = 0.02
comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)


def gas() raises -> MacFluid2:
    var f = MacFluid2(N, DX, Real(1e-3))
    for k in range(len(f.u)):
        f.u[k] = 0.4
    return f^


def strand(bones: List[Pose6]) raises -> StrandSet:
    var ss = StrandSet(0.0, 20.0)
    _ = ss.add(0, bones[0], Vec3(0.20, 0.50, 0, 0), Vec3(0, -1, 0, 0), 8, 0.03)
    return ss^


def gas_momentum(f: MacFluid2) -> Tuple[Float64, Float64]:
    """Momentum sum(u) dx^2 and sum(v) dx^2, accumulated in f64."""
    var sx = Float64(0)
    var sy = Float64(0)
    for k in range(len(f.u)):
        sx += Float64(f.u[k])
        sy += Float64(f.v[k])
    return (sx * Float64(DX) * Float64(DX), sy * Float64(DX) * Float64(DX))


def tip_x(ss: StrandSet) -> Real:
    return ss.tip(0)[0]


def main() raises:
    var s = Suite("strand_gas")
    var bones: List[Pose6] = [Pose6(Vec3(0, 0, 0, 0), Quat.identity())]

    # 1. exact reaction, drag step only (strand held in place)
    var f1 = gas()
    var ss1 = strand(bones)
    var c1 = StrandGas2(1e-4)
    var worst_gap = Float64(0)
    var worst_j = Float64(0)
    for _ in range(40):
        var before = gas_momentum(f1)
        var j0x = c1.strand_impulse[0]
        var j0y = c1.strand_impulse[1]
        c1.couple(f1, ss1, DT)
        var after = gas_momentum(f1)
        var jx = Float64(c1.strand_impulse[0] - j0x)
        var jy = Float64(c1.strand_impulse[1] - j0y)
        var dx_gas = after[0] - before[0]
        var dy_gas = after[1] - before[1]
        worst_gap = max(worst_gap, max(abs(dx_gas + jx), abs(dy_gas + jy)))
        worst_j = max(worst_j, max(abs(jx), abs(jy)))
    var ratio = worst_gap / worst_j
    print("  exact reaction: worst |dp_gas + J| / max|J| =", ratio, " (max |J| =", worst_j, ")")
    s.check(ratio < 1e-3, "each drag step: gas momentum change is minus the strand impulse")

    # 2 and 3. ordinary run, two-way and one-way
    var f2 = gas()
    var ss2 = strand(bones)
    var c2 = StrandGas2(1e-4, True)
    var f3 = gas()
    var ss3 = strand(bones)
    var c3 = StrandGas2(1e-4, False)
    var x0 = tip_x(ss2)
    var x0b = tip_x(ss3)
    for _ in range(96):
        c2.step(f2, ss2, G, bones, DT)
        c3.step(f3, ss3, G, bones, DT)
    var shift_two = tip_x(ss2) - x0
    var shift_one = tip_x(ss3) - x0b
    print("  tip shift +x after 0.4 s: one-way", shift_one, " two-way", shift_two)
    s.check(shift_one > 1e-3 and shift_two > 1e-3, "the flow pushes the tip downstream in both configurations")
    s.check(shift_two < shift_one, "the slowed gas pushes the two-way tip less than the one-way tip")

    var wake = f2.velocity(0.23, 0.40)[0]
    var beside = f2.velocity(0.23, 0.10)[0]
    print("  gas u downstream (0.23, 0.40)", wake, " beside (0.23, 0.10)", beside)
    s.check(wake < beside, "the gas just downstream of the strand is slower than the gas beside it")

    var zmax = Real(0)
    for k in range(len(ss2.x)):
        zmax = max(zmax, abs(ss2.x[k][2]))
    print("  largest |z| of the strand", zmax)
    s.check(zmax < 1e-9, "the strand stays in the gas plane")

    # 5. extreme
    var raised = False
    try:
        _ = StrandGas2(0.0)
    except:
        raised = True
    s.check(raised, "particle_mass <= 0 raises")
    s.finish()
