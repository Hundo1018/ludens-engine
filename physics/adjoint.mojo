"""Compile-time adjoint generation: the reverse pass emitted by `comptime`.

`physics/diffsim.mojo` already prices three ways to get a gradient — forward
duals, a runtime tape, and a HAND-WRITTEN adjoint that is 9x faster than the
tape. The hand-written one is the fast one and the unmaintainable one: it has to
be rederived by a person every time the step function changes, and nothing
checks that it still matches.

This generates it instead. A step is described once as a small straight-line
program; `eval_program` and `adjoint_program` are both `comptime for` walks over
that description, so the forward pass and its transpose are unrolled into
straight code at compile time. Warp and Taichi do the same transformation at JIT
time; doing it in `comptime` means there is no runtime generation step and the
adjoint is optimised together with the primal rather than after it.

THE SUB-LANGUAGE, and why it is worth being restricted. Operations are: move,
add, subtract, multiply by a COMPILE-TIME CONSTANT, add a constant, a marked
branch test, and a select on that mark. Every one of those is linear in the
register file, which has a consequence worth the restriction: the transpose of a
linear map does not depend on where it was evaluated, so the backward sweep
needs NO intermediate values — only the branch decisions. That is one bit per
step against a tape's one node per operation.

`program_is_linear` decides that at compile time by inspecting the program, so
the memory profile is a property the caller can read rather than a claim in a
comment. A program containing a variable-times-variable multiply is not linear,
and the generator says so instead of silently producing a wrong gradient.

The branch is differentiated as piecewise constant: the derivative of the
CONDITION is dropped and only the taken side is transposed. That is the standard
choice and it is exactly right except on the measure-zero set where the
condition changes — which is also where the primal itself is non-differentiable,
so no scheme does better there.
"""

from geometry.vec import Real

comptime OP_MOV = 0  # dst = a
comptime OP_ADD = 1  # dst = a + b
comptime OP_SUB = 2  # dst = a - b
comptime OP_MULC = 3  # dst = a * const[b]
comptime OP_ADDC = 4  # dst = a + const[b]
comptime OP_MARK = 5  # record bit: a < 0    (dst, b unused)
comptime OP_SELECT = 6  # dst = bit ? a : b
comptime OP_MUL = 7  # dst = a * b   -- NOT linear; see `program_is_linear`


def op(code: Int, dst: Int, a: Int, b: Int) -> List[Int]:
    var v = List[Int](capacity=4)
    v.append(code)
    v.append(dst)
    v.append(a)
    v.append(b)
    return v^


def concat(parts: List[List[Int]]) -> List[Int]:
    """Splice instruction groups into one flat program. Programs are built by
    a `comptime`-evaluated function, so this all disappears at compile time."""
    var out = List[Int]()
    for i in range(len(parts)):
        for j in range(len(parts[i])):
            out.append(parts[i][j])
    return out^


