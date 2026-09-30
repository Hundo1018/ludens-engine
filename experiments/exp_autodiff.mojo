"""Experiment R1 — geometric algebra + forward-mode automatic differentiation.

Now built on the engine's official generic types: `DualReal` (geometry.field)
flows through `GMV[2,0,1, DualReal]` (geometry.gmv) — the same comptime product
tables as `Multivector`, with the coefficient field swapped for dual numbers —
so the gradient of any GA expression falls out of the ε-lane automatically.

Demo: 1-DOF inverse kinematics. A motor M(θ) = T·R(θ) moves an effector point;
we descend d/dθ of the squared distance to a target. The autodiff derivative is
cross-checked against a central finite difference each step.

Run: pixi run mojo run -I build experiments/exp_autodiff.mojo
"""

from std.math import sqrt
from geometry.vec import Real, Vec2
from geometry.field import DualReal, dcos, dsin
from geometry.gmv import GMV

comptime DMV = GMV[2, 0, 1, DualReal]  # PGA2 over dual numbers


def motor2(theta: DualReal, tx: Real, ty: Real) -> DMV:
    """M(θ) = T(tx,ty)·R(θ) with dual coefficients (θ carries the seed)."""
    var rot = DMV()
    var half = DualReal(theta.a * 0.5, theta.b * 0.5)
    rot.c[0] = dcos(half)
    rot.c[0b011] = DualReal.zero() - dsin(half)  # -sin(θ/2) e12 (CCW)
    var tr = DMV()
    tr.c[0] = DualReal.const(1)
    tr.c[0b101] = DualReal.const(tx * 0.5)
    tr.c[0b110] = DualReal.const(ty * 0.5)
    return tr * rot


def apply_point(m: DMV, x: Real, y: Real) -> Tuple[DualReal, DualReal]:
    """Sandwich on the PGA2 point `e12 + x e20 - y e10`."""
    var P = DMV()
    P.c[0b011] = DualReal.const(1)
    P.c[0b110] = DualReal.const(x)
    P.c[0b101] = DualReal.const(-y)
    var R = m * P * m.reverse()
    return (R.c[0b110], DualReal.zero() - R.c[0b101])


def loss_and_grad(theta: Real, arm: Real, target: Vec2) -> Tuple[Real, Real]:
    """Loss f(θ) = |M(θ)·(arm,0) − target|², differentiated through the algebra."""
    var m = motor2(DualReal.seed(theta), 0, 0)
    var pt = apply_point(m, arm, 0)
    var dx = pt[0] - DualReal.const(target[0])
    var dy = pt[1] - DualReal.const(target[1])
    var f = dx * dx + dy * dy
    return (f.a, f.b)


def main():
    var arm = Real(2.0)
    var target = Vec2(0.4, sqrt(Real(4.0 - 0.16)))  # on the arm circle: |t| = 2
    var theta = Real(0.1)

    print("== 1-DOF IK by GA autodiff (arm=2, target on the reach circle) ==")
    for it in range(12):
        var fg = loss_and_grad(theta, arm, target)
        comptime H = Real(1e-3)
        var fp = loss_and_grad(theta + H, arm, target)
        var fm = loss_and_grad(theta - H, arm, target)
        var fd = (fp[0] - fm[0]) / (2 * H)
        if it % 3 == 0:
            print(
                "  it", it, " θ=", theta, " loss=", fg[0],
                " dloss(AD)=", fg[1], " dloss(FD)=", fd,
            )
        theta -= 0.1 * fg[1]

    var final = loss_and_grad(theta, arm, target)
    print("final θ:", theta, " loss:", final[0], "(expect ≈ 0)")
