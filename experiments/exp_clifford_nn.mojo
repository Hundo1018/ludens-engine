"""Experiment R3 — Clifford neural physics: geometric product as the linear map.

A two-layer network whose "matmul" is the PGA2 geometric product learns the
engine's own screw integrator: given (pose motor, velocity bivector) predict
the next pose, teacher = `pose * exp_screw2(vel·dt)` (geometry.galie). Because
weights are multivectors and layers are ⊗, the hypothesis class is closed under
rigid motions — the geometric bias Clifford networks are built for.

Training is SPSA (simultaneous-perturbation stochastic approximation): two loss
evaluations per step estimate the full 40-parameter gradient, no backprop
machinery needed for a feasibility probe. Success = train loss falls by orders
of magnitude and held-out pose error is small.

Run: pixi run mojo run -I build experiments/exp_clifford_nn.mojo
"""

from std.math import tanh, sqrt
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real
from geometry.multivector import PGA2
from geometry.motor import Motor2
from geometry.galie import Screw2, exp_screw2

comptime DT = Real(0.1)
comptime NPARAM = 40  # 5 multivector params × 8 blades


def teacher(pose: Motor2, vel: Screw2) -> Motor2:
    return (pose * exp_screw2(vel.scaled(DT))).normalized()


def _mv_motor(m: Motor2) -> PGA2:
    return m.to_mv()


def _mv_screw(v: Screw2) -> PGA2:
    var out = PGA2()
    out.c[0b011] = v.b12
    out.c[0b101] = v.b10
    out.c[0b110] = v.b20
    return out^


def forward(theta: List[Real], pose: Motor2, vel: Screw2) -> Motor2:
    """Predict y = W3 ⊗ tanh(W1⊗pose + W2⊗vel + B) + B2, projected to a motor."""
    var w1 = PGA2()
    var w2 = PGA2()
    var b1 = PGA2()
    var w3 = PGA2()
    var b2 = PGA2()
    comptime for i in range(8):
        w1.c[i] = theta[i]
        w2.c[i] = theta[8 + i]
        b1.c[i] = theta[16 + i]
        w3.c[i] = theta[24 + i]
        b2.c[i] = theta[32 + i]
    var h = w1 * _mv_motor(pose) + w2 * _mv_screw(vel) + b1
    comptime for i in range(8):
        h.c[i] = tanh(h.c[i])
    var y = w3 * h + b2
    var m = Motor2.from_mv(y)
    if m.s < 0:  # canonical sheet of the double cover
        m = Motor2(-m.s, -m.b12, -m.b10, -m.b20)
    return m.normalized()


def sample(mut rng: SplitMix64) -> Tuple[Motor2, Screw2]:
    var pose = Motor2.from_angle_translation(
        Real(rng.next_f32()) * 2 - 1,
        # translation kept modest so coefficients stay O(1)
        Vec2Like(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5),
    )
    var vel = Screw2(
        Real(rng.next_f32()) - 0.5,
        Real(rng.next_f32()) - 0.5,
        Real(rng.next_f32()) - 0.5,
    )
    return (pose, vel)


comptime Vec2Like = SIMD[DType.float32, 2]


def loss(theta: List[Real], mut rng: SplitMix64, batch: Int) -> Real:
    var total = Real(0)
    for _ in range(batch):
        var s = sample(rng)
        var want = teacher(s[0], s[1])
        if want.s < 0:
            want = Motor2(-want.s, -want.b12, -want.b10, -want.b20)
        var got = forward(theta, s[0], s[1])
        total += (
            (got.s - want.s) ** 2
            + (got.b12 - want.b12) ** 2
            + (got.b10 - want.b10) ** 2
            + (got.b20 - want.b20) ** 2
        )
    return total / Real(batch)


def main():
    var rng = SplitMix64.seeded(9)
    var theta = List[Real]()
    for _ in range(NPARAM):
        theta.append(Real(rng.next_f32()) * 0.4 - 0.2)

    print("== Clifford net (⊗ layers) learns the screw integrator ==")
    comptime A = Real(0.15)  # SPSA step
    comptime C = Real(0.05)  # SPSA perturbation
    for it in range(400):
        # simultaneous ±1 perturbation
        var delta = List[Real]()
        for _ in range(NPARAM):
            delta.append(Real(1) if rng.next_f32() > 0.5 else Real(-1))
        var tp = List[Real]()
        var tm = List[Real]()
        for i in range(NPARAM):
            tp.append(theta[i] + C * delta[i])
            tm.append(theta[i] - C * delta[i])
        var eval_rng = SplitMix64.seeded(UInt64(1000 + it))  # paired samples
        var eval_rng2 = SplitMix64.seeded(UInt64(1000 + it))
        var lp = loss(tp, eval_rng, 16)
        var lm = loss(tm, eval_rng2, 16)
        var g = (lp - lm) / (2 * C)
        for i in range(NPARAM):
            theta[i] -= A * g * delta[i]
        if it % 100 == 0 or it == 399:
            var report_rng = SplitMix64.seeded(777)
            print("  iter", it, " loss =", loss(theta, report_rng, 64))

    # held-out check: where does the predicted pose put the origin?
    var test_rng = SplitMix64.seeded(31337)
    var err = Real(0)
    for _ in range(32):
        var s = sample(test_rng)
        var want = teacher(s[0], s[1]).apply_point(Vec2Like(0, 0))
        var got = forward(theta, s[0], s[1]).apply_point(Vec2Like(0, 0))
        err += sqrt((want[0] - got[0]) ** 2 + (want[1] - got[1]) ** 2)
    print("held-out mean |Δorigin| =", err / 32, "(motion scale ≈ 1)")
