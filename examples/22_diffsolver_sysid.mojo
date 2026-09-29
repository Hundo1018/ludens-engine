"""Example 22 — system identification through the contact solver.

The production solver (`ContactScene6`) slides a ball along the floor with an
unknown friction coefficient and reports where it is after 0.5 s. We recover
the coefficient from that one number, two ways, both through
`physics.diffsolver.SphereWorld` -- the differentiable re-statement of the
same contact solve (ROADMAP 17.20 / 17.18):

  1. a coarse scan: eight candidate coefficients in ONE rollout, one per SIMD
     lane of `BatchReal[8]`;
  2. Newton refinement from the best lane, with the derivative
     d(x)/d(mu) carried by `DualReal` through every contact and friction
     impulse.

Run:

    pixi run mojo run -I build examples/22_diffsolver_sysid.mojo
"""

from geometry.vec import Real, Vec3
from geometry.field import SolverField, RealF, DualReal, BatchReal
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.diffsolver import SphereWorld, V3

comptime DT: Real = 1.0 / 60.0
comptime FRAMES = 30
comptime V0: Real = 4.0


def observed_x(mu: Real) -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)),
        Vec3(50, 0.5, 50, 0),
        True,
    )
    var b = QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.sphere(1, 0.5))
    b.vel = Vec3(V0, 0, 0, 0)
    _ = sc.add_sphere(b^, 0.5, False)
    for _ in range(FRAMES):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), mu=mu)
    return sc.bset.bodies[1].position()[0]


def rollout[F: SolverField](mu: F) -> F:
    var w = SphereWorld[F]()
    w.mu = mu
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    _ = w.add_sphere(
        V3[F](F.zero(), F.const(0.5), F.zero()),
        V3[F](F.const(V0), F.zero(), F.zero()),
        F.const(0.5),
        F.const(1),
    )
    for _ in range(FRAMES):
        w.step(DT)
    return w.bodies[0].pos.x


def main():
    var true_mu = Real(0.37)
    var target = observed_x(true_mu)
    print("observed x after", FRAMES, "frames:", target, "(true mu hidden:", true_mu, ")")

    # 1. coarse scan, eight coefficients in one batched rollout
    var cand = SIMD[DType.float32, 8](0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75)
    var xs = rollout[BatchReal[8]](BatchReal[8](cand)).v
    var best = 0
    for k in range(8):
        print("  mu =", cand[k], " x =", xs[k])
        if abs(xs[k] - target) < abs(xs[best] - target):
            best = k
    var mu = cand[best]
    print("scan picks mu =", mu)

    # 2. Newton on x(mu) = target, derivative from forward-mode AD
    for it in range(6):
        var r = rollout[DualReal](DualReal.seed(mu))
        var err = r.a - target
        print("  newton", it, " mu =", mu, " x - target =", err, " dx/dmu =", r.b)
        if abs(err) < 1e-5 or r.b == 0:
            break
        mu = mu - err / r.b
    print("recovered mu =", mu, " error vs truth:", abs(mu - true_mu))
