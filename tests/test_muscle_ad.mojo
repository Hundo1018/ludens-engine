# tier: component
"""Differentiable muscle control (ROADMAP 17.57, `physics.muscle_ad`).

  1. Ordinary: `hill_force_f[RealF]` equals `HillParams`' fl * fv * a + fp
     at 12 fiber lengths x velocities (shortening, lengthening, past
     -vmax, stretched past optimal) to 1e-4 relative (floor 1e-3).
  2. Integration: the final angle of a 0.6 s reach (1-DOF arm, flexor +
     extensor, 3 control windows each) as a function of the 6 controls:
     one `RevReal` sweep matches central differences (`harness.gradcheck`,
     best error < 1e-3 at matching force-velocity branch schedules).
  3. Optimisation: projected gradient descent on (q_T - 0.8)^2 from all
     controls at 0.2 takes the loss down by > 100x, the final angle within
     0.02 rad of the target, every control kept in [0, 1].
"""

from harness.runner import Suite
from harness.gradcheck import GradProblem, gradcheck, default_steps
from geometry.vec import Real
from geometry.field import RealF, RevReal, Tape, rev_seed
from physics.actuator import HillParams
from physics.muscle_ad import hill_force_f, ArmParams, arm_rollout


def params() -> ArmParams:
    var flex = HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10)
    var ext = HillParams.thelen(0.04, 0.1, 0.2, 0.30, 10)
    return ArmParams(flex, ext, 200.0, 0.05, 0.5, 0.04, 1.0 / 240.0, 144)


struct Reach(GradProblem):
    var p: ArmParams

    def __init__(out self, p: ArmParams):
        self.p = p

    def dim(self) -> Int:
        return 6

    def value(self, x: List[Float64]) -> Float64:
        var u = List[RealF]()
        for v in x:
            u.append(RealF(Real(v)))
        return Float64(arm_rollout(self.p, u, 0).v)

    def gradient(self, x: List[Float64], mut g: List[Float64]):
        var t = Tape()
        var u = List[RevReal]()
        for v in x:
            u.append(rev_seed(t, Real(v)))
        var q = arm_rollout(self.p, u, 0)
        var a = t.grad(q.idx)
        for k in range(6):
            g[k] = Float64(a[u[k].idx])

    def schedule(self, x: List[Float64]) -> UInt64:
        # which force-velocity branch each muscle was on, per step
        var u = List[Real]()
        for v in x:
            u.append(Real(v))
        var h: UInt64 = 14695981039346656037
        var q = Real(0)
        var qd = Real(0)
        var af = Real(0)
        var ae = Real(0)
        var p = self.p
        for k in range(p.steps):
            var w = min(k * 3 // p.steps, 2)
            af += (u[w] - af) * (p.dt / p.tau)
            ae += (u[3 + w] - ae) * (p.dt / p.tau)
            var lf = p.flex.l_mt0 - p.flex.tendon_slack - p.flex.arm * q
            var le = p.ext.l_mt0 - p.ext.tendon_slack + p.ext.arm * q
            var ff = hill_force_f(p.flex, RealF(af), RealF(lf), RealF(-p.flex.arm * qd)).v
            var fe = hill_force_f(p.ext, RealF(ae), RealF(le), RealF(p.ext.arm * qd)).v
            var tq = p.f_peak * (p.flex.arm * ff - p.ext.arm * fe) - p.damping * qd
            qd += tq / p.inertia * p.dt
            q += qd * p.dt
            if qd > 0:
                h = (h ^ UInt64(k)) * 1099511628211
        return h


def main() raises:
    var s = Suite("muscle_ad")
    var h = HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10)
    var worst = Real(0)
    for l in [Real(0.06), Real(0.1), Real(0.13)]:
        for v in [Real(-1.5), Real(-0.3), Real(0.0), Real(0.4)]:
            # HillParams speaks joint angle: fiber l at q = (l_mt0 - slack - l) / arm
            var q = (h.l_mt0 - h.tendon_slack - l) / h.arm
            var qd = -v / h.arm
            var want = 0.7 * h.fl(q) * h.fv(qd) + h.fp(q)
            var got = hill_force_f(h, RealF(0.7), RealF(l), RealF(v)).v
            # floor 1e-3 (forces are O(1)): at l = l_opt the passive term is
            # f32 rounding of a ~0 stretch through HillParams' q round trip
            worst = max(worst, abs(got - want) / max(abs(want), Real(1e-3)))
    print("generic Hill force vs HillParams: worst relative difference", worst)
    s.check(worst < 1e-4, "hill_force_f[RealF] == HillParams curves")

    var p = params()
    var x0: List[Float64] = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
    var rep = gradcheck(Reach(p), x0, default_steps())
    print("reach gradient vs central differences: best error", rep.best_error, "at h", rep.best_step, " skipped at h 1e-2:", rep.crossings[0])
    s.check(rep.passed(1e-3), "RevReal gradient of the final angle == central differences")

    var x = x0.copy()
    var prob = Reach(p)
    var target = Float64(0.8)
    var l0 = Float64(0)
    var loss = Float64(0)
    var g = List[Float64](length=6, fill=0)
    var lr = Float64(0.5)
    for it in range(80):
        var qT = prob.value(x)
        loss = (qT - target) * (qT - target)
        if it == 0:
            l0 = loss
        prob.gradient(x, g)
        for k in range(6):
            x[k] = min(1.0, max(0.0, x[k] - lr * 2 * (qT - target) * g[k]))
    var qf = prob.value(x)
    var inside = True
    for k in range(6):
        inside = inside and x[k] >= 0 and x[k] <= 1
    print("reach to 0.8 rad: loss", l0, "->", loss, " final angle", qf, " controls", x[0], x[1], x[2], x[3], x[4], x[5])
    s.check(loss < l0 / 100 and abs(qf - target) < 0.02 and inside, "projected gradient descent reaches the target, controls in [0, 1]")
    s.finish()
