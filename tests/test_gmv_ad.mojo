# tier: component
"""GMV / Field parity (E1): the coefficient-generic multivector must agree
with the specialized `Multivector` on its value lane (both are generated from
the same comptime sign tables — this asserts the wiring), and its ε-lane must
be a true derivative (checked against central finite differences through a
full motor sandwich)."""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real
from geometry.multivector import Multivector, PGA3
from geometry.field import DualReal, RealF, dcos, dsin
from geometry.gmv import GMV
from harness.gradcheck import GradProblem, gradcheck, default_steps

comptime D3 = GMV[3, 0, 1, DualReal]
comptime R3 = GMV[3, 0, 1, RealF]


def rotor_x(theta: DualReal) -> D3:
    # rotor about z: cos(θ/2) - sin(θ/2) e12; sandwich moves the e1 vector
    var r = D3()
    var half = DualReal(theta.a * 0.5, theta.b * 0.5)
    r.c[0] = dcos(half)
    r.c[0b0011] = DualReal.zero() - dsin(half)
    var v = D3.basis(0b0001, DualReal.const(1))  # e1
    var out = r * v * r.reverse()
    return out^


struct RotorBlade(GradProblem):
    """One coefficient of the rotated e1 as a function of the angle."""

    var blade: Int

    def __init__(out self, blade: Int):
        self.blade = blade

    def dim(self) -> Int:
        return 1

    def value(self, x: List[Float64]) -> Float64:
        return Float64(rotor_x(DualReal.const(Real(x[0]))).c[self.blade].a)

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        g[0] = Float64(rotor_x(DualReal.seed(Real(x[0]))).c[self.blade].b)

    def schedule(self, x: List[Float64]) -> UInt64:
        return 0


def main() raises:
    var s = Suite("gmv_ad")
    var rng = SplitMix64.seeded(29)

    # --- value-lane parity: GMV[DualReal] == Multivector on gp/wedge/reverse ---
    for _ in range(4):
        var a = PGA3()
        var b = PGA3()
        var ga = D3()
        var gb = D3()
        var ra = R3()
        var rb = R3()
        comptime for i in range(PGA3.BLADES):
            var va = Real(rng.next_f32()) * 2 - 1
            var vb = Real(rng.next_f32()) * 2 - 1
            a.c[i] = va
            b.c[i] = vb
            ga.c[i] = DualReal.const(va)
            gb.c[i] = DualReal.const(vb)
            ra.c[i] = RealF(va)
            rb.c[i] = RealF(vb)

        var m = a * b
        var gm = ga * gb
        var rm = ra * rb
        var w = a.wedge(b)
        var gw = ga.wedge(gb)
        var rv = a.reverse()
        var grv = ga.reverse()
        comptime for i in range(PGA3.BLADES):
            s.almost(Float64(gm.c[i].a), Float64(m.c[i]), "gp value lane", 1e-4)
            s.almost(Float64(rm.c[i].v), Float64(m.c[i]), "gp RealF lane", 1e-4)
            s.almost(Float64(gw.c[i].a), Float64(w.c[i]), "wedge value lane", 1e-4)
            s.almost(Float64(grv.c[i].a), Float64(rv.c[i]), "reverse value lane", 1e-4)

    # --- ε-lane is a real derivative: d/dθ through a rotor sandwich ---
    var worst = Float64(0)
    for k in range(5):
        var theta = Float64(Real(k) * 0.37 - 0.9)
        # x-component (e1) and y-component (e2) of the rotated vector
        for blade in [0b0001, 0b0010]:
            var rep = gradcheck(RotorBlade(blade), [theta], default_steps())
            worst = max(worst, rep.best_error)
    print("  rotor sandwich: worst gradcheck error over 5 angles x 2 blades", worst)
    s.check(worst < 1e-3, "ε-lane == central differences (gradcheck)")

    s.finish()
