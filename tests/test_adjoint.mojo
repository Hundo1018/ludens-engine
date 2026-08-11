"""Compile-time adjoint generation (architecture law v3).

`physics/adjoint.mojo` describes one integration step as a small program and
derives its reverse pass by a `comptime` walk. The claim is that the generated
adjoint is the hand-written one — not close to it, the same numbers — and that
its backward sweep needs one bit per step rather than one node per operation.

ORDINARY    the generated gradient matches the hand-written adjoint bit for
            bit, and both match central finite differences.
INTEGRATION the generated PRIMAL matches `diffsim.rollout_ctrl` in BOTH
            coordinates. The y comparison is the one that matters: gravity, the
            ground spring, the damper and the contact branch only ever touch vy,
            and x never reads vy, so every gradient with respect to these
            controls is blind to all four. Comparing x alone passes with the
            wrong gravity in place -- which is how the first version of this
            file passed while the program folded drag onto the wrong term.
EXTREME     no controls, one control, burst of one, a rollout long enough that
            contact fires on most steps, all-zero controls, and the compile-time
            introspection itself — a program containing a non-linear multiply
            must be reported as non-linear rather than silently differentiated.

WHAT X CANNOT SEE. The controls add to vx; gravity, the spring and the damper
add to vy; and x integrates vx while y integrates vy. The two halves never meet,
so no gradient of x with respect to u depends on gravity at all — and neither
does any gradient of y, which is identically zero. An earlier version of this
file checked only x-gradients and passed twice over while the module had the
wrong gravity constant AND folded drag onto the wrong term. The primal y is the
only observable here that can see any of it.
"""

from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RealF, DualReal
from physics.diffsim import rollout_ctrl, rollout_ctrl_adjoint
from physics.adjoint import (
    rollout_generated, op, concat, program_is_linear, program_marks,
    marks_before, STEP_PROGRAM, STEP_IS_LINEAR, STEP_BITS,
    OP_ADD, OP_MUL, OP_MARK, OP_MULC, R_X, R_Y,
)


def _controls(n: Int, scale: Real) -> List[Real]:
    var u = List[Real](capacity=n)
    for k in range(n):
        u.append(scale * (Real(0.3) + Real(k % 5) * 0.11))
    return u^


def _fd(u: List[Real], burst: Int, dt: Real, k: Int, use_y: Bool) -> Real:
    """Central difference of the chosen final coordinate w.r.t. u[k]."""
    var h = Real(1e-3)
    var up = List[Real](capacity=len(u))
    var um = List[Real](capacity=len(u))
    for i in range(len(u)):
        up.append(u[i])
        um.append(u[i])
    up[k] += h
    um[k] -= h
    var upf = List[RealF](capacity=len(u))
    var umf = List[RealF](capacity=len(u))
    for i in range(len(u)):
        upf.append(RealF(up[i]))
        umf.append(RealF(um[i]))
    var sp = rollout_ctrl[RealF](upf, burst, dt)
    var sm = rollout_ctrl[RealF](umf, burst, dt)
    if use_y:
        return (sp.y.v - sm.y.v) / (2 * h)
    return (sp.x.v - sm.x.v) / (2 * h)


