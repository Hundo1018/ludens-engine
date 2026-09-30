"""Kinematic capsule character controller (ROADMAP 17.1).

A character is not a rigid body: players expect it to stop dead against a
wall, walk up gentle slopes and small steps without bouncing, stay glued to
the ground over bumps, ride moving platforms, and never be launched by the
solver. The controller therefore moves a capsule by SWEEPING it through the
world (`collision.world_query` through `ContactScene6`'s wrappers) and never
enters the contact solver itself (the Unity CharacterController / Jolt
CharacterVirtual / Godot CharacterBody3D shape).

One `update(sc, walk_velocity, jump, dt, gravity)` does, in order:
1. gravity / jump on the vertical velocity (zeroed while grounded);
2. platform inheritance: while standing on a kinematic or dynamic body, add
   that body's surface velocity at the foot point;
3. move-and-slide: sweep along the remaining displacement, stop a skin short of
   the hit, remove the component into the surface, repeat (`max_slides`);
   a steep surface hit while grounded first tries a STEP: up by
   `step_height`, across, back down, accepted only if it lands on walkable
   ground;
4. depenetration: push out of anything still overlapped (spawned inside a
   wall, squeezed by a platform);
5. ground probe: a short downward sweep decides `on_ground` (normal within
   `max_slope`), the ground body, and snaps the capsule down onto it when
   walking over small drops so it does not go airborne on every bump;
6. ceiling: an upward hit zeroes upward velocity.
Dynamic bodies hit during the slide receive an impulse along the push
direction (`push_strength`), which is the controller's half of two-way
interaction; the other half (a body shoving the character) is step 4.

The capsule is vertical: centre `position`, segment half-length `half_height`,
radius `radius`; its bottom is `position.y - half_height - radius`.
"""

from std.math import sqrt, cos
from geometry.vec import Real, Vec3, dot, length
from collision.world_query import QueryFilter, Hit
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6

comptime _UP = Vec3(0, 1, 0, 0)
comptime _EPS: Real = 1e-6


@fieldwise_init
struct CharacterConfig(Copyable, ImplicitlyCopyable, Movable):
    var radius: Real
    var half_height: Real  # half of the segment between the hemisphere centres
    var max_slope_cos: Real  # cos(max walkable slope)
    var step_height: Real
    var skin: Real  # gap kept to surfaces
    var snap_distance: Real  # how far down the ground is followed
    var max_slides: Int
    var push_strength: Real  # fraction of the character speed handed to a pushed body
    var mask: UInt32

    @staticmethod
    def default() -> Self:
        return Self(0.3, 0.6, cos(Real(0.785398)), 0.3, 0.01, 0.25, 4, 1.0, 0xFFFFFFFF)


