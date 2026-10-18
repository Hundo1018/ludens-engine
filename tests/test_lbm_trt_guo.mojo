# tier: unit
"""TRT with Guo's second-order body force (ROADMAP 17.60, `Lbm.trt_guo`,
`collide_trt_guo`).

  1. Ordinary: the Poiseuille channel of test_lbm_trt (11 nodes across,
     half-way bounce-back walls) at tau 0.8, 2.0 and 3.5 with
     Lambda = 3/16: the error against the analytic parabola (velocity with
     the F / 2 rho half-force term) is 0.085 % / 0.11 % / 0.025 % --
     flat in tau, the f32 floor at u ~ 2e-4 (asserted < 0.2 %), where the
     velocity-shift TRT gives 0.56 % / 2.5 % / 5.1 %.
  2. Integration: the same channel driven along z (force_z, walls in y):
     the profile matches the x-driven one to 9e-5 of its peak (f32).
  3. Extreme: with trt_guo set but trt_lambda = 0 the BGK step runs
     (populations bit-identical to a lattice without the flag).
"""

from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm import Lbm, BC_PERIODIC, CELL_SOLID

comptime N = 11


def channel(nu: Real, along_z: Bool) -> Lbm:
    var ch = Lbm(4, N, 4, nu, BC_PERIODIC)
    for z in range(4):
        for x in range(4):
            ch.flag[ch.idx(x, 0, z)] = CELL_SOLID
            ch.flag[ch.idx(x, N - 1, z)] = CELL_SOLID
    ch.init_uniform(1.0, 0, 0, 0)
    if along_z:
        ch.force_z = Real(1e-5)
    else:
        ch.force_x = Real(1e-5)
    ch.trt_lambda = 3.0 / 16.0
    ch.trt_guo = True
    var steps = Int(3000 / nu) + 2000
    for _ in range(steps):
        ch.step()
    return ch^


def profile(ch: Lbm, comp: Int) -> List[Real]:
    var out = List[Real]()
    for y in range(1, N - 1):
        var c = ch.idx(2, y, 2)
        var rho = ch.density(c)
        var f = ch.force_x if comp == 0 else ch.force_z
        out.append(ch.velocity(c)[comp] + 0.5 * f / rho)
    return out^


def main() raises:
    var s = Suite("lbm_trt_guo")
    var errs = List[Real]()
    for nu in [Real(0.1), Real(0.5), Real(1.0)]:
        var ch = channel(nu, False)
        var u = profile(ch, 0)
        var hw = Real(N - 2) * 0.5
        var umax = ch.force_x * hw * hw / (2 * nu)
        var worst = Real(0)
        for k in range(len(u)):
            var yy = Real(k + 1) - Real(N - 1) * 0.5
            worst = max(worst, abs(u[k] - ch.force_x * (hw * hw - yy * yy) / (2 * nu)))
        errs.append(worst / umax)
    print("Poiseuille relative error with Guo forcing, tau 0.8 / 2.0 / 3.5:", errs[0], errs[1], errs[2])
    s.check(errs[0] < 2e-3 and errs[1] < 2e-3 and errs[2] < 2e-3, "TRT 3/16 + Guo: Poiseuille within the f32 floor (2e-3) at every tau")

    var cx = channel(0.5, False)
    var cz = channel(0.5, True)
    var ux = profile(cx, 0)
    var uz = profile(cz, 2)
    var d = Real(0)
    var peak = Real(0)
    for k in range(len(ux)):
        d = max(d, abs(ux[k] - uz[k]))
        peak = max(peak, ux[k])
    print("x-driven vs z-driven profile: largest difference", d, " peak", peak)
    s.check(d < 2e-4 * peak, "driving along z gives the x-driven profile (f32, 2e-4 of the peak)")

    var a = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    var b = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    a.init_uniform(1.0, 0.01, 0, 0)
    b.init_uniform(1.0, 0.01, 0, 0)
    a.force_x = 1e-5
    b.force_x = 1e-5
    b.trt_guo = True
    for _ in range(50):
        a.step()
        b.step()
    var same = True
    for k in range(len(a.f)):
        same = same and a.f[k] == b.f[k]
    s.check(same, "trt_guo without trt_lambda runs the BGK step, bit for bit")
    s.finish()
