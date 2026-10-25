"""Inertialized transitions (ROADMAP 17.64; Bollinger, GDC 2018).

A cross-fade samples both the outgoing and the incoming clip for the whole
transition and blends them. Inertialization samples only the incoming one:
at the switch it stores the difference between the pose being shown and the
new clip's pose (a translation offset and a rotation offset per bone), and
then adds that difference back, decaying it to zero over `duration`:

    pos = target_pos + offset_p * k(u),   rot = slerp(1, offset_q, k(u)) * target_rot

with u = elapsed / duration and k(u) = 1 - (10 u^3 - 15 u^4 + 6 u^5) (a quintic
with zero slope at both ends). At u = 0 the output is the old pose (to
rounding); from u >= 1 on it is the target pose exactly (the offset is not
applied at all).
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat, slerp
from geometry.motor import Motor3
from geometry.galie import exp_screw3, log_motor3

comptime INERT_SPLIT = 0
"""Offset as a translation plus a rotation, decayed separately (default)."""
comptime INERT_MOTOR = 1
"""Offset as one rigid motion (motor), decayed along its screw: a bone
rotated about a pivot away from its origin swings back on the arc around
that pivot instead of cutting the chord."""


def _decay(u: Real) -> Real:
    if u <= 0:
        return 1
    if u >= 1:
        return 0
    return 1 - u * u * u * (10 - 15 * u + 6 * u * u)


struct Inertializer(Copyable, Movable):
    var bones: Int
    var off_p: List[Real]  # 3 per bone
    var off_q: List[Real]  # 4 per bone (x, y, z, w)
    var elapsed: Real
    var duration: Real
    var active: Bool
    var space: Int  # INERT_SPLIT / INERT_MOTOR
    var off_m: List[Motor3]  # per bone (INERT_MOTOR)

    def __init__(out self, bones: Int, space: Int = INERT_SPLIT):
        self.bones = bones
        self.off_p = List[Real](length=3 * bones, fill=0)
        self.off_q = List[Real](length=4 * bones, fill=0)
        self.elapsed = 0
        self.duration = 0
        self.active = False
        self.space = space
        self.off_m = List[Motor3](length=bones, fill=Motor3.from_translation(Vec3(0, 0, 0, 0)))

    def start(mut self, src_pos: List[Real], src_rot: List[Real], dst_pos: List[Real], dst_rot: List[Real], duration: Real):
        """Record the offset from the pose being shown (src) to the new
        target's pose (dst) at the switch."""
        if duration <= 0:
            self.active = False
            return
        for b in range(self.bones):
            for k in range(3):
                self.off_p[3 * b + k] = src_pos[3 * b + k] - dst_pos[3 * b + k]
            var qs = Quat(src_rot[4 * b], src_rot[4 * b + 1], src_rot[4 * b + 2], src_rot[4 * b + 3])
            var qd = Quat(dst_rot[4 * b], dst_rot[4 * b + 1], dst_rot[4 * b + 2], dst_rot[4 * b + 3])
            var off = (qs * qd.conjugate()).normalized()
            if off.w < 0:  # shortest way round
                off = Quat(-off.x, -off.y, -off.z, -off.w)
            self.off_q[4 * b] = off.x
            self.off_q[4 * b + 1] = off.y
            self.off_q[4 * b + 2] = off.z
            self.off_q[4 * b + 3] = off.w
            if self.space == INERT_MOTOR:
                var ms = Motor3.from_quat_translation(qs, Vec3(src_pos[3 * b], src_pos[3 * b + 1], src_pos[3 * b + 2], 0))
                var md = Motor3.from_quat_translation(qd, Vec3(dst_pos[3 * b], dst_pos[3 * b + 1], dst_pos[3 * b + 2], 0))
                self.off_m[b] = (ms * md.reverse()).normalized()
        self.elapsed = 0
        self.duration = duration
        self.active = True

    def advance(mut self, dt: Real):
        if self.active:
            self.elapsed += dt
            if self.elapsed >= self.duration:
                self.active = False

    def apply(self, mut pos: List[Real], mut rot: List[Real]):
        """Add the decayed offset to the target pose in place (no-op once
        the transition is over)."""
        if not self.active:
            return
        var k = _decay(self.elapsed / self.duration)
        if k <= 0:
            return
        if self.space == INERT_MOTOR:
            for b in range(self.bones):
                var q = Quat(rot[4 * b], rot[4 * b + 1], rot[4 * b + 2], rot[4 * b + 3])
                var md = Motor3.from_quat_translation(q, Vec3(pos[3 * b], pos[3 * b + 1], pos[3 * b + 2], 0))
                var m = (exp_screw3(log_motor3(self.off_m[b]).scaled(k)) * md).normalized()
                var qt = m.to_quat_translation()
                var r = qt[0]
                if r.x * q.x + r.y * q.y + r.z * q.z + r.w * q.w < 0:  # keep the target's hemisphere
                    r = Quat(-r.x, -r.y, -r.z, -r.w)
                pos[3 * b] = qt[1][0]
                pos[3 * b + 1] = qt[1][1]
                pos[3 * b + 2] = qt[1][2]
                rot[4 * b] = r.x
                rot[4 * b + 1] = r.y
                rot[4 * b + 2] = r.z
                rot[4 * b + 3] = r.w
            return
        var one = Quat(0, 0, 0, 1)
        for b in range(self.bones):
            for c in range(3):
                pos[3 * b + c] += self.off_p[3 * b + c] * k
            var off = Quat(self.off_q[4 * b], self.off_q[4 * b + 1], self.off_q[4 * b + 2], self.off_q[4 * b + 3])
            var q = Quat(rot[4 * b], rot[4 * b + 1], rot[4 * b + 2], rot[4 * b + 3])
            var r = (slerp(one, off, k) * q).normalized()
            rot[4 * b] = r.x
            rot[4 * b + 1] = r.y
            rot[4 * b + 2] = r.z
            rot[4 * b + 3] = r.w
