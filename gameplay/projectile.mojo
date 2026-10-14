"""Ballistic projectiles (ROADMAP 17.71).

A fixed-capacity `ProjectileSet` (the pool: spawning when full drops the new
projectile and counts it in `dropped`, the hot-path row of
`docs/ARCHITECTURE.md` §2). Each step moves every live projectile under
gravity and drag and casts a ray along the segment it travelled, so a fast
round cannot skip a thin wall between ticks (no CCD needed). A hit stops
the projectile, is reported, and optionally hands `mass x velocity` to the
body as an impulse at the hit point.

Drag: DRAG_LINEAR (acceleration -k v) is integrated exactly per step (the
closed form, so the landing point matches the analytic trajectory for any
dt); DRAG_QUADRATIC (-k |v| v) has no closed form with gravity and uses one
RK4 step per tick.
"""

from std.math import exp, sqrt, isfinite
from geometry.vec import Real, Vec3, dot, length
from collision.world_query import QueryFilter
from collision.broadphase import BroadPhase
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6

comptime DRAG_LINEAR = 0
comptime DRAG_QUADRATIC = 1


@fieldwise_init
struct ProjectileHit(Copyable, ImplicitlyCopyable, Movable):
    var projectile: Int
    var body: Int
    var point: Vec3
    var normal: Vec3
    var velocity: Vec3


struct ProjectileSet(Movable):
    var pos: List[Vec3]
    var vel: List[Vec3]
    var alive: List[Bool]
    var capacity: Int
    var drag_kind: Int
    var k: Real
    var mass: Real
    var dropped: Int
    var filter: QueryFilter

    def __init__(out self, capacity: Int, drag_kind: Int = DRAG_LINEAR, k: Real = 0, mass: Real = 0) raises:
        if capacity < 1:
            raise Error("ProjectileSet: capacity must be >= 1")
        self.pos = List[Vec3]()
        self.vel = List[Vec3]()
        self.alive = List[Bool]()
        self.capacity = capacity
        self.drag_kind = drag_kind
        self.k = k
        self.mass = mass
        self.dropped = 0
        self.filter = QueryFilter.all()

    def live(self) -> Int:
        var n = 0
        for a in self.alive:
            if a:
                n += 1
        return n

    def spawn(mut self, p: Vec3, v: Vec3) -> Int:
        """Index of the new projectile, or -1 (counted in `dropped`) when the
        pool is full or the input is not finite."""
        if not (isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2]) and isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])):
            self.dropped += 1
            return -1
        for i in range(len(self.alive)):
            if not self.alive[i]:
                self.pos[i] = p
                self.vel[i] = v
                self.alive[i] = True
                return i
        if len(self.alive) >= self.capacity:
            self.dropped += 1
            return -1
        self.pos.append(p)
        self.vel.append(v)
        self.alive.append(True)
        return len(self.alive) - 1

    def _acc(self, v: Vec3, g: Vec3) -> Vec3:
        return g - v * (self.k * length(v))

    def advance_state(self, p: Vec3, v: Vec3, g: Vec3, dt: Real) -> Tuple[Vec3, Vec3]:
        """One step of free flight (no collision)."""
        if self.k <= 0:
            return (p + v * dt + g * (0.5 * dt * dt), v + g * dt)
        if self.drag_kind == DRAG_LINEAR:
            var e = exp(-self.k * dt)
            var vt = g / self.k  # terminal velocity
            return (p + (v - vt) * ((1 - e) / self.k) + vt * dt, (v - vt) * e + vt)
        var k1v = self._acc(v, g)
        var k1x = v
        var k2v = self._acc(v + k1v * (dt / 2), g)
        var k2x = v + k1v * (dt / 2)
        var k3v = self._acc(v + k2v * (dt / 2), g)
        var k3x = v + k2v * (dt / 2)
        var k4v = self._acc(v + k3v * dt, g)
        var k4x = v + k3v * dt
        return (p + (k1x + k2x * 2 + k3x * 2 + k4x) * (dt / 6), v + (k1v + k2v * 2 + k3v * 2 + k4v) * (dt / 6))

    def step[B: Body6, BP: BroadPhase](mut self, mut sc: ContactScene6[B, BP], dt: Real, gravity: Vec3, push: Bool = False) raises -> List[ProjectileHit]:
        var hits = List[ProjectileHit]()
        for i in range(len(self.alive)):
            if not self.alive[i]:
                continue
            var nx = self.advance_state(self.pos[i], self.vel[i], gravity, dt)
            var seg = nx[0] - self.pos[i]
            var l = length(seg)
            if l > 0:
                var h = sc.ray_cast(self.pos[i], seg / l, l, self.filter)
                if h.hit:
                    var at = self.pos[i] + seg * (h.t / l)
                    hits.append(ProjectileHit(i, h.body, at, h.normal, self.vel[i]))
                    if push and self.mass > 0 and h.body >= 0 and sc.bset.is_dynamic(h.body):
                        sc.apply_impulse(sc.bset.id_of(h.body), self.vel[i] * self.mass, at)
                    self.alive[i] = False
                    continue
            self.pos[i] = nx[0]
            self.vel[i] = nx[1]
        return hits^
