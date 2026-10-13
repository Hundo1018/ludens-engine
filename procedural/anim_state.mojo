"""Animator state graph (ROADMAP 17.64).

`AnimGraph` assembles the pieces into one object evaluated once per tick:

  * parameters: floats, bools and triggers (a trigger is consumed by the
    transition that uses it);
  * states: a clip and a playback speed;
  * transitions: from a state (or any state, `src = -1`) to another, taken
    when every condition holds and, if `exit_time >= 0`, once the source has
    played that fraction of its clip; a duration and an easing curve
    (`procedural.tween` ids); while a transition runs, another may only cut
    in if the running one is `interruptible`;
  * two transition implementations (a seam): `TRANS_FADE` samples both
    clips and blends them with the eased weight; `TRANS_INERTIAL` samples
    only the new clip and decays the pose difference recorded at the switch
    (`procedural.inertialize`). Once a transition is over both give the new
    clip's sample exactly;
  * events: the current state's clip fires its `EventTrack` over the tick's
    clip-time interval (`procedural.anim_events`); the outgoing state of a
    transition stops firing at the switch.

All pose buffers are allocated once in the constructor; `tick` allocates
only when a caller-provided `events` list grows. The graph is a value type,
so a copy is a snapshot: a copy taken mid-transition continues bit for bit.
"""

from geometry.vec import Real
from .anim import AnimClip, blend_poses, BLEND_DLB
from .anim_events import EventTrack
from .inertialize import Inertializer
from .tween import ease_dyn

comptime COND_GT = 0  # float param > value
comptime COND_LT = 1  # float param < value
comptime COND_TRUE = 2  # bool param set
comptime COND_FALSE = 3  # bool param clear
comptime COND_TRIGGER = 4  # trigger param set (consumed on use)

comptime TRANS_FADE = 0
comptime TRANS_INERTIAL = 1