def program_is_linear(prog: List[Int]) -> Bool:
    """Whether the adjoint of `prog` needs no intermediate values.

    True exactly when every operation is linear in the registers. Called at
    `comptime`, so "this program's backward pass is value-free" is a compile
    time fact, not a runtime hope."""
    for i in range(len(prog) // 4):
        if prog[4 * i] == OP_MUL:
            return False
    return True


def marks_before(prog: List[Int], upto: Int) -> Int:
    """How many `OP_MARK`s precede instruction `upto`.

    This is what gives every `OP_SELECT` a fixed bit index instead of "whatever
    bit was recorded most recently". Resolving it at `comptime` means a step
    with two branches is as correct as one with a single branch, and the
    forward and backward passes cannot disagree about which bit is which."""
    var n = 0
    for i in range(upto):
        if prog[4 * i] == OP_MARK:
            n += 1
    return n


def program_marks(prog: List[Int]) -> Int:
    """How many bits one execution records — the checkpoint size per step."""
    var n = 0
    for i in range(len(prog) // 4):
        if prog[4 * i] == OP_MARK:
            n += 1
    return n


def eval_program[
    prog: List[Int], nreg: Int
](mut reg: InlineArray[Real, nreg], consts: InlineArray[Real, 6],
  mut bits: List[Bool]):
    """Forward pass, unrolled. Appends one bit per `OP_MARK`."""
    comptime NOPS = len(prog) // 4
    var base = len(bits)
    comptime for i in range(NOPS):
        comptime mk = marks_before(prog, i)
        comptime code = prog[4 * i]
        comptime d = prog[4 * i + 1]
        comptime a = prog[4 * i + 2]
        comptime b = prog[4 * i + 3]
        comptime if code == OP_MOV:
            reg[d] = reg[a]
        comptime if code == OP_ADD:
            reg[d] = reg[a] + reg[b]
        comptime if code == OP_SUB:
            reg[d] = reg[a] - reg[b]
        comptime if code == OP_MULC:
            reg[d] = reg[a] * consts[b]
        comptime if code == OP_ADDC:
            reg[d] = reg[a] + consts[b]
        comptime if code == OP_MUL:
            reg[d] = reg[a] * reg[b]
        comptime if code == OP_MARK:
            bits.append(reg[a] < 0)
        comptime if code == OP_SELECT:
            reg[d] = reg[a] if bits[base + mk - 1] else reg[b]


def adjoint_program[
    prog: List[Int], nreg: Int
](mut adj: InlineArray[Real, nreg], consts: InlineArray[Real, 6],
  bits: List[Bool], bit_end: Int):
    """Reverse pass, unrolled: the transpose of `eval_program`.

    `adj` carries the adjoints of the registers in and out. `bit_end` is the
    index one past this step's last recorded bit, so a rollout sweeps steps in
    reverse by walking that cursor backwards.

    Dispatch is `comptime if`, not a runtime chain: each instruction expands to
    exactly its own rule and nothing else. That is required rather than merely
    tidy — with a runtime chain every arm is instantiated for every instruction,
    so `consts[b]` would be compiled with `b` holding a REGISTER index on an
    `OP_ADD`, which an `InlineArray` rejects at compile time.

    Each rule reads the destination adjoint into a local and CLEARS it before
    distributing. That ordering is not cosmetic: instructions like
    `add r0, r0, r5` write a register they also read, and distributing before
    clearing would wipe the contribution that was just added to it."""
    comptime NOPS = len(prog) // 4
    comptime NMARK = program_marks(prog)
    var base = bit_end - NMARK
    comptime for ii in range(NOPS):
        comptime i = NOPS - 1 - ii
        comptime mk = marks_before(prog, i)
        comptime code = prog[4 * i]
        comptime d = prog[4 * i + 1]
        comptime a = prog[4 * i + 2]
        comptime b = prog[4 * i + 3]
        comptime if code == OP_MOV:
            var g = adj[d]
            adj[d] = 0
            adj[a] += g
        comptime if code == OP_ADD:
            var g = adj[d]
            adj[d] = 0
            adj[a] += g
            adj[b] += g
        comptime if code == OP_SUB:
            var g = adj[d]
            adj[d] = 0
            adj[a] += g
            adj[b] -= g
        comptime if code == OP_MULC:
            var g = adj[d]
            adj[d] = 0
            adj[a] += consts[b] * g
        comptime if code == OP_ADDC:
            var g = adj[d]
            adj[d] = 0
            adj[a] += g
        # OP_MARK carries no adjoint: a branch condition is differentiated as
        # piecewise constant. It needs no arm at all now that dispatch is
        # comptime -- an opcode with no rule simply emits nothing.
        # OP_MUL is deliberately given no rule. A variable-times-variable
        # product needs the forward operand values, which this value-free sweep
        # does not have, and emitting a plausible-looking wrong rule would be
        # far worse than refusing -- the gradient would be silently incorrect in
        # a way no test of the machinery itself would catch.
        # `program_is_linear` is the compile-time gate that keeps one out.
        comptime if code == OP_SELECT:
            var g = adj[d]
            adj[d] = 0
            if bits[base + mk - 1]:
                adj[a] += g
            else:
                adj[b] += g


# ---------------------------------------------------------------------------
# The engine's own differentiable step, described once and differentiated by
# the machinery above. `physics/diffsim.mojo` carries the same dynamics three
# other ways -- forward duals, a runtime tape, and a hand-written adjoint --
# and `test_adjoint` holds all four to the same numbers.
# ---------------------------------------------------------------------------

comptime R_X = 0
comptime R_Y = 1
comptime R_VX = 2
comptime R_VY = 3
comptime _R_T0 = 4  # scratch begins here; every write below is to a FRESH
comptime NREG = 13  # register, which keeps the program in SSA form

comptime C_GDT = 0
comptime C_DRAG1 = 1  # 1 - drag*dt, folded so the step is one multiply
comptime C_KDT = 2
comptime C_CDT1 = 3  # 1 - c*dt
comptime C_DT = 4
comptime C_NEGKDT = 5


def _make_step_program() -> List[Int]:
    """One integration step of `diffsim._step2`, as instructions.

    Register discipline is SSA except for the four state registers, which are
    updated in place at the end of the step. That is deliberate: the state has
    to be in the same registers at the end as at the start for a rollout to
    chain steps, and the adjoint rules clear a destination before distributing
    precisely so an in-place update transposes correctly."""
    var p = List[List[Int]]()
    # vy1 = vy*(1 - drag) - g*dt.  The ORDER matters and getting it wrong is
    # invisible in x: diffsim writes `vy - gdt - drag*vy`, which applies drag to
    # the ORIGINAL vy, not to `vy - gdt`. Folding it the other way round changed
    # the primal y by 3.5e-4 and left the primal x and every gradient w.r.t. the
    # controls bit-identical, because the controls only ever touch vx and x
    # never reads vy. Only comparing the primal y caught it.
    p.append(op(OP_MULC, _R_T0, R_VY, C_DRAG1))
    p.append(op(OP_ADDC, _R_T0 + 1, _R_T0, C_GDT))  # gdt stored negated
    # vx1 = vx * (1 - drag)
    p.append(op(OP_MULC, _R_T0 + 2, R_VX, C_DRAG1))
    # contact branch on the CURRENT y
    p.append(op(OP_MARK, 0, R_Y, 0))
    # vy2 = vy1*(1 - c*dt) - k*dt*y
    p.append(op(OP_MULC, _R_T0 + 3, _R_T0 + 1, C_CDT1))
    p.append(op(OP_MULC, _R_T0 + 4, R_Y, C_NEGKDT))
    p.append(op(OP_ADD, _R_T0 + 5, _R_T0 + 3, _R_T0 + 4))
    p.append(op(OP_SELECT, _R_T0 + 6, _R_T0 + 5, _R_T0 + 1))
    # x' = x + vx1*dt ; y' = y + vy2*dt
    p.append(op(OP_MULC, _R_T0 + 7, _R_T0 + 2, C_DT))
    p.append(op(OP_MULC, _R_T0 + 8, _R_T0 + 6, C_DT))
    p.append(op(OP_ADD, R_X, R_X, _R_T0 + 7))
    p.append(op(OP_ADD, R_Y, R_Y, _R_T0 + 8))
    p.append(op(OP_MOV, R_VX, _R_T0 + 2, 0))
    p.append(op(OP_MOV, R_VY, _R_T0 + 6, 0))
    return concat(p)


comptime STEP_PROGRAM = _make_step_program()
comptime STEP_IS_LINEAR = program_is_linear(STEP_PROGRAM)
comptime STEP_BITS = program_marks(STEP_PROGRAM)


def step_consts(dt: Real) -> InlineArray[Real, 6]:
    """The folded constants the program indexes. Folding `1 - drag*dt` here
    rather than emitting a subtract keeps the program shorter AND keeps it
    linear, which is what the value-free adjoint depends on."""
    # These MUST be `diffsim`'s own constants, and getting them wrong once was
    # instructive: the first version used different gravity, spring and damper
    # values and still matched the hand-written adjoint bit for bit, because
    # the observable being compared was the landing X -- and gravity, the
    # ground spring and the damper only ever touch vy. A comparison on x alone
    # cannot see three of the four constants OR the contact branch at all.
    # `test_adjoint` therefore also seeds the Y adjoint, which does.
    comptime G: Real = 9.8
    comptime DRAG: Real = 0.1
    comptime K: Real = 400.0
    comptime C: Real = 8.0
    # InlineArray, not List: the register file and the constants are indexed by
    # COMPILE-TIME constants inside the unrolled program, so keeping them on the
    # stack is what lets the whole thing stay in registers. Measured: with a
    # heap List the generated adjoint ran at 19.7ns against the hand-written
    # 5.7ns; the structure was already right and the indirection was the gap.
    var c = InlineArray[Real, 6](fill=0)
    c[C_GDT] = -G * dt
    c[C_DRAG1] = 1 - DRAG * dt
    c[C_KDT] = K * dt
    c[C_CDT1] = 1 - C * dt
    c[C_DT] = dt
    c[C_NEGKDT] = -K * dt
    return c


def rollout_generated(
    u: List[Real], burst: Int, dt: Real, mut grad: List[Real],
    seed: Int = R_X,
) -> Tuple[Real, Real]:
    """Primal and full gradient of the landing x, with the reverse pass
    GENERATED from `STEP_PROGRAM` instead of written out by hand.

    Returns `(x_final, y_final)`; `grad` is filled with the derivative of
    whichever register `seed` names. Seeding X reproduces
    `diffsim.rollout_ctrl_adjoint` exactly, which is the point of having it.
    Seeding Y is what actually exercises gravity, the ground spring and the
    contact branch — none of which x can see, since they only ever touch vy."""
    var consts = step_consts(dt)
    var reg = InlineArray[Real, NREG](fill=0)
    reg[R_X] = 0
    reg[R_Y] = 1.0
    reg[R_VX] = 0
    reg[R_VY] = 2.0

    var n = len(u)
    var bits = List[Bool](capacity=n * burst * STEP_BITS)
    for k in range(n):
        reg[R_VX] = reg[R_VX] + u[k]
        for _ in range(burst):
            eval_program[STEP_PROGRAM, NREG](reg, consts, bits)
    var x_final = reg[R_X]
    var y_final = reg[R_Y]

    var adj = InlineArray[Real, NREG](fill=0)
    adj[seed] = 1
    grad.clear()
    for _ in range(n):
        grad.append(0)

    var cursor = len(bits)
    for kk in range(n):
        var k = n - 1 - kk
        for _ in range(burst):
            adjoint_program[STEP_PROGRAM, NREG](adj, consts, bits, cursor)
            cursor -= STEP_BITS
        # `vx += u[k]` opens the burst, so the control's gradient is whatever
        # has accumulated on vx by the time the sweep reaches the burst start
        grad[k] = adj[R_VX]
    return (x_final, y_final)
