"""Movement modes and velocity models for the kinematic character
(ROADMAP 17.67).

`CharacterController.update` takes a desired horizontal velocity and sets
it directly; it has one mode (walking / airborne), no jump feel and no
external velocity. `Mover` wraps it:

  * modes: WALK, FALL, SWIM, FLY. Swimming starts when more than
    `swim_enter` of the capsule's height is under a `WaterVolume` surface
    and stops below `swim_exit` (the gap is the hysteresis that stops a
    character bobbing at the surface from flickering between modes); in the
    water gravity is scaled by `1 - buoyancy`, vertical wish moves the
    swimmer and `water_drag` damps it. FLY ignores gravity.
  * velocity models (a seam, `MoveConfig.model`): MODEL_DIRECT sets the
    wish velocity (the controller's old behaviour); MODEL_ACCEL moves toward
    it at `accel` (`decel` when there is no wish; times `air_control` in the
    air); MODEL_QUAKE is Quake's PM_Friction + PM_Accelerate (friction on
    the ground, then add speed along the wish direction up to the wish
    speed). On flat ground all three settle at the wish speed.
  * jump feel, counted in ticks so it replays exactly: coyote time (a jump
    pressed up to `coyote_ticks` after leaving the ground still jumps), a
    jump buffer (a press up to `buffer_ticks` before landing jumps on
    landing), variable height (releasing while rising multiplies the
    upward speed by `jump_cut` once), and `max_jumps` (2 = double jump).
  * external velocity (`add_velocity`): knockback, jump pads, wind; added
    to the move each tick and decaying at `ext_decay` per second, never
    overwritten by walking.
  * moving platforms: the controller already carries the position; `heading`
    (yaw, radians) now also turns with the platform's angular velocity.

`Mover` is a value type (copy = snapshot) and uses no wall clock.
"""

from std.math import sqrt, isfinite, exp
from geometry.vec import Real, Vec3, dot, length
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from .character import CharacterController

comptime MODE_WALK = 0
comptime MODE_FALL = 1
comptime MODE_SWIM = 2
comptime MODE_FLY = 3

comptime MODEL_DIRECT = 0
comptime MODEL_ACCEL = 1
comptime MODEL_QUAKE = 2


@fieldwise_init
struct MoveConfig(Copyable, ImplicitlyCopyable, Movable):
    var model: Int
    var accel: Real  # m/s^2 (MODEL_ACCEL); 1/s x wish speed (MODEL_QUAKE)
    var decel: Real  # m/s^2 braking with no wish (MODEL_ACCEL)
    var friction: Real  # 1/s ground friction (MODEL_QUAKE)
    var air_control: Real  # fraction of accel in the air
    var jump_speed: Real
    var jump_cut: Real  # upward speed kept when jump is released while rising
    var coyote_ticks: Int
    var buffer_ticks: Int
    var max_jumps: Int
    var swim_enter: Real
    var swim_exit: Real
    var buoyancy: Real  # fraction of gravity cancelled in the water
    var water_drag: Real  # 1/s on vertical speed in the water
    var ext_decay: Real  # 1/s

    @staticmethod
    def default() -> Self:
        return Self(MODEL_DIRECT, 20, 20, 6, 0.3, 5, 0.5, 6, 6, 1, 0.6, 0.4, 0.95, 2, 3)


def _toward(v: Vec3, target: Vec3, step: Real) -> Vec3:
    var d = target - v
    var l = length(d)
    if l <= step or l == 0:
        return target
    return v + d * (step / l)


def _flat(v: Vec3) -> Vec3:
    return Vec3(v[0], 0, v[2], 0)