struct CharacterController(Copyable, Movable):
    var cfg: CharacterConfig
    var position: Vec3
    var velocity: Vec3
    var on_ground: Bool
    var ground_normal: Vec3
    var ground_body: Int
    var hit_ceiling: Bool
    var pushed: Int  # dynamic bodies pushed during the last update

    def __init__(out self, position: Vec3, cfg: CharacterConfig = CharacterConfig.default()):
        self.cfg = cfg
        self.position = position
        self.velocity = Vec3(0, 0, 0, 0)
        self.on_ground = False
        self.ground_normal = _UP
        self.ground_body = -1
        self.hit_ceiling = False
        self.pushed = 0

    # ---------------------------------------------------------------- shape

    def _seg(self, at: Vec3) -> Tuple[Vec3, Vec3]:
        var h = Vec3(0, self.cfg.half_height, 0, 0)
        return (at - h, at + h)

    def _filter(self) -> QueryFilter:
        return QueryFilter(self.cfg.mask, -1, False)

    def foot(self) -> Vec3:
        return self.position - Vec3(0, self.cfg.half_height + self.cfg.radius, 0, 0)

    def _walkable(self, n: Vec3) -> Bool:
        return n[1] >= self.cfg.max_slope_cos

    def _cast[B: Body6](self, sc: ContactScene6[B], at: Vec3, d: Vec3, dist: Real) -> Hit:
        var s = self._seg(at)
        return sc.capsule_cast(s[0], s[1], self.cfg.radius, d, dist, self._filter())

    def set_half_height[B: Body6](mut self, sc: ContactScene6[B], h: Real) -> Bool:
        """Crouch / stand: change the capsule height keeping the foot fixed.
        Growing is refused (returns False) when the taller capsule would
        overlap something -- standing up under a low ceiling."""
        var foot_y = self.position[1] - self.cfg.half_height - self.cfg.radius
        var c = Vec3(self.position[0], foot_y + h + self.cfg.radius, self.position[2], 0)
        if h > self.cfg.half_height:
            var s = Vec3(0, h, 0, 0)
            if len(sc.capsule_penetrations(c - s, c + s, self.cfg.radius - self.cfg.skin, self._filter())) > 0:
                return False
        self.cfg.half_height = h
        self.position = c
        return True

    # ---------------------------------------------------------------- steps

    def _push[B: Body6](mut self, mut sc: ContactScene6[B], h: Hit, blocked: Vec3, dt: Real):
        if h.body < 0 or not sc.bset.is_dynamic(h.body):
            return
        var im = sc.bset.bodies[h.body].inv_mass()
        if im <= 0:
            return
        # Velocity-level push: bring the body's speed along the push
        # direction up to the character's (times push_strength); an impulse
        # proportional to the blocked displacement is too small to beat
        # friction and the box never moves.
        var d = Vec3(-h.normal[0], 0, -h.normal[2], 0)
        var dl = length(d)
        if dl < _EPS:
            return
        d = d / dl
        var rel = dot(self.velocity, d) - dot(sc.bset.bodies[h.body].velocity_at(h.point), d)
        if rel <= 0:
            return
        sc.bset.bodies[h.body].apply_impulse(d * (rel * self.cfg.push_strength / im), h.point)
        try:
            sc.wake(sc.bset.id_of(h.body))
        except:
            pass
        self.pushed += 1

    def _slide[B: Body6](mut self, mut sc: ContactScene6[B], disp: Vec3, dt: Real, allow_step: Bool):
        var remaining = disp
        for _ in range(self.cfg.max_slides):
            var dist = length(remaining)
            if dist < _EPS:
                return
            var d = remaining / dist
            var h = self._cast(sc, self.position, d, dist + self.cfg.skin)
            if not h.hit:
                self.position += remaining
                return
            var travel = max(Real(0), h.t - self.cfg.skin)
            self.position += d * travel
            remaining -= d * travel
            var n = h.normal
            if n[1] < -0.5 and remaining[1] > 0:
                self.hit_ceiling = True
            # a steep wall while grounded and walking: try a step first
            if (
                allow_step
                and self.on_ground
                and not self._walkable(n)
                and n[1] > -0.5
                and (remaining[0] * remaining[0] + remaining[2] * remaining[2]) > _EPS
            ):
                if self._try_step(sc, remaining):
                    return
            self._push(sc, h, remaining, dt)
            var into = dot(remaining, n)
            if into < 0:
                remaining -= n * into
            # never let a steep slope lift the character: it slides, it does
            # not climb (walkable slopes keep their vertical component)
            if not self._walkable(n) and remaining[1] > 0 and n[1] > 0:
                remaining[1] = 0

    def _try_step[B: Body6](mut self, sc: ContactScene6[B], remaining: Vec3) -> Bool:
        var up = self._cast(sc, self.position, _UP, self.cfg.step_height)
        var rise = self.cfg.step_height if not up.hit else max(Real(0), up.t - self.cfg.skin)
        if rise < self.cfg.skin:
            return False
        var raised = self.position + _UP * rise
        var horiz = Vec3(remaining[0], 0, remaining[2], 0)
        var hl = length(horiz)
        var hd = horiz / hl
        var across = self._cast(sc, raised, hd, hl + self.cfg.skin)
        var moved = raised + hd * (hl if not across.hit else max(Real(0), across.t - self.cfg.skin))
        if across.hit and length(moved - raised) < _EPS:
            return False
        var down = self._cast(sc, moved, -_UP, rise + self.cfg.snap_distance)
        if not down.hit:
            return False
        var landed = moved - _UP * max(Real(0), down.t - self.cfg.skin)
        # Judge the step by the SUPPORTING SURFACE's height above the current
        # foot, not by how far the capsule rose: a rounded bottom resting on a
        # 0.5 m box's edge has risen less than 0.3 m, but the box is 0.5 m.
        var surf = self._surface(sc, down)
        var rise_to = surf[1] - self.foot()[1]
        if not self._walkable(surf[0]) or rise_to < self.cfg.skin:
            return False
        if rise_to > self.cfg.step_height + self.cfg.skin:
            return False
        self.position = landed
        return True

    def _depenetrate[B: Body6](mut self, sc: ContactScene6[B]):
        for _ in range(4):
            var s = self._seg(self.position)
            var pens = sc.capsule_penetrations(s[0], s[1], self.cfg.radius, self._filter())
            if len(pens) == 0:
                return
            var push = Vec3(0, 0, 0, 0)
            for k in range(len(pens)):
                push += pens[k].normal * (pens[k].depth + self.cfg.skin * 0.5)
            self.position += push

    def _surface[B: Body6](self, sc: ContactScene6[B], h: Hit) -> Tuple[Vec3, Real]:
        """Normal and height of the SURFACE under a hit, not of the contact.
        A rounded bottom resting on an edge reports the edge's diagonal
        normal and a contact point below the surface; a short ray down just
        past the edge, AWAY from the capsule axis (where the supporting
        surface continues), finds the top face and its height."""
        if self._walkable(h.normal):
            return (h.normal, h.point[1])
        var toward = Vec3(self.position[0] - h.point[0], 0, self.position[2] - h.point[2], 0)
        var tl = length(toward)
        if tl < _EPS:
            return (h.normal, h.point[1])
        var o = h.point - toward * (0.02 / tl) + _UP * 0.05
        var r = sc.ray_cast(o, -_UP, 0.1, self._filter())
        if r.hit and self._walkable(r.normal):
            return (r.normal, r.point[1])
        return (h.normal, h.point[1])

    def _probe_ground[B: Body6](mut self, sc: ContactScene6[B], snap: Bool):
        if self.velocity[1] > _EPS:
            # moving up (a jump): never grounded, or the jump is undone
            self.on_ground = False
            self.ground_normal = _UP
            self.ground_body = -1
            return
        var h = self._cast(sc, self.position, -_UP, self.cfg.snap_distance + self.cfg.skin * 2)
        var n = self._surface(sc, h)[0] if h.hit else _UP
        if h.hit and self._walkable(n):
            self.on_ground = True
            self.ground_normal = n
            self.ground_body = h.body
            if snap and h.t > self.cfg.skin:
                self.position -= _UP * (h.t - self.cfg.skin)
        else:
            self.on_ground = False
            self.ground_normal = _UP
            self.ground_body = -1

    # ---------------------------------------------------------------- update

    def update[B: Body6](
        mut self,
        mut sc: ContactScene6[B],
        walk: Vec3,
        jump_speed: Real,
        dt: Real,
        gravity: Vec3,
    ):
        """Advance the character by one step. `walk` is the desired horizontal
        velocity; `jump_speed > 0` jumps if grounded."""
        self.hit_ceiling = False
        self.pushed = 0
        var was_grounded = self.on_ground
        var vy = self.velocity[1]
        var jumped = False
        if was_grounded:
            vy = 0
            if jump_speed > 0:
                vy = jump_speed
                jumped = True
        else:
            vy += gravity[1] * dt
        self.velocity = Vec3(walk[0], vy, walk[2], 0)
        var disp = self.velocity * dt
        # ride what we stand on
        if was_grounded and self.ground_body >= 0 and self.ground_body < len(sc.bset.bodies):
            if sc.bset.moves(self.ground_body):
                disp += sc.bset.bodies[self.ground_body].velocity_at(self.foot()) * dt
        # walking along the ground: follow its slope instead of pushing into it
        if was_grounded and not jumped:
            var into = dot(disp, self.ground_normal)
            if into < 0:
                disp -= self.ground_normal * into
        self._slide(sc, disp, dt, was_grounded)
        self._depenetrate(sc)
        self._probe_ground(sc, was_grounded and not jumped)
        if self.hit_ceiling and self.velocity[1] > 0:
            self.velocity[1] = 0
        if self.on_ground and self.velocity[1] < 0:
            self.velocity[1] = 0

    def teleport(mut self, p: Vec3):
        self.position = p
        self.velocity = Vec3(0, 0, 0, 0)
        self.on_ground = False
        self.ground_body = -1