@fieldwise_init
struct Cond(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var param: Int
    var value: Real


@fieldwise_init
struct AnimTransition(Copyable, Movable):
    var src: Int  # -1 = from any state
    var dst: Int
    var conds: List[Cond]
    var exit_time: Real  # fraction of the source clip; < 0 = none
    var duration: Real
    var ease: Int
    var interruptible: Bool


@fieldwise_init
struct AnimStateDef(Copyable, ImplicitlyCopyable, Movable):
    var clip: Int
    var speed: Real


struct AnimGraph(Copyable, Movable):
    var bones: Int
    var mode: Int
    var blend: Int
    var states: List[AnimStateDef]
    var transitions: List[AnimTransition]
    var floats: List[Real]
    var bools: List[Bool]
    var triggers: List[Bool]
    var current: Int
    var time: Real  # unwrapped clip time of the current state
    var prev: Int
    var prev_time: Real
    var elapsed: Real
    var tr_len: Real
    var tr_ease: Int
    var tr_interruptible: Bool
    var in_transition: Bool
    var inert: Inertializer
    var _pa: List[Real]
    var _ra: List[Real]
    var _pb: List[Real]
    var _rb: List[Real]
    var _last_p: List[Real]
    var _last_r: List[Real]
    var _has_last: Bool

    def __init__(out self, bones: Int, mode: Int = TRANS_FADE, blend: Int = BLEND_DLB):
        self.bones = bones
        self.mode = mode
        self.blend = blend
        self.states = List[AnimStateDef]()
        self.transitions = List[AnimTransition]()
        self.floats = List[Real]()
        self.bools = List[Bool]()
        self.triggers = List[Bool]()
        self.current = 0
        self.time = 0
        self.prev = -1
        self.prev_time = 0
        self.elapsed = 0
        self.tr_len = 0
        self.tr_ease = 0
        self.tr_interruptible = True
        self.in_transition = False
        self.inert = Inertializer(bones)
        self._pa = List[Real](length=3 * bones, fill=0)
        self._ra = List[Real](length=4 * bones, fill=0)
        self._pb = List[Real](length=3 * bones, fill=0)
        self._rb = List[Real](length=4 * bones, fill=0)
        self._last_p = List[Real](length=3 * bones, fill=0)
        self._last_r = List[Real](length=4 * bones, fill=0)
        self._has_last = False

    def add_state(mut self, clip: Int, speed: Real = 1) -> Int:
        self.states.append(AnimStateDef(clip, speed))
        return len(self.states) - 1

    def add_transition(mut self, var t: AnimTransition) raises:
        if t.dst < 0 or t.dst >= len(self.states) or t.src < -1 or t.src >= len(self.states):
            raise Error("AnimGraph.add_transition: state out of range")
        self.transitions.append(t^)

    def add_float(mut self, v: Real = 0) -> Int:
        self.floats.append(v)
        return len(self.floats) - 1

    def add_bool(mut self, v: Bool = False) -> Int:
        self.bools.append(v)
        return len(self.bools) - 1

    def add_trigger(mut self) -> Int:
        self.triggers.append(False)
        return len(self.triggers) - 1

    def _holds(self, c: Cond) -> Bool:
        if c.kind == COND_GT:
            return self.floats[c.param] > c.value
        if c.kind == COND_LT:
            return self.floats[c.param] < c.value
        if c.kind == COND_TRUE:
            return self.bools[c.param]
        if c.kind == COND_FALSE:
            return not self.bools[c.param]
        return self.triggers[c.param]

    def _pick(self, clips: List[AnimClip]) -> Int:
        if self.in_transition and not self.tr_interruptible:
            return -1
        for k in range(len(self.transitions)):
            ref t = self.transitions[k]
            if t.dst == self.current:
                continue
            if t.src >= 0 and t.src != self.current:
                continue
            if t.exit_time >= 0:
                var dur = clips[self.states[self.current].clip].duration()
                if dur > 0 and self.time / dur < t.exit_time:
                    continue
            var ok = True
            for c in t.conds:
                if not self._holds(c):
                    ok = False
                    break
            if ok:
                return k
        return -1

    def tick(
        mut self, dt: Real, clips: List[AnimClip], tracks: List[EventTrack],
        mut pos: List[Real], mut rot: List[Real], mut events: List[Int],
    ):
        """Advance by `dt` seconds, write the pose into `pos` / `rot` (3 and 4
        reals per bone) and append the events fired this tick."""
        var k = self._pick(clips)
        if k >= 0:
            var dst = self.transitions[k].dst
            for c in self.transitions[k].conds:
                if c.kind == COND_TRIGGER:
                    self.triggers[c.param] = False
            if self.mode == TRANS_INERTIAL and self._has_last:
                clips[self.states[dst].clip].sample(0, self._pb, self._rb)
                self.inert.start(self._last_p, self._last_r, self._pb, self._rb, self.transitions[k].duration)
            self.prev = self.current
            self.prev_time = self.time
            self.current = dst
            self.time = 0
            self.elapsed = 0
            self.tr_len = self.transitions[k].duration
            self.tr_ease = self.transitions[k].ease
            self.tr_interruptible = self.transitions[k].interruptible
            self.in_transition = self.tr_len > 0
        # advance clocks and fire the current clip's events
        var sd = self.states[self.current]
        var t0 = self.time
        self.time += dt * sd.speed
        if sd.clip < len(tracks):
            ref clip = clips[sd.clip]
            tracks[sd.clip].fire(t0, self.time, clip.duration(), clip.loop, events)
        if self.in_transition:
            self.prev_time += dt * self.states[self.prev].speed
            self.elapsed += dt
            if self.mode == TRANS_INERTIAL:
                self.inert.advance(dt)
            if self.elapsed >= self.tr_len:
                self.in_transition = False
        # evaluate
        if self.in_transition and self.mode == TRANS_FADE:
            clips[self.states[self.prev].clip].sample(self.prev_time, self._pa, self._ra)
            clips[self.states[self.current].clip].sample(self.time, self._pb, self._rb)
            var w = ease_dyn(self.tr_ease, self.elapsed / self.tr_len)
            blend_poses(self._pa, self._ra, self._pb, self._rb, self.bones, w, self.blend, pos, rot)
        else:
            clips[self.states[self.current].clip].sample(self.time, pos, rot)
            if self.in_transition and self.mode == TRANS_INERTIAL:
                self.inert.apply(pos, rot)
        for i in range(3 * self.bones):
            self._last_p[i] = pos[i]
        for i in range(4 * self.bones):
            self._last_r[i] = rot[i]
        self._has_last = True
