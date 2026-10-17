"""Ragdoll control on top of `Ragdoll` (ROADMAP 17.66): segment masses,
the mode state machine, balance assist with step recovery, grab / carry.

  * `segment_masses(total, halves)`: per-bone masses proportional to the
    bone box volumes (one density), summing to `total` -- `Ragdoll`'s
    `masses` argument instead of one mass per bone.
  * `RagdollModes`: ACTIVE (animation, strength 1) -> STUMBLE (a hit of at
    least `stumble_impulse`, or balance lost: strength `stumble_strength`
    for `stumble_time`, back to ACTIVE if balanced by then, else LIMP) ->
    LIMP (a hit of at least `fall_impulse`: strength 0) -> GETUP (after
    `rest_time` grounded below `rest_speed`: strength 1, the ragdoll blend
    weight going 1 -> 0 over `getup_time`, the get-up clip chosen face up /
    face down from the torso) -> ACTIVE. `update` returns the drive
    strength to set; `blend` is the weight for `blend_world`. Its state
    goes through `physics.state_io` (`write_state` / `read_state`).
  * `balance_assist`: centre of mass and velocity of the ragdoll's bodies,
    capture point (`gameplay.balance`); while the capture point is inside
    the support polygon a force on the root body steers the capture point
    toward the polygon centre, kp (centre - capture) - kd v, capped (at
    rest the capture point is the COM); when it is
    outside, the result asks for a step to the capture point
    (`need_step`, `step_to`): the caller moves a foot there, which is what
    restores balance after a push.
  * `grab(sc, hand, object, ...)`: a weld joint from a hand body to an
    object at their current relative pose, breakable above `break_force` /
    `break_torque` (`set_joint_break`, 17.29); `release` marks it
    `JOINT_BROKEN`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6, JOINT_BROKEN
from physics.body_set import BodyId
from physics.state_io import StateWriter, StateReader
from .balance import center_of_mass, capture_point, balance_margin
from .ragdoll import Ragdoll

comptime MODE_ACTIVE = 0
comptime MODE_STUMBLE = 1
comptime MODE_LIMP = 2
comptime MODE_GETUP = 3


def segment_masses(total: Real, halves: List[Vec3]) raises -> List[Real]:
    if not (total > 0):
        raise Error("segment_masses: total mass must be > 0")
    var vol = Real(0)
    for h in halves:
        vol += h[0] * h[1] * h[2]
    if not (vol > 0):
        raise Error("segment_masses: boxes have no volume")
    var out = List[Real]()
    for h in halves:
        out.append(total * h[0] * h[1] * h[2] / vol)
    return out^


struct RagdollModes(Movable):
    var mode: Int
    var timer: Real
    var blend: Real
    var face_up: Bool
    var stumble_impulse: Real
    var fall_impulse: Real
    var stumble_time: Real
    var stumble_strength: Real
    var rest_speed: Real
    var rest_time: Real
    var getup_time: Real

    def __init__(
        out self, stumble_impulse: Real = 30, fall_impulse: Real = 120, stumble_time: Real = 0.6,
        stumble_strength: Real = 0.3, rest_speed: Real = 0.2, rest_time: Real = 0.5, getup_time: Real = 0.8,
    ) raises:
        if not (stumble_impulse > 0 and fall_impulse >= stumble_impulse and stumble_time > 0 and rest_time > 0 and getup_time > 0):
            raise Error("RagdollModes: positive times, 0 < stumble_impulse <= fall_impulse")
        self.mode = MODE_ACTIVE
        self.timer = 0
        self.blend = 0
        self.face_up = True
        self.stumble_impulse = stumble_impulse
        self.fall_impulse = fall_impulse
        self.stumble_time = stumble_time
        self.stumble_strength = stumble_strength
        self.rest_speed = rest_speed
        self.rest_time = rest_time
        self.getup_time = getup_time

    def _enter(mut self, mode: Int):
        self.mode = mode
        self.timer = 0

    def on_hit(mut self, impulse: Real):
        """Register a hit of this impulse magnitude (N s)."""
        if impulse >= self.fall_impulse:
            self._enter(MODE_LIMP)
        elif impulse >= self.stumble_impulse and self.mode == MODE_ACTIVE:
            self._enter(MODE_STUMBLE)

    def update(mut self, dt: Real, root_speed: Real, grounded: Bool, balanced: Bool, torso_up: Real) -> Real:
        """Advance by dt; returns the drive strength. `torso_up` is the dot
        of the torso's front with world up (> 0: lying face up)."""
        self.timer += dt
        if self.mode == MODE_ACTIVE:
            if not balanced:
                self._enter(MODE_STUMBLE)
            else:
                self.blend = 0
                return 1
        if self.mode == MODE_STUMBLE:
            self.blend = 0
            if self.timer >= self.stumble_time:
                self._enter(MODE_ACTIVE if balanced else MODE_LIMP)
                return Real(1) if self.mode == MODE_ACTIVE else Real(0)
            return self.stumble_strength
        if self.mode == MODE_LIMP:
            self.blend = 1
            if not (grounded and root_speed < self.rest_speed):
                self.timer = 0
            elif self.timer >= self.rest_time:
                self.face_up = torso_up > 0
                self._enter(MODE_GETUP)
                return 1
            return 0
        # GETUP
        self.blend = max(Real(0), 1 - self.timer / self.getup_time)
        if self.timer >= self.getup_time:
            self._enter(MODE_ACTIVE)
            self.blend = 0
        return 1

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(self.mode)
        w.wf(self.timer)
        w.wf(self.blend)
        w.wi(1 if self.face_up else 0)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.mode = r.ri()
        self.timer = r.rf()
        self.blend = r.rf()
        self.face_up = r.ri() == 1


