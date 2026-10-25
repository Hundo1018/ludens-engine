"""Sequence playback into the simulation (ROADMAP 17.68).

`SequencePlayer` plays a `procedural.sequence.Sequence` forward with a
`SeqCursor`, one tick at a time:

  * every event the cursor crosses is sent as a `SeqEvent` into a
    `scheduler.events.Channel` (sequence id, event id, sequence time), so
    gameplay, VFX and audio readers see it in tick order, exactly once;
  * bound bodies are made kinematic and driven to their tracks' pose each
    tick with `ContactScene6.move_to` (a Vec3 track for the position, an
    optional quaternion track for the rotation);
  * after the last tick, bodies bound with `release = True` become dynamic
    again (`ContactScene6.set_dynamic`) with the velocity the track ends
    with (its derivative over the last `dt`), so a scripted
    throw or a platform dropping off its rail carries on physically.

Call `tick` before `ContactScene6.step` with the same `dt`.
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Body6, Pose6
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase
from scheduler.events import Channel
from procedural.sequence import Sequence, SeqCursor


@fieldwise_init
struct SeqEvent(Copyable, ImplicitlyCopyable, Movable):
    var sequence: Int  # the player's id
    var event: Int  # the event id in the sequence's EventTrack
    var time: Real  # sequence time at the end of the tick that crossed it


@fieldwise_init
struct BodyBinding(Copyable, ImplicitlyCopyable, Movable):
    var body: BodyId
    var pos_track: Int  # Vec3 track
    var rot_track: Int  # quaternion track, -1 keeps the body's rotation
    var release: Bool  # hand back to the dynamics at the end


struct SequencePlayer(Copyable, Movable):
    var id: Int
    var seq: Sequence
    var cursor: SeqCursor
    var bindings: List[BodyBinding]
    var finished: Bool  # the cursor reached the end
    var released: Bool  # release bodies handed back
    var _fired: List[Int]

    def __init__(out self, id: Int, var seq: Sequence):
        self.id = id
        self.cursor = SeqCursor(seq)
        self.seq = seq^
        self.bindings = List[BodyBinding]()
        self.finished = False
        self.released = False
        self._fired = List[Int]()

    def bind[B: Body6, BP: BroadPhase](
        mut self, mut sc: ContactScene6[B, BP], body: BodyId, pos_track: Int, rot_track: Int = -1, release: Bool = False,
    ) raises:
        """Drive `body` with the given tracks (made kinematic now). Raises
        on a track index out of range or an invalid body."""
        if pos_track < 0 or pos_track >= len(self.seq.vec3s):
            raise Error("SequencePlayer.bind: no such Vec3 track")
        if rot_track < -1 or rot_track >= len(self.seq.quats):
            raise Error("SequencePlayer.bind: no such quaternion track")
        sc.set_kinematic(body)
        self.bindings.append(BodyBinding(body, pos_track, rot_track, release))

    def tick[B: Body6, BP: BroadPhase](
        mut self, mut sc: ContactScene6[B, BP], dt: Real, mut events: Channel[SeqEvent]
    ) raises:
        """Advance by `dt`: send crossed events, drive bound bodies; the tick
        after the end releases bodies. `dt <= 0` does nothing."""
        if not (dt > 0):
            return
        if self.finished:
            if not self.released:
                self.released = True
                var L = self.seq.length
                var h = min(dt, L)
                for b in self.bindings:
                    if b.release:
                        sc.set_dynamic(b.body)
                        if h > 0:
                            # the track's velocity over its last dt, not the
                            # last tick's (which may be a float residue)
                            var v = (self.seq.vec3(b.pos_track, L) - self.seq.vec3(b.pos_track, L - h)) / h
                            var w = Vec3(0, 0, 0, 0)
                            if b.rot_track >= 0:
                                var q1 = self.seq.quat(b.rot_track, L)
                                var q0 = self.seq.quat(b.rot_track, L - h)
                                var qd = q1 * q0.conjugate()
                                if qd.w < 0:
                                    qd = Quat(-qd.x, -qd.y, -qd.z, -qd.w)
                                w = Vec3(qd.x, qd.y, qd.z, 0) * (2 / h)
                            sc.set_velocity(b.body, v, w)
            return
        self._fired.clear()
        self.cursor.advance(self.seq, dt, self._fired)
        for e in self._fired:
            events.send(SeqEvent(self.id, e, self.cursor.t))
        for b in self.bindings:
            var i = b.body.index()
            var rot = sc.bset.bodies[i].rotation()
            if b.rot_track >= 0:
                rot = self.cursor.quat(self.seq, b.rot_track)
            sc.move_to(b.body, Pose6(self.cursor.vec3(self.seq, b.pos_track), rot), dt)
        if self.cursor.t >= self.seq.length:
            self.finished = True
