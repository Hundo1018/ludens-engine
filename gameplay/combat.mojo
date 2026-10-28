"""Hit and hurt volumes, melee sweeps, hitscan, hit-stop (ROADMAP 17.71).

A `Hurtbox` is a capsule on one bone of one owner (team, body-part damage
multiplier); the caller updates its segment from the animated pose each
tick. A `Swing` is a weapon blade (a capsule along local +x from `base` to
`tip`, of radius `radius`) held at a pivot pose; `Swing.step(pivot, rot)`
moves it to the new pose and reports the hurtboxes it touched on the way,
**each owner at most once per swing** (dedup set, cleared by `begin`).

Detection is a seam (`DETECT_*`):

  * DISCRETE: overlap at the new pose only;
  * LINEAR: the blade's two end points move on straight lines between the
    old and new pose, sampled so no point moves more than `max_step`;
  * ARC: the pivot moves on a straight line and the rotation along the
    shortest arc (slerp), same sampling -- the blade sweeps the real arc of a
    swing instead of its chord.

When the blade moves less than a target's thickness per tick all three
report the same hits; a fast swing can pass through a thin shield between
two discrete poses, and the chord of a wide arc cuts inside it
(`test_combat` measures both).

`hitscan` casts a ray against the hurtboxes (team-filtered) and returns the
nearest. `HitStop` holds per-owner freeze counters in ticks.
"""

from std.math import sqrt, acos
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat, slerp

comptime DETECT_DISCRETE = 0
comptime DETECT_LINEAR = 1
comptime DETECT_ARC = 2


@fieldwise_init
struct Hurtbox(Copyable, ImplicitlyCopyable, Movable):
    var owner: Int
    var bone: Int
    var team: Int
    var mult: Real  # body-part damage multiplier
    var a: Vec3
    var b: Vec3
    var r: Real


@fieldwise_init
struct HitResult(Copyable, ImplicitlyCopyable, Movable):
    var hurtbox: Int
    var owner: Int
    var bone: Int
    var point: Vec3
    var normal: Vec3  # from the hurtbox surface toward the weapon
    var dir: Vec3  # weapon motion direction at the hit (unit, or zero)
    var mult: Real


def closest_segments(p1: Vec3, q1: Vec3, p2: Vec3, q2: Vec3) -> Tuple[Vec3, Vec3]:
    """Closest points of segments p1-q1 and p2-q2 (Ericson, Real-Time
    Collision Detection 5.1.9)."""
    var d1 = q1 - p1
    var d2 = q2 - p2
    var r = p1 - p2
    var a = dot(d1, d1)
    var e = dot(d2, d2)
    var f = dot(d2, r)
    var s = Real(0)
    var t = Real(0)
    if a <= 1e-12 and e <= 1e-12:
        return (p1, p2)
    if a <= 1e-12:
        t = min(max(f / e, Real(0)), Real(1))
    else:
        var c = dot(d1, r)
        if e <= 1e-12:
            s = min(max(-c / a, Real(0)), Real(1))
        else:
            var b = dot(d1, d2)
            var den = a * e - b * b
            if den != 0:
                s = min(max((b * f - c * e) / den, Real(0)), Real(1))
            t = (b * s + f) / e
            if t < 0:
                t = 0
                s = min(max(-c / a, Real(0)), Real(1))
            elif t > 1:
                t = 1
                s = min(max((b - c) / a, Real(0)), Real(1))
    return (p1 + d1 * s, p2 + d2 * t)