@fieldwise_init
struct BalanceResult(Copyable, ImplicitlyCopyable, Movable):
    var com: Vec3
    var capture: Vec3
    var margin: Real  # capture point to the polygon edge (> 0 inside)
    var need_step: Bool
    var step_to: Vec3
    var force: Vec3  # applied to the root body


def balance_assist(
    mut sc: ContactScene6[QuatBody6], rd: Ragdoll, support: List[Vec3], ground_y: Real, g: Real,
    kp: Real, kd: Real, max_force: Real,
) raises -> BalanceResult:
    """See the module note. `support` is the support polygon (x, z of
    each point used; counter-clockwise, `gameplay.balance.support_polygon`)."""
    if len(support) < 3:
        raise Error("balance_assist: support polygon needs >= 3 points")
    var cv = center_of_mass(sc, rd.ids)
    var com = cv[0]
    var vel = cv[1]
    var cp = capture_point(com, vel, ground_y, g)
    var m = balance_margin(support, cp)
    if m < 0:
        return BalanceResult(com, cp, m, True, Vec3(cp[0], ground_y, cp[2], 0), Vec3(0, 0, 0, 0))
    var cx = Real(0)
    var cz = Real(0)
    for p in support:
        cx += p[0]
        cz += p[2]
    cx /= Real(len(support))
    cz /= Real(len(support))
    # capture-point control: steer the capture point (not the COM) to the
    # centre. Pulling the COM there instead accelerated a body that had
    # just stepped (the new centre is ahead of it) and ran away (9 m/s).
    var f = Vec3(kp * (cx - cp[0]) - kd * vel[0], 0, kp * (cz - cp[2]) - kd * vel[2], 0)
    var fl = sqrt(f[0] * f[0] + f[2] * f[2])
    if fl > max_force:
        f = f * (max_force / fl)
    var root = 0
    for b in range(len(rd.parent)):
        if rd.parent[b] < 0:
            root = b
    sc.add_force(rd.ids[root], f)
    return BalanceResult(com, cp, m, False, Vec3(0, 0, 0, 0), f)


def grab(mut sc: ContactScene6[QuatBody6], hand: BodyId, obj: BodyId, break_force: Real, break_torque: Real) raises -> Int:
    """Weld `obj` to `hand` where they are now; returns the joint index."""
    ref hb = sc.bset.bodies[hand.index()]
    ref ob = sc.bset.bodies[obj.index()]
    var at = ob.position()
    var rel = hb.rotation().conjugate() * ob.rotation()
    var j = sc.add_joint(Joint6.weld(hand.index(), obj.index(), hb.to_local(at), ob.to_local(at), rel))
    sc.set_joint_break(j, break_force, break_torque)
    return j


def release(mut sc: ContactScene6[QuatBody6], joint: Int) raises:
    """Let go: the weld becomes `JOINT_BROKEN` (never solved again), as a
    joint that broke under load does."""
    if joint < 0 or joint >= len(sc.joints):
        raise Error("release: joint index out of range")
    var jt = sc.joints[joint]
    jt.kind = JOINT_BROKEN
    sc.joints[joint] = jt
