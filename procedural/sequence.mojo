"""Sequences / timelines (ROADMAP 17.68).

A `Sequence` holds keyed tracks -- scalar (with a `procedural.tween` easing
per segment), Vec3 (linear) and quaternion (slerp) -- plus an `EventTrack`
(`procedural.anim_events`, events crossed exactly once). Evaluation is a
pure function of time: `scalar(k, t)` / `vec3(k, t)` / `quat(k, t)` find the
segment by binary search, so any t can be read in any order (scrub, skip,
fast-forward give the same values).

A clip track (`add_clip_track` / `key_clip` / `clip`) says which animation
clip plays at time t and at what local time: each key starts a clip at
`start` (from `offset`, at `speed`) and crossfades from the previous key's
clip over `blend` seconds; `clip(k, t)` returns both clips' local times and
the weight of the new one, so a host or a 17.64 animator samples them.

`SeqCursor` is the other evaluation strategy (a seam): it remembers each
track's current segment and walks forward from it, which is O(1) per step
for playback. It computes the same segment index and the same arithmetic,
so its values equal `Sequence`'s bit for bit; `advance` also fires the
events crossed (backwards scrubs fire in reverse order).
"""

from std.math import isfinite
from geometry.vec import Real, Vec3
from geometry.quat import Quat, slerp
from .tween import ease_dyn
from .anim_events import EventTrack


struct ScalarTrack(Copyable, Movable):
    var times: List[Real]
    var values: List[Real]
    var eases: List[Int]  # per segment (into the next key)

    def __init__(out self):
        self.times = List[Real]()
        self.values = List[Real]()
        self.eases = List[Int]()


struct Vec3Track(Copyable, Movable):
    var times: List[Real]
    var values: List[Vec3]

    def __init__(out self):
        self.times = List[Real]()
        self.values = List[Vec3]()


struct QuatTrack(Copyable, Movable):
    var times: List[Real]
    var values: List[Quat]

    def __init__(out self):
        self.times = List[Real]()
        self.values = List[Quat]()


@fieldwise_init
struct ClipKey(Copyable, ImplicitlyCopyable, Movable):
    var start: Real  # sequence time the clip starts
    var clip: Int  # clip id (the host's or an `AnimLibrary`'s)
    var offset: Real  # clip time at `start`
    var speed: Real
    var blend: Real  # crossfade from the previous key's clip, seconds


@fieldwise_init
struct ClipSample(Copyable, ImplicitlyCopyable, Movable):
    var clip: Int  # -1 before the first key
    var time: Real  # local time in `clip`
    var prev_clip: Int  # -1 when not blending
    var prev_time: Real
    var weight: Real  # of `clip`; 1 - weight goes to `prev_clip`


struct ClipTrack(Copyable, Movable):
    var times: List[Real]
    var keys: List[ClipKey]

    def __init__(out self):
        self.times = List[Real]()
        self.keys = List[ClipKey]()


def _check_time(times: List[Real], t: Real) raises:
    if len(times) > 0 and t < times[len(times) - 1]:
        raise Error("Sequence: keys must be added in non-decreasing time")


def _seg(times: List[Real], t: Real) -> Int:
    """Last key index with time <= t (0 before the first key)."""
    var lo = 0
    var hi = len(times) - 1
    if hi <= 0 or t <= times[0]:
        return 0
    if t >= times[hi]:
        return hi
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if times[mid] <= t:
            lo = mid
        else:
            hi = mid
    return lo


def _frac(times: List[Real], i: Int, t: Real) -> Real:
    if i + 1 >= len(times):
        return 0
    var span = times[i + 1] - times[i]
    if span <= 0:
        return 1
    return min(max((t - times[i]) / span, Real(0)), Real(1))


