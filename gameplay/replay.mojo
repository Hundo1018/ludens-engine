"""Input recording and deterministic replay (ROADMAP 17.39) -- QA regression
runs, ghosts, kill-cams; single machine, no network.

A simulation here is `SimState` -- a physics scene, a character controller
and a random stream -- advanced one fixed tick at a time by `sim_tick` from
one `InputFrame`. Because every part is deterministic (the solver steps
bit-reproducibly, the scene snapshot of 6.10 restores it bit-exactly, the
RNG is a value), a recording is just the inputs plus periodic snapshots:

  `Recorder`       inputs per tick, a full `SimState` snapshot every
                   `interval` ticks, and a checksum per tick
  `replay_from_start`  re-run every input from tick 0
  `seek`           restore the nearest snapshot at or before the target tick
                   and re-run only the inputs after it -- the same state as
                   `replay_from_start` bit for bit (the seam), at a cost
                   bounded by the interval
  `first_divergence`  re-run and compare checksums tick by tick: the first
                   tick where a changed build stops reproducing a recording
  `ghost`          the character's positions over a replay
"""

from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from scheduler.rng import SplitMix64
from .character import CharacterController


@fieldwise_init
struct InputFrame(Copyable, ImplicitlyCopyable, Movable):
    var tick: Int
    var move: Vec3  # desired horizontal velocity
    var jump: Real  # jump speed (0 = no jump)
    var buttons: UInt32


struct SimState(Movable):
    var scene: ContactScene6[QuatBody6]
    var ctl: CharacterController
    var rng: SplitMix64
    var tick: Int

    def __init__(out self, var scene: ContactScene6[QuatBody6], var ctl: CharacterController, var rng: SplitMix64):
        self.scene = scene^
        self.ctl = ctl^
        self.rng = rng^
        self.tick = 0


@fieldwise_init
struct Snapshot(Copyable, Movable):
    var tick: Int
    var scene: String
    var ctl: CharacterController
    var rng_state: UInt64  # the generator is a value: its state is all of it


def take(st: SimState) raises -> Snapshot:
    return Snapshot(st.tick, scene_to_string(st.scene), st.ctl.copy(), st.rng.state)


def restore(snap: Snapshot) raises -> SimState:
    var st = SimState(scene_from_string(snap.scene), snap.ctl.copy(), SplitMix64(snap.rng_state))
    st.tick = snap.tick
    return st^


def sim_tick(mut st: SimState, inp: InputFrame, dt: Real, gravity: Vec3) raises:
    """One fixed tick: the character moves from the input, button 1 kicks
    the nearest dynamic body in a random direction (so the RNG is part of
    what must replay), then the world steps."""
    st.ctl.update(st.scene, inp.move, inp.jump, dt, gravity)
    if inp.buttons & 1 != 0:
        for i in range(len(st.scene.bset.bodies)):
            if st.scene.bset.is_dynamic(i):
                var a = st.rng.next_f32() * 6.2831853
                var dir = Vec3(Real(a) - 3, 2, Real(st.rng.next_f32()) - 0.5, 0)
                st.scene.wake(st.scene.bset.id_of(i))
                st.scene.bset.bodies[i].apply_impulse(dir, st.scene.bset.bodies[i].position())
                break
    st.scene.step_soft(dt, gravity)
    st.tick += 1


def checksum(st: SimState) -> UInt64:
    """FNV-1a over the bit patterns of every body position and velocity
    and the character's position."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(st.scene.bset.bodies)):
        var p = st.scene.bset.bodies[i].position()
        var v = st.scene.bset.bodies[i].linear_velocity()
        for k in range(3):
            h = (h ^ UInt64(p[k].to_bits())) * 0x100000001B3
            h = (h ^ UInt64(v[k].to_bits())) * 0x100000001B3
    for k in range(3):
        h = (h ^ UInt64(st.ctl.position[k].to_bits())) * 0x100000001B3
    return h


struct Recorder(Movable):
    var interval: Int
    var inputs: List[InputFrame]
    var snapshots: List[Snapshot]
    var sums: List[UInt64]  # checksum after each tick

    def __init__(out self, interval: Int):
        self.interval = interval
        self.inputs = List[InputFrame]()
        self.snapshots = List[Snapshot]()
        self.sums = List[UInt64]()

    def step(mut self, mut st: SimState, inp: InputFrame, dt: Real, gravity: Vec3) raises:
        """Record `inp`, snapshot on the interval (before the tick), tick,
        record the checksum."""
        if st.tick % self.interval == 0:
            self.snapshots.append(take(st))
        self.inputs.append(inp)
        sim_tick(st, inp, dt, gravity)
        self.sums.append(checksum(st))


def replay_from_start(rec: Recorder, until: Int, dt: Real, gravity: Vec3) raises -> SimState:
    var st = restore(rec.snapshots[0])
    while st.tick < until:
        sim_tick(st, rec.inputs[st.tick], dt, gravity)
    return st^


def seek(rec: Recorder, until: Int, dt: Real, gravity: Vec3) raises -> SimState:
    var k = 0
    for i in range(len(rec.snapshots)):
        if rec.snapshots[i].tick <= until:
            k = i
    var st = restore(rec.snapshots[k])
    while st.tick < until:
        sim_tick(st, rec.inputs[st.tick], dt, gravity)
    return st^


def first_divergence(rec: Recorder, dt: Real, gravity: Vec3) raises -> Int:
    """Re-run the whole recording; the first tick whose checksum differs
    from the recorded one, or -1 if it reproduces."""
    var st = restore(rec.snapshots[0])
    while st.tick < len(rec.inputs):
        sim_tick(st, rec.inputs[st.tick], dt, gravity)
        if checksum(st) != rec.sums[st.tick - 1]:
            return st.tick - 1
    return -1


def ghost(rec: Recorder, dt: Real, gravity: Vec3) raises -> List[Vec3]:
    var st = restore(rec.snapshots[0])
    var out = List[Vec3]()
    while st.tick < len(rec.inputs):
        sim_tick(st, rec.inputs[st.tick], dt, gravity)
        out.append(st.ctl.position)
    return out^
