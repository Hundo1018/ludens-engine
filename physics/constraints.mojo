"""One solver for every constraint the engine has: equality, joint limits,
dry friction, and contact with friction.

The engine solved these in separate passes — limits in `resolve_limits`,
contacts in `resolve_ground` — and separate passes fight. A limit pass that
runs after a contact pass undoes some of the contact impulse, the contact pass
next step undoes some of the limit impulse, and the visible result is a foot
that buzzes against a joint stop. Putting every row in ONE system means each
impulse is computed knowing what the others are doing.

The rows differ only in how their impulse is projected:

    equality       unbounded          a bilateral constraint pushes both ways
    joint limit    f >= 0             a stop pushes, it does not pull
    friction loss  |f| <= f_max       a box: dry friction with a fixed cap
    contact normal f >= 0             same as a limit, different Jacobian
    contact firct. |f| <= mu * f_n    a cone whose size follows the normal

so the solver is one projected Gauss-Seidel loop with a per-row projection,
not four algorithms sharing a file.

The last row is where the interesting choice lives, and it is exposed as a
seam. A PYRAMIDAL cone bounds each tangent component separately, which is
cheap and is what most solvers do; its cost is that the admissible set is a
square, so friction along a diagonal of the tangent basis can reach sqrt(2)
times the limit. An ELLIPTIC cone bounds the tangent vector's magnitude,
which is what Coulomb friction actually says. The difference is not subtle
and it is not a tolerance: it makes sliding friction depend on the direction
of travel relative to an arbitrary basis. `bench_constraints` measures that
anisotropy directly.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, length
from physics.chain import Chain

comptime CON_EQUALITY = 0
comptime CON_LIMIT = 1
comptime CON_FRICTION_LOSS = 2
comptime CON_CONTACT = 3
comptime CON_TANGENT = 4

comptime CONE_PYRAMIDAL = 0
comptime CONE_ELLIPTIC = 1


@fieldwise_init
struct ConRow(Copyable, ImplicitlyCopyable, Movable):
    """One scalar constraint. `jac_at` indexes into the set's flat Jacobian."""

    var kind: Int
    var bias: Real  # target residual velocity (Baumgarte / restitution)
    var cap: Real  # friction-loss bound; ignored otherwise
    var normal_row: Int  # for CON_TANGENT: which normal scales the cone
    var mu: Real
    var partner: Int  # for CON_TANGENT: the other tangent of the same contact