struct Swing(Copyable, Movable):
    var team: Int
    var base: Real
    var tip: Real
    var radius: Real
    var mode: Int
    var max_step: Real
    var pivot: Vec3
    var rot: Quat
    var hit_owners: List[Int]
    var samples: Int  # blade poses tested in the last step (cost)

    def __init__(out self, team: Int, base: Real, tip: Real, radius: Real, mode: Int = DETECT_ARC, max_step: Real = 0.01):
        self.team = team
        self.base = base
        self.tip = tip
        self.radius = radius
        self.mode = mode
        self.max_step = max_step
        self.pivot = Vec3(0, 0, 0, 0)
        self.rot = Quat(0, 0, 0, 1)
        self.hit_owners = List[Int]()
        self.samples = 0

    def begin(mut self, pivot: Vec3, rot: Quat):
        """Start a swing at this pose (clears the per-swing dedup set)."""
        self.pivot = pivot
        self.rot = rot
        self.hit_owners = List[Int]()

    def blade(self, pivot: Vec3, rot: Quat) -> Tuple[Vec3, Vec3]:
        return (pivot + rot.rotate(Vec3(self.base, 0, 0, 0)), pivot + rot.rotate(Vec3(self.tip, 0, 0, 0)))

    def _test(mut self, a: Vec3, b: Vec3, motion: Vec3, boxes: List[Hurtbox], mut out: List[HitResult]):
        for k in range(len(boxes)):
            ref h = boxes[k]
            if h.team == self.team:
                continue
            var seen = False
            for o in self.hit_owners:
                if o == h.owner:
                    seen = True
                    break
            if seen:
                continue
            var cp = closest_segments(a, b, h.a, h.b)
            var d = cp[0] - cp[1]
            var l = length(d)
            if l <= self.radius + h.r:
                var n = d / l if l > 0 else Vec3(0, 1, 0, 0)
                var ml = length(motion)
                out.append(HitResult(k, h.owner, h.bone, cp[1] + n * h.r, n, motion / ml if ml > 0 else Vec3(0, 0, 0, 0), h.mult))
                self.hit_owners.append(h.owner)

    def step(mut self, pivot: Vec3, rot: Quat, boxes: List[Hurtbox]) -> List[HitResult]:
        var out = List[HitResult]()
        var e0 = self.blade(self.pivot, self.rot)
        var e1 = self.blade(pivot, rot)
        var motion = e1[1] - e0[1]
        var n = 1
        if self.mode != DETECT_DISCRETE:
            var move = max(length(e1[0] - e0[0]), length(e1[1] - e0[1]))
            if self.mode == DETECT_ARC:
                # the arc is longer than the chord: bound it by angle x reach
                var q0 = self.rot
                var c = abs(q0.x * rot.x + q0.y * rot.y + q0.z * rot.z + q0.w * rot.w)
                var ang = 2 * acos(min(c, Real(1)))
                move = max(move, ang * max(abs(self.tip), abs(self.base)) + length(pivot - self.pivot))
            n = max(1, Int(move / self.max_step) + 1)
        self.samples = n
        for i in range(1, n + 1):
            var u = Real(i) / Real(n)
            var a: Vec3
            var b: Vec3
            match self.mode:
                case == DETECT_ARC:
                    var e = self.blade(self.pivot + (pivot - self.pivot) * u, slerp(self.rot, rot, u).normalized())
                    a = e[0]
                    b = e[1]
                case == DETECT_LINEAR:
                    a = e0[0] + (e1[0] - e0[0]) * u
                    b = e0[1] + (e1[1] - e0[1]) * u
                case _:
                    a = e1[0]
                    b = e1[1]
            self._test(a, b, motion, boxes, out)
        self.pivot = pivot
        self.rot = rot
        return out^


def hitscan(origin: Vec3, dir_in: Vec3, max_t: Real, boxes: List[Hurtbox], team: Int) -> Tuple[Int, Real]:
    """Nearest hurtbox (not of `team`) along the ray, as (index, t); (-1, max_t)
    if none. Exact ray-capsule: the cylinder side and both end spheres."""
    var l = length(dir_in)
    if l == 0:
        return (-1, max_t)
    var d = dir_in / l
    var best = -1
    var bt = max_t
    for k in range(len(boxes)):
        ref h = boxes[k]
        if h.team == team:
            continue
        var t = _ray_capsule(origin, d, h.a, h.b, h.r)
        if t >= 0 and t < bt:
            bt = t
            best = k
    return (best, bt)


def _ray_sphere(o: Vec3, d: Vec3, c: Vec3, r: Real) -> Real:
    var m = o - c
    var b = dot(m, d)
    var cc = dot(m, m) - r * r
    if cc > 0 and b > 0:
        return -1
    var disc = b * b - cc
    if disc < 0:
        return -1
    var t = -b - sqrt(disc)
    return max(t, Real(0))


def _ray_capsule(o: Vec3, d: Vec3, a: Vec3, b: Vec3, r: Real) -> Real:
    var best = Real(-1)
    for c in [a, b]:
        var t = _ray_sphere(o, d, c, r)
        if t >= 0 and (best < 0 or t < best):
            best = t
    var ab = b - a
    var ll = dot(ab, ab)
    if ll > 0:
        var ao = o - a
        var dd = dot(d, ab) / ll
        var od = dot(ao, ab) / ll
        var pd = d - ab * dd
        var po = ao - ab * od
        var qa = dot(pd, pd)
        var qb = 2 * dot(pd, po)
        var qc = dot(po, po) - r * r
        if qa > 1e-12:
            var disc = qb * qb - 4 * qa * qc
            if disc >= 0:
                var t = (-qb - sqrt(disc)) / (2 * qa)
                if t >= 0:
                    var s = od + dd * t
                    if s >= 0 and s <= 1 and (best < 0 or t < best):
                        best = t
    return best


struct HitStop(Copyable, Movable):
    """Per-owner freeze counters: a hit freezes attacker and target for a
    few ticks (time scale 0), counted down by `tick`."""

    var left: List[Int]

    def __init__(out self, owners: Int):
        self.left = List[Int](length=owners, fill=0)

    def freeze(mut self, owner: Int, ticks: Int):
        if owner >= 0 and owner < len(self.left):
            self.left[owner] = max(self.left[owner], ticks)

    def scale(self, owner: Int) -> Real:
        return 0 if owner >= 0 and owner < len(self.left) and self.left[owner] > 0 else 1

    def tick(mut self):
        for i in range(len(self.left)):
            if self.left[i] > 0:
                self.left[i] -= 1
