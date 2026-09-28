"""Volumetric XPBD soft bodies for the 6-DOF scene (SOTA capability #9).

A `SoftBody` is a box lattice of particles joined by distance constraints over
the 13 unique neighbour directions (structural + face + body diagonals — the
diagonals are what give the lattice shear/volume stiffness without explicit
volume constraints). Constraints solve as true XPBD: per-substep Lagrange
multipliers with compliance `alpha` (0 = rigid distance), so stiffness is
timestep-independent.

Coupling with rigid bodies is positional-to-impulse, both ways:

  * bodies push particles out (min-penetration-axis projection in the body's
    local frame, using the CURRENT pose — rotating boxes plough correctly);
  * every pushout applies the equivalent impulse `-m_p * dx / h` back to a
    dynamic body at the contact point, and wakes it if it was sleeping.

The solve is sequential Gauss-Seidel — deterministic by construction (gate:
bit-identical repeat runs in `test_softbody`).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot

comptime _DAMP: Real = 0.999


@fieldwise_init
struct SP(Copyable, ImplicitlyCopyable, Movable):
    """One lattice particle. Public (not `SP`): it is the element type of
    `SoftBody.pts`, a public field — a private type in a public field's
    signature is itself the reach-through `physics/serialize.mojo` needs
    (audit F18)."""

    var x: Vec3  # position
    var v: Vec3  # velocity
    var w: Real  # inverse mass


@fieldwise_init
struct SEdge(Copyable, ImplicitlyCopyable, Movable):
    """One structural/diagonal distance constraint. Public for the same
    reason as `SP`: it types `SoftBody.edges`, a public field."""

    var a: Int
    var b: Int
    var rest: Real
    var lam: Real  # XPBD multiplier (reset each substep)


struct SoftBody(Movable, Deinitable):
    var pts: List[SP]
    var edges: List[SEdge]
    var alpha: Real  # XPBD compliance (m/N); 0 = hard distance
    var radius: Real  # particle contact radius
    var damp: Real  # velocity retention per substep (1 = lossless)
    var mu: Real  # Coulomb friction vs rigid shapes (0 = frictionless)

    def __init__(out self):
        self.pts = List[SP]()
        self.edges = List[SEdge]()
        self.alpha = 0
        self.radius = 0.02
        self.damp = 0.999
        self.mu = 0.5

    @staticmethod
    def box_lattice(
        center: Vec3,
        half: Vec3,
        n: Int,
        mass: Real,
        alpha: Real,
    ) raises -> SoftBody:
        """An n*n*n particle lattice filling the box; edges over the 13 unique
        neighbour directions (offsets with positive leading component).

        `n < 2` (audit E4) has no well-defined lattice: the per-particle mass
        divides by `n*n*n` (0/0 = NaN when `n == 0`) and every per-axis
        fractional coordinate below divides by `n - 1` (1/0 = inf when
        `n == 1`), so every particle position comes out non-finite instead of
        the caller's presumably-intended single/degenerate particle."""
        if n < 2:
            raise Error("SoftBody.box_lattice: n must be >= 2")
        var sb = SoftBody()
        sb.alpha = alpha
        var per = mass / Real(n * n * n)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var f = Vec3(
                        Real(i) / Real(n - 1) * 2 - 1,
                        Real(j) / Real(n - 1) * 2 - 1,
                        Real(k) / Real(n - 1) * 2 - 1,
                        0,
                    )
                    sb.pts.append(
                        SP(center + f * half, Vec3(0, 0, 0, 0), 1 / per)
                    )
        sb.radius = (half[0] / Real(n - 1)) * 0.5

        for k in range(n):
            for j in range(n):
                for i in range(n):
                    for dz in range(-1, 2):
                        for dy in range(-1, 2):
                            for dx in range(2):
                                if dx == 0 and (dy < 0 or (dy == 0 and dz <= 0)):
                                    continue  # keep 13 unique directions
                                var ii = i + dx
                                var jj = j + dy
                                var kk = k + dz
                                if ii >= n or jj < 0 or jj >= n or kk < 0 or kk >= n:
                                    continue
                                var a = (k * n + j) * n + i
                                var b = (kk * n + jj) * n + ii
                                var d = sb.pts[a].x - sb.pts[b].x
                                sb.edges.append(
                                    SEdge(a, b, sqrt(dot(d, d)), 0)
                                )
        return sb^

    def top_y(self) -> Real:
        var m = self.pts[0].x[1]
        for i in range(1, len(self.pts)):
            if self.pts[i].x[1] > m:
                m = self.pts[i].x[1]
        return m

    def bottom_y(self) -> Real:
        var m = self.pts[0].x[1]
        for i in range(1, len(self.pts)):
            if self.pts[i].x[1] < m:
                m = self.pts[i].x[1]
        return m

    def max_speed(self) -> Real:
        var m = Real(0)
        for i in range(len(self.pts)):
            var s = dot(self.pts[i].v, self.pts[i].v)
            if s > m:
                m = s
        return sqrt(m)

    def momentum(self) -> Vec3:
        var p = Vec3(0, 0, 0, 0)
        for i in range(len(self.pts)):
            p = p + self.pts[i].v / self.pts[i].w
        return p
