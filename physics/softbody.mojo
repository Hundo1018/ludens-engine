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

from std.math import sqrt, isfinite
from geometry.vec import Real, Vec3, dot
from .continuum import ContinuumSolver, ContinuumHealth
from .state_io import StateWriter, StateReader

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


struct SoftBody(Movable, Deinitable, ContinuumSolver):
    var pts: List[SP]
    var edges: List[SEdge]
    var alpha: Real  # XPBD compliance (m/N); 0 = hard distance
    var radius: Real  # particle contact radius
    var damp: Real  # velocity retention per substep (1 = lossless)
    var mu: Real  # Coulomb friction vs rigid shapes (0 = frictionless)
    # ROADMAP 17.85: step every `period` scene steps (with period x the
    # substep), offset by `phase`; 1 = every step
    var period: Int
    var phase: Int

    def __init__(out self):
        self.pts = List[SP]()
        self.edges = List[SEdge]()
        self.alpha = 0
        self.radius = 0.02
        self.damp = 0.999
        self.mu = 0.5
        self.period = 1
        self.phase = 0

    def shift(mut self, d: Vec3):
        """Origin rebasing (ROADMAP 17.8): every particle moves by `-d`;
        velocities and rest lengths are translation-invariant."""
        for i in range(len(self.pts)):
            self.pts[i].x -= d

    # ---- substep pieces shared with `soft_couple.softbody_pass` ------------------
    def predict(mut self, h: Real, gravity: Vec3) -> List[Real]:
        """Explicit predict; returns the pre-substep positions (x, y, z per
        particle) for `finish`."""
        var np = len(self.pts)
        var prev = List[Real](capacity=np * 3)
        for i in range(np):
            var p = self.pts[i]
            prev.append(p.x[0])
            prev.append(p.x[1])
            prev.append(p.x[2])
            p.v = p.v + gravity * h
            p.x = p.x + p.v * h
            self.pts[i] = p
        for e in range(len(self.edges)):
            var ed = self.edges[e]
            ed.lam = 0
            self.edges[e] = ed
        return prev^

    def solve_edges(mut self, h: Real, iters: Int):
        """XPBD Gauss-Seidel over the lattice edges."""
        var alpha_h = self.alpha / (h * h)
        for _ in range(iters):
            for e in range(len(self.edges)):
                var ed = self.edges[e]
                var pa = self.pts[ed.a]
                var pb = self.pts[ed.b]
                var d = pa.x - pb.x
                var l = sqrt(max(dot(d, d), Real(1e-12)))
                var cc = l - ed.rest
                var wsum = pa.w + pb.w
                if wsum <= 0:
                    continue
                var dl = (-cc - alpha_h * ed.lam) / (wsum + alpha_h)
                ed.lam += dl
                var corr = d * (dl / l)
                pa.x = pa.x + corr * pa.w
                pb.x = pb.x - corr * pb.w
                self.pts[ed.a] = pa
                self.pts[ed.b] = pb
                self.edges[e] = ed

    def finish(mut self, prev: List[Real], h: Real):
        """Velocities from positions, damped."""
        for i in range(len(self.pts)):
            var p = self.pts[i]
            var pv = Vec3(prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2], 0)
            p.v = (p.x - pv) * (self.damp / h)
            self.pts[i] = p

    # ---- ContinuumSolver (17.55) ----------------------------------------------
    def advance(mut self, dt: Real, gravity: Vec3):
        """`softbody_pass` without a scene (no collisions): 4 substeps x 4
        iterations, the step's defaults; `period` is the scene's business."""
        var h = dt / Real(4)
        for _ in range(4):
            var prev = self.predict(h, gravity)
            self.solve_edges(h, 4)
            self.finish(prev, h)

    def _ok(self, i: Int) -> Bool:
        var p = self.pts[i]
        return isfinite(p.x[0]) and isfinite(p.x[1]) and isfinite(p.x[2]) and isfinite(p.v[0]) and isfinite(p.v[1]) and isfinite(p.v[2])

    def health(self) -> ContinuumHealth:
        var bad = 0
        for i in range(len(self.pts)):
            if not self._ok(i):
                bad += 1
        return ContinuumHealth(bad, 0, 0)

    def quarantine(mut self) -> Int:
        """Pin a non-finite particle at a finite edge neighbour (the origin
        if none) with zero velocity and zero inverse mass."""
        var n = 0
        for i in range(len(self.pts)):
            if self._ok(i):
                continue
            var at = Vec3(0, 0, 0, 0)
            for e in range(len(self.edges)):
                var j = self.edges[e].b if self.edges[e].a == i else (self.edges[e].a if self.edges[e].b == i else -1)
                if j >= 0 and self._ok(j):
                    at = self.pts[j].x
                    break
            self.pts[i] = SP(at, Vec3(0, 0, 0, 0), 0)
            n += 1
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.pts))
        for p in self.pts:
            w.wv(p.x)
            w.wv(p.v)
            w.wf(p.w)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n != len(self.pts):
            raise Error("SoftBody.read_state: particle count differs")
        for i in range(n):
            var x = r.rv()
            var v = r.rv()
            var w = r.rf()
            self.pts[i] = SP(x, v, w)

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
