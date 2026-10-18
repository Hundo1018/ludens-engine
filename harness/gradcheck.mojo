"""Shared gradient check (ROADMAP 17.84).

Each differentiable test used to carry its own finite difference (`_fd` in
`test_adjoint`, `test_gmv_ad`, ...), with its own step and tolerance. This
module is the one implementation: a problem implements `GradProblem`, and
`gradcheck` compares its analytic gradient with central differences at a
sweep of step sizes. `test_adjoint`, `test_diffsim`, `test_diffrigid` and
`test_gmv_ad` use it; the first three hash their contact steps
(`DiffState2.schedule`, `RigidState.schedule`).

Why a sweep: truncation error falls as h^2 and rounding error rises as eps/h,
so a single h either hides a wrong gradient (too large) or reports noise as
a mismatch (too small). The report keeps the error at every h and the best.

Why a schedule hash: through a contact or a clamp the function is piecewise
smooth. A difference whose two evaluations land on different branches
(`schedule(x + h e_i) != schedule(x)`) measures the jump, not the derivative
(the `diffrigid` lesson). Such (h, i) pairs are counted and excluded from the
error at that h; a problem without branches returns a constant.
"""


trait GradProblem:
    def dim(self) -> Int: ...

    def value(self, x: List[Float64]) -> Float64: ...

    def gradient(self, x: List[Float64], mut g: List[Float64]): ...

    # A hash of the discrete decisions taken at `x` (contact set, active
    # clamps); return a constant when there are none.
    def schedule(self, x: List[Float64]) -> UInt64: ...


struct GradReport(Copyable, Movable):
    var steps: List[Float64]
    var errors: List[Float64]  # per step: max_i |fd_i - g_i| / max(1, max |g|)
    var crossings: List[Int]  # per step: components skipped (branch crossed)
    var best_step: Float64
    var best_error: Float64

    def __init__(out self):
        self.steps = List[Float64]()
        self.errors = List[Float64]()
        self.crossings = List[Int]()
        self.best_step = 0
        self.best_error = Float64.MAX

    def passed(self, tol: Float64) -> Bool:
        return self.best_error <= tol


def default_steps() -> List[Float64]:
    return [1e-2, 1e-3, 1e-4, 1e-5, 1e-6, 1e-7]


def gradcheck[P: GradProblem](p: P, x: List[Float64], steps: List[Float64]) -> GradReport:
    var n = p.dim()
    var g = List[Float64](length=n, fill=0)
    p.gradient(x, g)
    var scale = Float64(1)
    for v in g:
        scale = max(scale, abs(v))
    var base = p.schedule(x)
    var rep = GradReport()
    var xp = x.copy()
    for h in steps:
        var worst = Float64(0)
        var crossed = 0
        for i in range(n):
            xp[i] = x[i] + h
            var fp = p.value(xp)
            var sp = p.schedule(xp)
            xp[i] = x[i] - h
            var fm = p.value(xp)
            var sm = p.schedule(xp)
            xp[i] = x[i]
            if sp != base or sm != base:
                crossed += 1
                continue
            worst = max(worst, abs((fp - fm) / (2 * h) - g[i]) / scale)
        rep.steps.append(h)
        rep.errors.append(worst)
        rep.crossings.append(crossed)
        if crossed < n and worst < rep.best_error:
            rep.best_error = worst
            rep.best_step = h
    return rep^


def max_rel_diff(a: List[Float64], b: List[Float64]) -> Float64:
    """The same measure as `gradcheck`, max_i |a_i - b_i| / max(1, max |a|),
    for comparing two analytic gradients (forward vs reverse mode)."""
    var scale = Float64(1)
    for v in a:
        scale = max(scale, abs(v))
    var worst = Float64(0)
    for i in range(len(a)):
        worst = max(worst, abs(a[i] - b[i]) / scale)
    return worst
