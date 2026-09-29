"""Ropes and cables (ROADMAP 17.41).

A rope is a 1-D XPBD chain: particles joined by distance constraints of
compliance `alpha` (0 = inextensible), stepped in its own substeps. Either
end can be pinned to a world point or attached to a point on a
`ContactScene6` body (in the body's frame); the end particle follows that
point every substep. Loads go through the solver: `tie` adds a distance
joint of the rope's length between the two ends, so a crate hanging on the
rope is carried like one on a joint and the rope snaps through the 17.29
break thresholds (the XPBD particles only give the rope its shape and let
it drape over things -- one-way, the way engines' cable components are
paired with a physics constraint). Particles are pushed out of the scene's
colliders (optional). A segment whose own XPBD tension exceeds
`break_tension` also snaps.

Parity target (the seam): hung between two fixed points under gravity with
no bending stiffness, the rope rests on the catenary y = a cosh(x / a) + c
for its length -- the same curve a chain of rigid links on distance joints
approaches as the links get short (`test_rope`).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from collision.world_query import QueryFilter
from .rigid6 import Body6, QuatBody6, Inertia3
from .solver6 import ContactScene6
from .joints6 import Joint6, JOINT_BROKEN


struct Rope(Copyable, Movable):
    var x: List[Vec3]
    var prev: List[Vec3]
    var v: List[Vec3]
    var w: List[Real]  # inverse mass per particle (0 = pinned)
    var rest: List[Real]  # rest length per segment
    var lam: List[Real]  # XPBD multipliers (per substep)
    var cut: List[Bool]  # snapped segments
    var alpha: Real  # compliance
    var radius: Real  # particle collision radius (0 = no collision)
    var break_tension: Real
    var tension: List[Real]  # last substep's tension per segment (N)
    var end_body: List[Int]  # [a, b]: body index or -1
    var end_local: List[Vec3]
    var damping: Real
    var tie_joint: Int  # the scene joint carrying the load (-1: none)

    def __init__(
        out self, a: Vec3, b: Vec3, segments: Int, mass: Real,
        alpha: Real = 0, radius: Real = 0, length: Real = -1,
    ):
        """A rope of `segments` segments laid straight from `a` to `b`;
        `length` (default |b - a|) sets the rest length, so a rope longer
        than the gap sags."""
        var n = segments + 1
        var d = b - a
        var total = length if length > 0 else sqrt(dot(d, d))
        self.x = List[Vec3]()
        self.prev = List[Vec3]()
        self.v = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.w = List[Real]()
        for i in range(n):
            var p = a + d * (Real(i) / Real(segments))
            self.x.append(p)
            self.prev.append(p)
            self.w.append(Real(n) / mass)
        self.rest = List[Real](length=segments, fill=total / Real(segments))
        self.lam = List[Real](length=segments, fill=0)
        self.cut = List[Bool](length=segments, fill=False)
        self.tension = List[Real](length=segments, fill=0)
        self.alpha = alpha
        self.radius = radius
        self.break_tension = Real.MAX
        self.end_body = List[Int](length=2, fill=-1)
        self.end_local = List[Vec3](length=2, fill=Vec3(0, 0, 0, 0))
        self.damping = 0.999
        self.tie_joint = -1

    def pin(mut self, end: Int, p: Vec3):
        """Fix end 0 or 1 at world point `p`."""
        var i = 0 if end == 0 else len(self.x) - 1
        self.x[i] = p
        self.prev[i] = p
        self.w[i] = 0
        self.end_body[end] = -1

    def attach[B: Body6](mut self, end: Int, sc: ContactScene6[B], body: Int, local: Vec3):
        """Tie end 0 or 1 to `local` (body frame) on scene body `body`."""
        var i = 0 if end == 0 else len(self.x) - 1
        self.end_body[end] = body
        self.end_local[end] = local
        var p = sc.bset.bodies[body].act(local)
        self.x[i] = p
        self.prev[i] = p
        self.w[i] = 0

    def tie(mut self, mut sc: ContactScene6[QuatBody6], break_tension: Real = Real.MAX) raises -> Int:
        """Give the rope a load path in the solver: a distance joint of the
        rope's rest length between its two ends (a pinned end gets a
        static, non-colliding anchor body). The joint carries whatever hangs
        on the rope -- the XPBD particles only shape it -- so a crate on a
        rope weighs on its support exactly as on a joint, and the rope snaps
        through the 17.29 break machinery when `break_tension` is exceeded.
        The joint is bilateral: a taut cable, no slack in the load path."""
        var ids = List[Int]()
        var loc = List[Vec3]()
        for e in range(2):
            var i = 0 if e == 0 else len(self.x) - 1
            if self.end_body[e] >= 0:
                ids.append(self.end_body[e])
                loc.append(self.end_local[e])
            else:
                var a = sc.add(
                    QuatBody6.at_rest(self.x[i], Inertia3.box(1, 0.01, 0.01, 0.01)),
                    Vec3(0.01, 0.01, 0.01, 0), True,
                )
                sc.set_filter(a.index(), 0, 0)
                ids.append(a.index())
                loc.append(Vec3(0, 0, 0, 0))
        var total = Real(0)
        for s in range(len(self.rest)):
            total += self.rest[s]
        self.tie_joint = sc.add_joint(Joint6.distance(ids[0], ids[1], loc[0], loc[1], total))
        if break_tension < Real.MAX:
            sc.set_joint_break(self.tie_joint, break_tension, Real.MAX)
        return self.tie_joint

    def length(self) -> Real:
        var l = Real(0)
        for s in range(len(self.rest)):
            var d = self.x[s + 1] - self.x[s]
            l += sqrt(dot(d, d))
        return l

    def step[B: Body6](
        mut self, mut sc: ContactScene6[B], dt: Real, gravity: Vec3,
        substeps: Int = 8, iters: Int = 4,
    ) raises:
        var h = dt / Real(substeps)
        var n = len(self.x)
        # the load-bearing joint snapped (17.29): cut the rope in the middle
        if self.tie_joint >= 0 and sc.joints[self.tie_joint].kind == JOINT_BROKEN:
            self.cut[len(self.cut) // 2] = True
            self.tie_joint = -1
        var ah = self.alpha / (h * h)
        for _ in range(substeps):
            # pinned ends follow their bodies
            for e in range(2):
                var bi = self.end_body[e]
                if bi >= 0:
                    var i = 0 if e == 0 else n - 1
                    self.x[i] = sc.bset.bodies[bi].act(self.end_local[e])
            # predict
            for i in range(n):
                self.prev[i] = self.x[i]
                if self.w[i] > 0:
                    self.v[i] = self.v[i] + gravity * h
                    self.x[i] = self.x[i] + self.v[i] * h
            for s in range(len(self.lam)):
                self.lam[s] = 0
            # XPBD distance constraints
            for _ in range(iters):
                for s in range(len(self.rest)):
                    if self.cut[s]:
                        continue
                    var wa = self.w[s]
                    var wb = self.w[s + 1]
                    var ws = wa + wb
                    if ws <= 0:
                        continue
                    var d = self.x[s + 1] - self.x[s]
                    var l = sqrt(max(dot(d, d), Real(1e-12)))
                    var c = l - self.rest[s]
                    var dl = (-c - ah * self.lam[s]) / (ws + ah)
                    self.lam[s] += dl
                    var corr = d * (dl / l)
                    self.x[s] = self.x[s] - corr * wa
                    self.x[s + 1] = self.x[s + 1] + corr * wb
            # tension and snapping
            for s in range(len(self.rest)):
                self.tension[s] = abs(self.lam[s]) / (h * h)
                if self.tension[s] > self.break_tension:
                    self.cut[s] = True
            # collide with the scene
            if self.radius > 0:
                for i in range(n):
                    if self.w[i] == 0:
                        continue
                    var hits = sc.overlap_sphere(self.x[i], self.radius, QueryFilter.all())
                    for k in range(len(hits)):
                        var b = hits[k]
                        if b == self.end_body[0] or b == self.end_body[1]:
                            continue
                        var pr = sc.closest_point(b, self.x[i])
                        if pr.dist < self.radius:
                            self.x[i] = self.x[i] + pr.normal * (self.radius - pr.dist)
            # velocities from the corrected positions, lightly damped
            for i in range(n):
                if self.w[i] > 0:
                    self.v[i] = (self.x[i] - self.prev[i]) * (self.damping / h)
