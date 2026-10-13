"""Tiered simulation policies (ROADMAP 17.85). Seam: `TierPolicy`.

A policy turns (scene, observers, step index) into a tier per body slot;
`ContactScene6.set_body_tiers` applies it and the scene's tier table maps a
tier to (iters, substeps, period). The solver gives an island the finest tier
among its members, so a policy only has to rank bodies.

- `DistanceTiers`: distance to the nearest observer against ascending radii,
  with hysteresis (a body moves to a coarser tier only past `radius +
  hysteresis`, back to a finer one inside `radius`). Generalises 17.31's
  `DistanceLOD` (one radius, freeze / unfreeze).
- `CausalReach`: breadth-first search over the contact / joint graph from
  the bodies within `seed_radius` of an observer; contact-graph depth d
  maps to a tier through ascending depth thresholds; bodies the search does
  not reach get the coarsest tier. Near in space but causally far (behind a
  wall, on a separate pile) stays coarse.
- `RoundRobin`: every body in one tier whose period spreads the work; the
  solver's phase (an island's first slot index) makes every island tick
  exactly once per period.
- `BudgetTiers`: `DistanceTiers` whose radii scale with a measured step cost
  (generalises 17.31's `SimBudget`): above the target the radii shrink by
  `shrink`, comfortably below it they grow back to the configured values.

Policies are deterministic functions of their inputs plus their own
hysteresis state; `copy()` the policy alongside a snapshot to replay.
Parity anchor (`test_tiers_parity`): a plan with every body at tier 0, tier 0
= the step's config, is bit-identical to the untiered step.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase


trait TierPolicy(Movable, Deinitable):
    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        """Tier per body slot (len == number of slots)."""
        ...


def _nearest_dist(p: Vec3, observers: List[Vec3]) -> Real:
    var best = Real(1e30)
    for o in observers:
        var d = p - o
        best = min(best, sqrt(dot(d, d)))
    return best


struct DistanceTiers(TierPolicy, Copyable):
    var radii: List[Real]  # ascending: tier t covers up to radii[t]
    var hysteresis: Real
    var last: List[Int]

    def __init__(out self, var radii: List[Real], hysteresis: Real = 1.0) raises:
        for i in range(1, len(radii)):
            if not (radii[i] > radii[i - 1]):
                raise Error("DistanceTiers: radii must be strictly ascending")
        if hysteresis < 0:
            raise Error("DistanceTiers: hysteresis must be >= 0")
        self.radii = radii^
        self.hysteresis = hysteresis
        self.last = List[Int]()

    def tier_for(self, dist: Real, prev: Int) -> Int:
        """Raw tier = first radius covering dist; hysteresis keeps a finer
        previous tier until dist exceeds its radius + hysteresis."""
        var t = len(self.radii)
        for i in range(len(self.radii)):
            if dist <= self.radii[i]:
                t = i
                break
        if prev >= 0 and prev < t and dist <= self.radii[prev] + self.hysteresis:
            return prev
        return t

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        var n = len(scene.bset.bodies)
        while len(self.last) < n:
            self.last.append(-1)
        var out = List[Int](length=n, fill=len(self.radii))
        for i in range(n):
            if scene.bset.is_removed(i):
                continue
            var d = _nearest_dist(scene.bset.bodies[i].position(), observers)
            out[i] = self.tier_for(d, self.last[i])
            self.last[i] = out[i]
        return out^


struct CausalReach(TierPolicy, Copyable):
    var seed_radius: Real
    var depths: List[Int]  # ascending: tier t covers graph depth <= depths[t]
    var reached: Int  # bodies reached by the last search (diagnostic)

    def __init__(out self, seed_radius: Real, var depths: List[Int]) raises:
        for i in range(1, len(depths)):
            if not (depths[i] > depths[i - 1]):
                raise Error("CausalReach: depths must be strictly ascending")
        self.seed_radius = seed_radius
        self.depths = depths^
        self.reached = 0

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        var n = len(scene.bset.bodies)
        # adjacency from last step's contacts and the joints (CSR)
        var deg = List[Int](length=n + 1, fill=0)
        for c in scene.cache:
            deg[c.a + 1] += 1
            deg[c.b + 1] += 1
        for j in scene.joints:
            deg[j.a + 1] += 1
            deg[j.b + 1] += 1
        for i in range(n):
            deg[i + 1] += deg[i]
        var fill = deg.copy()
        var adj = List[Int](length=deg[n], fill=-1)
        for c in scene.cache:
            adj[fill[c.a]] = c.b
            fill[c.a] += 1
            adj[fill[c.b]] = c.a
            fill[c.b] += 1
        for j in scene.joints:
            adj[fill[j.a]] = j.b
            fill[j.a] += 1
            adj[fill[j.b]] = j.a
            fill[j.b] += 1
        var depth = List[Int](length=n, fill=-1)
        var queue = List[Int]()
        var r2 = self.seed_radius * self.seed_radius
        for i in range(n):
            if scene.bset.is_removed(i) or not scene.bset.moves(i):
                continue
            for o in observers:
                var d = scene.bset.bodies[i].position() - o
                if dot(d, d) <= r2:
                    depth[i] = 0
                    queue.append(i)
                    break
        var head = 0
        while head < len(queue):
            var u = queue[head]
            head += 1
            for e in range(deg[u], deg[u + 1]):
                var v = adj[e]
                # static bodies conduct nothing: a shared floor would put the
                # whole level at depth 1
                if depth[v] >= 0 or not scene.bset.moves(v):
                    continue
                depth[v] = depth[u] + 1
                queue.append(v)
        self.reached = len(queue)
        var coarsest = len(self.depths)
        var out = List[Int](length=n, fill=coarsest)
        for i in range(n):
            if depth[i] < 0:
                continue
            for t in range(len(self.depths)):
                if depth[i] <= self.depths[t]:
                    out[i] = t
                    break
        return out^


struct RoundRobin(TierPolicy, Copyable):
    var tier: Int  # the tier (in the scene's table) whose period spreads the work

    def __init__(out self, tier: Int = 1):
        self.tier = tier

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        return List[Int](length=len(scene.bset.bodies), fill=self.tier)


struct BudgetTiers(TierPolicy, Copyable):
    var inner: DistanceTiers
    var base: List[Real]
    var target_ns: Int
    var shrink: Real
    var scale: Real
    var last_ns: Int

    def __init__(out self, var radii: List[Real], target_ns: Int, hysteresis: Real = 1.0, shrink: Real = 0.8) raises:
        if target_ns <= 0 or not (shrink > 0 and shrink < 1):
            raise Error("BudgetTiers: target_ns > 0 and 0 < shrink < 1")
        self.base = radii.copy()
        self.inner = DistanceTiers(radii^, hysteresis)
        self.target_ns = target_ns
        self.shrink = shrink
        self.scale = 1
        self.last_ns = 0

    def measured(mut self, ns: Int):
        """Feed the last step's cost: above 110 % of the target the radii
        shrink, below 70 % they grow back toward the configured values."""
        self.last_ns = ns
        if ns * 10 > self.target_ns * 11:
            self.scale *= self.shrink
        elif ns * 10 < self.target_ns * 7:
            self.scale = min(Real(1), self.scale / self.shrink)
        for i in range(len(self.base)):
            self.inner.radii[i] = self.base[i] * self.scale

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        return self.inner.assign(scene, observers, step)