struct ConstraintSet(Movable, ImplicitlyDeletable):
    """Rows over a system described only by its mass matrix and velocity.

    Deliberately not tied to `Chain`. A constraint solver that knows what a
    joint is cannot be tested against a system with an analytic answer, and
    the friction-cone question in particular needs one: a free body has
    `H = m I`, so the exact stopping distance is a closed form and the
    anisotropy measurement has something to be anisotropic against."""

    var n: Int  # generalised coordinates
    var jac: List[Real]  # rows * n, row-major
    var rows: List[ConRow]
    var force: List[Real]  # accumulated impulse per row
    var cone: Int

    def __init__(out self, n: Int):
        self.n = n
        self.jac = List[Real]()
        self.rows = List[ConRow]()
        self.force = List[Real]()
        self.cone = CONE_ELLIPTIC

    def count(self) -> Int:
        return len(self.rows)

    def add(mut self, jac: List[Real], row: ConRow) raises -> Int:
        if len(jac) != self.n:
            raise Error("constraint Jacobian must have one entry per coordinate")
        for i in range(self.n):
            self.jac.append(jac[i])
        self.rows.append(row)
        self.force.append(0)
        return len(self.rows) - 1

    def add_equality(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_EQUALITY, bias, 0, -1, 0, -1))

    def add_limit(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_LIMIT, bias, 0, -1, 0, -1))

    def add_friction_loss(mut self, jac: List[Real], cap: Real) raises -> Int:
        return self.add(jac, ConRow(CON_FRICTION_LOSS, 0, cap, -1, 0, -1))

    def add_contact(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_CONTACT, bias, 0, -1, 0, -1))

    def add_tangents(
        mut self, jt1: List[Real], jt2: List[Real], normal_row: Int, mu: Real
    ) raises -> Int:
        """The two tangent rows of a contact, added together because the
        elliptic projection needs both at once — a cone is a statement about
        the pair, and adding them one at a time would make it impossible to
        express."""
        var a = self.add(jt1, ConRow(CON_TANGENT, 0, 0, normal_row, mu, -1))
        var b = self.add(jt2, ConRow(CON_TANGENT, 0, 0, normal_row, mu, a))
        self.rows[a] = ConRow(CON_TANGENT, 0, 0, normal_row, mu, b)
        return a

    def _row_dot(self, r: Int, v: List[Real]) -> Real:
        var s = Real(0)
        for i in range(self.n):
            s += self.jac[r * self.n + i] * v[i]
        return s

    def solve(
        mut self, var hmat: List[Real], mut qd: List[Real], iters: Int = 20
    ) raises:
        """Projected Gauss-Seidel over every row, in place on `qd`.

        `H⁻¹Jᵀ` is formed ONCE for all rows rather than per row per iteration.
        That is the difference between a solver whose cost grows with
        iteration count and one whose iterations are cheap: the expensive part
        is the factorisation, and it does not change while the impulses do."""
        var m = len(self.rows)
        if m == 0:
            return
        # minv_jt[r] = H⁻¹ Jᵀ_r, one dense solve per row
        var minv_jt = List[Real]()
        for _ in range(m * self.n):
            minv_jt.append(0)
        for r in range(m):
            var rhs = List[Real]()
            for i in range(self.n):
                rhs.append(self.jac[r * self.n + i])
            var col = Chain.solve_h(hmat.copy(), rhs^, self.n)
            for i in range(self.n):
                minv_jt[r * self.n + i] = col[i]
        # diagonal of A = J H⁻¹ Jᵀ
        var adiag = List[Real]()
        for r in range(m):
            var s = Real(0)
            for i in range(self.n):
                s += self.jac[r * self.n + i] * minv_jt[r * self.n + i]
            adiag.append(s if s > 1e-12 else Real(1e-12))

        for r in range(m):
            self.force[r] = 0

        for _ in range(iters):
            for r in range(m):
                var kind = self.rows[r].kind
                if kind == CON_TANGENT and self.cone == CONE_ELLIPTIC:
                    # elliptic rows are solved as a pair, by the lower index
                    if self.rows[r].partner < r:
                        continue
                    self._solve_pair(r, minv_jt, adiag, qd)
                    continue
                var resid = self._row_dot(r, qd) - self.rows[r].bias
                var df = -resid / adiag[r]
                var want = self.force[r] + df
                var clamped = self._project(r, want)
                var applied = clamped - self.force[r]
                self.force[r] = clamped
                for i in range(self.n):
                    qd[i] = qd[i] + minv_jt[r * self.n + i] * applied

    def _project(self, r: Int, f: Real) -> Real:
        var row = self.rows[r]
        if row.kind == CON_EQUALITY:
            return f
        if row.kind == CON_LIMIT or row.kind == CON_CONTACT:
            return f if f > 0 else Real(0)
        if row.kind == CON_FRICTION_LOSS:
            return row.cap if f > row.cap else (-row.cap if f < -row.cap else f)
        # pyramidal tangent: each component bounded independently, which is
        # exactly the approximation that makes the admissible set a square
        var lim = row.mu * self.force[row.normal_row]
        if lim < 0:
            lim = 0
        return lim if f > lim else (-lim if f < -lim else f)

    def _solve_pair(
        mut self,
        r: Int,
        minv_jt: List[Real],
        adiag: List[Real],
        mut qd: List[Real],
    ):
        """Both tangents of one contact, projected onto the friction DISC.

        Solving them separately and then scaling is not the same thing: the
        radial projection has to see the pair as a vector, or the result is
        the square again with extra steps."""
        var b = self.rows[r].partner
        var r1 = self._row_dot(r, qd)
        var r2 = self._row_dot(b, qd)
        var f1 = self.force[r] - r1 / adiag[r]
        var f2 = self.force[b] - r2 / adiag[b]
        var lim = self.rows[r].mu * self.force[self.rows[r].normal_row]
        if lim < 0:
            lim = 0
        var mag = sqrt(f1 * f1 + f2 * f2)
        if mag > lim and mag > 1e-12:
            var k = lim / mag
            f1 = f1 * k
            f2 = f2 * k
        var d1 = f1 - self.force[r]
        var d2 = f2 - self.force[b]
        self.force[r] = f1
        self.force[b] = f2
        for i in range(self.n):
            qd[i] = (
                qd[i]
                + minv_jt[r * self.n + i] * d1
                + minv_jt[b * self.n + i] * d2
            )