struct Sequence(Copyable, Movable):
    var scalars: List[ScalarTrack]
    var vec3s: List[Vec3Track]
    var quats: List[QuatTrack]
    var clips: List[ClipTrack]
    var events: EventTrack
    var length: Real

    def __init__(out self, length: Real):
        self.scalars = List[ScalarTrack]()
        self.vec3s = List[Vec3Track]()
        self.quats = List[QuatTrack]()
        self.clips = List[ClipTrack]()
        self.events = EventTrack()
        self.length = length

    def add_scalar_track(mut self) -> Int:
        self.scalars.append(ScalarTrack())
        return len(self.scalars) - 1

    def add_vec3_track(mut self) -> Int:
        self.vec3s.append(Vec3Track())
        return len(self.vec3s) - 1

    def add_quat_track(mut self) -> Int:
        self.quats.append(QuatTrack())
        return len(self.quats) - 1

    def add_clip_track(mut self) -> Int:
        self.clips.append(ClipTrack())
        return len(self.clips) - 1

    def key_scalar(mut self, k: Int, t: Real, v: Real, ease: Int = 0) raises:
        _check_time(self.scalars[k].times, t)
        self.scalars[k].times.append(t)
        self.scalars[k].values.append(v)
        self.scalars[k].eases.append(ease)

    def key_vec3(mut self, k: Int, t: Real, v: Vec3) raises:
        _check_time(self.vec3s[k].times, t)
        self.vec3s[k].times.append(t)
        self.vec3s[k].values.append(v)

    def key_clip(mut self, k: Int, start: Real, clip: Int, offset: Real = 0, speed: Real = 1, blend: Real = 0) raises:
        """Start `clip` at sequence time `start`. Raises on a key earlier
        than the last, a negative blend or a non-finite speed."""
        _check_time(self.clips[k].times, start)
        if not (blend >= 0) or not isfinite(speed):
            raise Error("Sequence.key_clip: blend must be >= 0 and speed finite")
        self.clips[k].times.append(start)
        self.clips[k].keys.append(ClipKey(start, clip, offset, speed, blend))

    def key_quat(mut self, k: Int, t: Real, q: Quat) raises:
        _check_time(self.quats[k].times, t)
        self.quats[k].times.append(t)
        self.quats[k].values.append(q)

    # ---- evaluation at a known segment (shared by seek and cursor) --------
    def scalar_at(self, k: Int, i: Int, t: Real) -> Real:
        ref tr = self.scalars[k]
        if len(tr.times) == 0:
            return 0
        if i + 1 >= len(tr.times):
            return tr.values[i]
        var u = ease_dyn(tr.eases[i], _frac(tr.times, i, t))
        return tr.values[i] + (tr.values[i + 1] - tr.values[i]) * u

    def vec3_at(self, k: Int, i: Int, t: Real) -> Vec3:
        ref tr = self.vec3s[k]
        if len(tr.times) == 0:
            return Vec3(0, 0, 0, 0)
        if i + 1 >= len(tr.times):
            return tr.values[i]
        var u = _frac(tr.times, i, t)
        return tr.values[i] + (tr.values[i + 1] - tr.values[i]) * u

    def quat_at(self, k: Int, i: Int, t: Real) -> Quat:
        ref tr = self.quats[k]
        if len(tr.times) == 0:
            return Quat(0, 0, 0, 1)
        if i + 1 >= len(tr.times):
            return tr.values[i]
        return slerp(tr.values[i], tr.values[i + 1], _frac(tr.times, i, t))

    def clip(self, k: Int, t: Real) -> ClipSample:
        """Clip(s) playing on clip track `k` at time `t` (pure in t)."""
        ref tr = self.clips[k]
        if len(tr.times) == 0 or t < tr.times[0]:
            return ClipSample(-1, 0, -1, 0, 1)
        var i = _seg(tr.times, t)
        var key = tr.keys[i]
        var local = key.offset + (t - key.start) * key.speed
        if i == 0 or key.blend <= 0 or t >= key.start + key.blend:
            return ClipSample(key.clip, local, -1, 0, 1)
        var pk = tr.keys[i - 1]
        var w = (t - key.start) / key.blend
        return ClipSample(key.clip, local, pk.clip, pk.offset + (t - pk.start) * pk.speed, w)

    # ---- random access (pure in t) ------------------------------------------------
    def scalar(self, k: Int, t: Real) -> Real:
        return self.scalar_at(k, _seg(self.scalars[k].times, t), t)

    def vec3(self, k: Int, t: Real) -> Vec3:
        return self.vec3_at(k, _seg(self.vec3s[k].times, t), t)

    def quat(self, k: Int, t: Real) -> Quat:
        return self.quat_at(k, _seg(self.quats[k].times, t), t)


def _walk(times: List[Real], i: Int, t: Real) -> Int:
    """Segment index for t found by walking from i (either direction);
    equals `_seg(times, t)`."""
    var n = len(times)
    if n <= 1 or t <= times[0]:
        return 0
    if t >= times[n - 1]:
        return n - 1
    var j = min(max(i, 0), n - 1)
    while j + 1 < n and times[j + 1] <= t:
        j += 1
    while j > 0 and times[j] > t:
        j -= 1
    return j


struct SeqCursor(Copyable, Movable):
    var t: Real
    var si: List[Int]
    var vi: List[Int]
    var qi: List[Int]

    def __init__(out self, seq: Sequence):
        self.t = 0
        self.si = List[Int](length=len(seq.scalars), fill=0)
        self.vi = List[Int](length=len(seq.vec3s), fill=0)
        self.qi = List[Int](length=len(seq.quats), fill=0)

    def advance(mut self, seq: Sequence, dt: Real, mut events: List[Int]):
        """Move by `dt` (negative scrubs back), firing the events crossed."""
        var t0 = self.t
        self.t = min(max(self.t + dt, Real(0)), seq.length)
        seq.events.fire(t0, self.t, seq.length, False, events)
        for k in range(len(self.si)):
            self.si[k] = _walk(seq.scalars[k].times, self.si[k], self.t)
        for k in range(len(self.vi)):
            self.vi[k] = _walk(seq.vec3s[k].times, self.vi[k], self.t)
        for k in range(len(self.qi)):
            self.qi[k] = _walk(seq.quats[k].times, self.qi[k], self.t)

    def scalar(self, seq: Sequence, k: Int) -> Real:
        return seq.scalar_at(k, self.si[k], self.t)

    def vec3(self, seq: Sequence, k: Int) -> Vec3:
        return seq.vec3_at(k, self.vi[k], self.t)

    def quat(self, seq: Sequence, k: Int) -> Quat:
        return seq.quat_at(k, self.qi[k], self.t)
