"""Fixed-step ↔ render-rate state interpolation (ROADMAP 17.7).

The simulation advances in fixed ticks; frames arrive at their own rate. A
frame drawn between two ticks shows the pose `alpha` of the way from the
previous tick to the current one (`FixedLoop`/`Runtime.advance` return that
`alpha`). Drawing the latest tick instead makes motion stutter whenever the
frame rate does not divide the tick rate.

`PoseHistory` keeps the previous and current tick pose of every body slot;
`capture` shifts them each tick; `mark_teleport` makes the next capture copy
the new pose into both, so a teleported body appears at its destination
instead of smearing across the level for one frame.

The interpolator is a seam (`PoseInterpolator`), three variants:
- `LerpNlerp`: position lerp + quaternion nlerp (what most engines do);
- `DqNlerp`: dual-quaternion nlerp (couples rotation and translation);
- `MotorGeodesic`: the PGA motor geodesic -- constant-speed screw motion, the
  true interpolant of a rigid body spinning about an off-centre axis.
All three agree exactly at alpha = 0 and 1 and for pure translations; they
differ on screw motions, which is what the parity test and benchmark measure.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.dualquat import DualQuat
from geometry.galie import geodesic3


@fieldwise_init
struct PoseQT(Copyable, ImplicitlyCopyable, Movable):
    """A rigid pose as position + unit quaternion."""

    var p: Vec3
    var q: Quat

    def apply(self, v: Vec3) -> Vec3:
        return self.p + self.q.rotate(v)


@always_inline
def _qdot(a: Quat, b: Quat) -> Real:
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w


@always_inline
def _qneg(a: Quat) -> Quat:
    return Quat(-a.x, -a.y, -a.z, -a.w)


@always_inline
def _qmix(a: Quat, b: Quat, t: Real) -> Quat:
    var s = 1 - t
    return Quat(a.x * s + b.x * t, a.y * s + b.y * t, a.z * s + b.z * t, a.w * s + b.w * t)


trait PoseInterpolator:
    @staticmethod
    def blend(a: PoseQT, b: PoseQT, t: Real) -> PoseQT: ...


struct LerpNlerp(PoseInterpolator):
    @staticmethod
    def blend(a: PoseQT, b: PoseQT, t: Real) -> PoseQT:
        var bq = b.q if _qdot(a.q, b.q) >= 0 else _qneg(b.q)
        return PoseQT(a.p + (b.p - a.p) * t, _qmix(a.q, bq, t).normalized())


struct DqNlerp(PoseInterpolator):
    @staticmethod
    def blend(a: PoseQT, b: PoseQT, t: Real) -> PoseQT:
        var da = DualQuat.from_quat_translation(a.q, a.p)
        var db = DualQuat.from_quat_translation(b.q, b.p)
        if _qdot(da.real, db.real) < 0:
            db = DualQuat(_qneg(db.real), _qneg(db.dual))
        var r = _qmix(da.real, db.real, t)
        var d = _qmix(da.dual, db.dual, t)
        var n = sqrt(_qdot(r, r))
        var dq = DualQuat(
            Quat(r.x / n, r.y / n, r.z / n, r.w / n),
            Quat(d.x / n, d.y / n, d.z / n, d.w / n),
        )
        return PoseQT(dq.translation(), dq.real)


struct MotorGeodesic(PoseInterpolator):
    @staticmethod
    def blend(a: PoseQT, b: PoseQT, t: Real) -> PoseQT:
        var ma = Motor3.from_quat_translation(a.q, a.p)
        var mb = Motor3.from_quat_translation(b.q, b.p)
        var dq = DualQuat.from_motor(geodesic3(ma, mb, t))
        return PoseQT(dq.translation(), dq.real.normalized())


struct PoseHistory(Movable):
    var prev: List[PoseQT]
    var curr: List[PoseQT]
    var teleported: List[Bool]

    def __init__(out self):
        self.prev = List[PoseQT]()
        self.curr = List[PoseQT]()
        self.teleported = List[Bool]()

    def capture(mut self, poses: List[PoseQT]):
        """Called once per fixed tick with every slot's pose after the step.
        New slots start with prev == curr (no interpolation from nowhere)."""
        for i in range(len(poses)):
            if i >= len(self.curr):
                self.prev.append(poses[i])
                self.curr.append(poses[i])
                self.teleported.append(False)
                continue
            if self.teleported[i]:
                self.prev[i] = poses[i]
                self.teleported[i] = False
            else:
                self.prev[i] = self.curr[i]
            self.curr[i] = poses[i]

    def mark_teleport(mut self, i: Int):
        if i < len(self.teleported):
            self.teleported[i] = True

    def sample[I: PoseInterpolator](self, i: Int, alpha: Real, extrapolate: Bool = False) -> PoseQT:
        """The pose `alpha` of the way from the previous tick to the current.
        alpha is clamped to [0, 1] unless `extrapolate` (then alpha > 1 runs
        the same interpolant past the current tick)."""
        var t = alpha
        if not extrapolate:
            t = max(Real(0), min(Real(1), t))
        if t == 0:
            return self.prev[i]
        if t == 1:
            return self.curr[i]
        return I.blend(self.prev[i], self.curr[i], t)