def main() raises:
    var s = Suite("adjoint")

    comptime NOPS = len(STEP_PROGRAM) // 4
    print("  program: linear", STEP_IS_LINEAR, " bits/step", STEP_BITS,
          " ops", NOPS)
    s.check(STEP_IS_LINEAR, "the step program is linear in the registers")
    s.eqi(STEP_BITS, 1, "so its checkpoint is ONE bit per step")

    # ---- ORDINARY: generated == hand-written, bit for bit ----
    var burst = 20
    var dt = Real(1.0) / 120.0
    var u = _controls(6, 1.0)
    var gh = List[Real]()
    var gg = List[Real]()
    var xh = rollout_ctrl_adjoint(u, burst, dt, gh)
    var rg = rollout_generated(u, burst, dt, gg)
    print("  primal — hand", xh, " generated", rg[0])
    s.check(rg[0] == xh, "the generated primal is bit-identical to the hand one")
    var exact = True
    for k in range(len(u)):
        if gg[k] != gh[k]:
            exact = False
    s.check(exact, "and so is every gradient component")

    # ---- INTEGRATION: the primal really is diffsim's step ----
    var uf = List[RealF](capacity=len(u))
    for k in range(len(u)):
        uf.append(RealF(u[k]))
    var base = rollout_ctrl[RealF](uf, burst, dt)
    print("  vs diffsim primal — x", base.x.v, " y", base.y.v,
          " | generated x", rg[0], " y", rg[1])
    s.check(
        abs(Float64(base.x.v - rg[0])) < 1e-5,
        "the generated program reproduces diffsim's x",
    )
    s.check(
        abs(Float64(base.y.v - rg[1])) < 1e-5,
        "and its y -- which is what pins gravity, the spring and the damper",
    )

    # X gradient against finite differences
    var worst_x = Real(0)
    for k in range(len(u)):
        var e = abs(gg[k] - _fd(u, burst, dt, k, False))
        if e > worst_x:
            worst_x = e
    print("  worst |generated - central difference| on x:", worst_x)
    s.check(Float64(worst_x) < 2e-3, "the x gradient matches finite differences")

    # The Y gradient is identically zero here, and that is a STRUCTURAL fact
    # rather than a coincidence: a control adds to vx, and y is driven only by
    # vy. Asserting it is worth doing -- an adjoint that leaked a coupling
    # between the two would show up as a non-zero entry -- but it must not be
    # mistaken for a check on gravity or the spring, which no gradient with
    # respect to these controls can reach. The primal y above is what does that.
    var gy = List[Real]()
    var ry = rollout_generated(u, burst, dt, gy, R_Y)
    var worst_y = Real(0)
    var worst_fd = Real(0)
    for k in range(len(u)):
        if abs(gy[k]) > worst_y:
            worst_y = abs(gy[k])
        var f = abs(_fd(u, burst, dt, k, True))
        if f > worst_fd:
            worst_fd = f
    print("  largest |d(y)/du| — generated", worst_y, " finite difference", worst_fd)
    s.check(
        Float64(worst_y) == 0.0,
        "d(y)/du is exactly zero: the adjoint invents no coupling between the"
        " horizontal controls and the vertical state",
    )
    s.check(
        Float64(worst_fd) < 1e-3,
        "and finite differences agree that there is none",
    )

    # forward-mode dual on the same problem, as a third opinion
    var ud = List[DualReal](capacity=len(u))
    for k in range(len(u)):
        ud.append(DualReal(u[k], Real(1) if k == 2 else Real(0)))
    var sd = rollout_ctrl[DualReal](ud, burst, dt)
    print("  forward dual d(x)/d(u[2]):", sd.x.b, " generated:", gg[2])
    s.check(
        abs(Float64(sd.x.b - gg[2])) < 1e-4,
        "and forward-mode duals agree with the generated reverse pass",
    )

    # ---- EXTREME ----
    var g0 = List[Real]()
    var e0 = List[Real]()
    var r0 = rollout_generated(e0, burst, dt, g0)
    s.eqi(len(g0), 0, "no controls yields an empty gradient")
    s.check(
        Float64(r0[0]) == 0.0,
        "and no horizontal motion, since only a control can start it",
    )

    var u1 = _controls(1, 1.0)
    var g1 = List[Real]()
    var gh1 = List[Real]()
    var r1 = rollout_generated(u1, burst, dt, g1)
    var xh1 = rollout_ctrl_adjoint(u1, burst, dt, gh1)
    s.check(g1[0] == gh1[0], "a single control matches the hand adjoint")
    s.check(r1[0] == xh1, "and so does its primal")

    var gb = List[Real]()
    var ghb = List[Real]()
    var rb = rollout_generated(u, 1, dt, gb)
    var xhb = rollout_ctrl_adjoint(u, 1, dt, ghb)
    var b_exact = True
    for k in range(len(u)):
        if gb[k] != ghb[k]:
            b_exact = False
    s.check(b_exact, "a burst of one still matches exactly")
    s.check(rb[0] == xhb, "primal too")

    # long enough that the ball is resting on the ground for most of it, so the
    # contact branch is taken on the majority of steps
    var ulong = _controls(20, 1.0)
    var gl = List[Real]()
    var ghl = List[Real]()
    var rl = rollout_generated(ulong, 40, dt, gl)
    var xhl = rollout_ctrl_adjoint(ulong, 40, dt, ghl)
    var l_exact = True
    for k in range(len(ulong)):
        if gl[k] != ghl[k]:
            l_exact = False
    print("  long rollout (800 steps) final y:", rl[1])
    s.check(l_exact, "800 steps with contact active still match exactly")
    s.check(
        Float64(rl[1]) < 0.05,
        "and the ball really is on the ground, so the branch was exercised",
    )

    var uz = List[Real](capacity=4)
    for _ in range(4):
        uz.append(0)
    var gz = List[Real]()
    var ghz = List[Real]()
    var rz = rollout_generated(uz, burst, dt, gz)
    var xhz = rollout_ctrl_adjoint(uz, burst, dt, ghz)
    s.check(
        Float64(rz[0]) == 0.0, "zero controls leave the ball on the y axis"
    )
    var z_exact = True
    for k in range(4):
        if gz[k] != ghz[k]:
            z_exact = False
    s.check(z_exact, "and the gradient is still exact there")
    s.check(Float64(gz[0]) > 0, "a control at rest still moves the landing point")

    # ---- EXTREME: the compile-time introspection itself ----
    var nonlin = List[List[Int]]()
    nonlin.append(op(OP_ADD, 4, 0, 1))
    nonlin.append(op(OP_MUL, 5, 4, 2))
    var np = concat(nonlin)
    s.check(
        not program_is_linear(np),
        "a variable-times-variable product makes a program non-linear",
    )
    s.check(STEP_IS_LINEAR, "and the step program is not that")

    var two = List[List[Int]]()
    two.append(op(OP_MARK, 0, 1, 0))
    two.append(op(OP_MULC, 4, 1, 0))
    two.append(op(OP_MARK, 0, 3, 0))
    two.append(op(OP_ADD, 5, 4, 3))
    var tp = concat(two)
    s.eqi(program_marks(tp), 2, "two marks are counted as two bits")
    s.eqi(marks_before(tp, 0), 0, "no marks precede the first instruction")
    s.eqi(marks_before(tp, 2), 1, "one precedes the third")
    s.eqi(
        marks_before(tp, 3), 2,
        "and two precede the fourth -- which is how a SELECT gets a fixed bit"
        " index instead of 'the most recent one'",
    )

    s.finish()