struct Mover(Copyable, Movable):
    var cc: CharacterController
    var cfg: MoveConfig
    var mode: Int
    var vel: Vec3  # horizontal model velocity
    var ext: Vec3  # external velocity, decaying
    var air_ticks: Int  # ticks since last on the ground
    var press_ticks: Int  # ticks since jump was last pressed (large = none pending)
    var jumps: Int  # jumps used since last grounded
    var rising_jump: Bool  # a jump is rising and has not been cut yet
    var heading: Real
    var mode_changes: Int

    def __init__(out self, var cc: CharacterController, cfg: MoveConfig = MoveConfig.default()):
        self.cc = cc^
        self.cfg = cfg
        self.mode = MODE_FALL
        self.vel = Vec3(0, 0, 0, 0)
        self.ext = Vec3(0, 0, 0, 0)
        self.air_ticks = 1 << 30
        self.press_ticks = 1 << 30
        self.jumps = 0
        self.rising_jump = False
        self.heading = 0
        self.mode_changes = 0

    def add_velocity(mut self, dv: Vec3):
        if isfinite(dv[0]) and isfinite(dv[1]) and isfinite(dv[2]):
            self.ext = self.ext + dv

    def _set_mode(mut self, m: Int):
        if m != self.mode:
            self.mode = m
            self.mode_changes += 1

    def _submerged(self, waters: List[WaterVolume]) -> Real:
        var foot = self.cc.foot()[1]
        var height = 2 * (self.cc.cfg.half_height + self.cc.cfg.radius)
        var p = self.cc.position
        var best = Real(0)
        for w in waters:
            if p[0] < w.lo[0] or p[0] > w.hi[0] or p[2] < w.lo[2] or p[2] > w.hi[2] or foot > w.hi[1]:
                continue
            best = max(best, min(max((w.hi[1] - foot) / height, Real(0)), Real(1)))
        return best

    def _model(mut self, wish: Vec3, grounded: Bool, dt: Real):
        var w = _flat(wish)
        if self.cfg.model == MODEL_DIRECT:
            self.vel = w
            return
        var ctrl = Real(1) if grounded else self.cfg.air_control
        if self.cfg.model == MODEL_ACCEL:
            if length(w) > 0:
                self.vel = _toward(self.vel, w, self.cfg.accel * ctrl * dt)
            elif grounded:
                self.vel = _toward(self.vel, Vec3(0, 0, 0, 0), self.cfg.decel * dt)
            return
        # MODEL_QUAKE: friction, then accelerate along the wish direction
        if grounded:
            var sp = length(self.vel)
            if sp > 0:
                var drop = sp * self.cfg.friction * dt
                self.vel = self.vel * (max(sp - drop, Real(0)) / sp)
        var ws = length(w)
        if ws > 0:
            var dir = w / ws
            var add = ws - dot(self.vel, dir)
            if add > 0:
                self.vel = self.vel + dir * min(self.cfg.accel * ctrl * dt * ws, add)

    def update[B: Body6](
        mut self, mut sc: ContactScene6[B], wish_in: Vec3, jump_pressed: Bool, jump_held: Bool,
        dt: Real, gravity: Vec3, waters: List[WaterVolume],
    ):
        """One tick. `wish_in` is the desired velocity (horizontal; its y is
        used only when swimming or flying); non-finite input counts as no
        wish. `dt = 0` changes nothing."""
        if not (dt > 0):
            return
        var wish = wish_in
        if not (isfinite(wish[0]) and isfinite(wish[1]) and isfinite(wish[2])):
            wish = Vec3(0, 0, 0, 0)
        var grounded = self.cc.on_ground
        # mode
        var sub = self._submerged(waters)
        if self.mode == MODE_FLY:
            pass
        elif self.mode == MODE_SWIM:
            if sub < self.cfg.swim_exit:
                self._set_mode(MODE_WALK if grounded else MODE_FALL)
        elif sub > self.cfg.swim_enter:
            self._set_mode(MODE_SWIM)
        else:
            self._set_mode(MODE_WALK if grounded else MODE_FALL)
        # jump bookkeeping (ticks)
        if grounded:
            self.air_ticks = 0
            self.jumps = 0
        else:
            self.air_ticks += 1
        if jump_pressed:
            self.press_ticks = 0
        else:
            self.press_ticks += 1
        # horizontal model
        self._model(wish, grounded, dt)
        var walk = self.vel + _flat(self.ext)
        var g = gravity
        var jump = Real(0)
        if self.mode == MODE_SWIM:
            g = gravity * (1 - self.cfg.buoyancy)
            var vy = self.cc.velocity[1] * exp(-self.cfg.water_drag * dt) + wish[1] * (1 - exp(-self.cfg.water_drag * dt))
            self.cc.velocity[1] = vy
            self.rising_jump = False
        elif self.mode == MODE_FLY:
            g = Vec3(0, 0, 0, 0)
            self.cc.velocity[1] = wish[1]
            if grounded and wish[1] > 0:
                jump = wish[1]
        else:
            var ground_ok = grounded or self.air_ticks <= self.cfg.coyote_ticks
            var pending = self.press_ticks <= self.cfg.buffer_ticks
            var fire = False
            if pending and self.jumps == 0 and ground_ok:
                self.jumps = 1  # from the ground, or within coyote time
                fire = True
            elif jump_pressed and (self.jumps >= 1 or not ground_ok) and max(self.jumps, 1) < self.cfg.max_jumps:
                self.jumps = max(self.jumps, 1) + 1  # an air jump needs a fresh press
                fire = True
            if fire:
                self.press_ticks = 1 << 30
                self.rising_jump = True
                if grounded:
                    jump = self.cfg.jump_speed
                else:
                    self.cc.velocity[1] = self.cfg.jump_speed
            elif self.rising_jump and not jump_held and self.cc.velocity[1] > 0:
                self.cc.velocity[1] *= self.cfg.jump_cut
                self.rising_jump = False
        # external vertical velocity
        if self.ext[1] != 0:
            if grounded and self.ext[1] > 0 and jump == 0:
                jump = self.ext[1]
            elif not grounded:
                self.cc.velocity[1] += self.ext[1] * dt * self.cfg.ext_decay
        var gb = self.cc.ground_body
        self.cc.update(sc, walk, jump, dt, g)
        if grounded and gb >= 0 and gb < len(sc.bset.bodies) and sc.bset.moves(gb):
            self.heading += sc.bset.bodies[gb].omega_world()[1] * dt
        if self.cc.velocity[1] <= 0:
            self.rising_jump = False
        self.ext = self.ext * exp(-self.cfg.ext_decay * dt)
