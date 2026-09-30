# tier: integration
"""Input recording and deterministic replay (ROADMAP 17.39).

A character walks, jumps and kicks crates (random directions from the
recorded RNG stream) for 300 ticks while a `Recorder` keeps the inputs, a
snapshot every 50 ticks and a checksum per tick.

  ordinary     replaying from the start reproduces the live run bit for bit
               (checksum of every tick, final state).
  seam parity  `seek` (nearest snapshot + short re-run) lands on the same
               state as a full re-run, for targets on, just after and just
               before snapshot ticks.
  integration  the ghost (character positions over a replay) equals the
               live trajectory; `first_divergence` returns -1 for an intact
               recording and the exact tick when one input is edited.
  extreme      seek to tick 0 and to the last tick; an interval of 1.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from scheduler.rng import SplitMix64
from gameplay.character import CharacterController
from gameplay.replay import (
    InputFrame, SimState, Recorder, sim_tick, checksum, replay_from_start, seek,
    first_divergence, ghost,
)

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime TICKS = 300


def _world() raises -> SimState:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(30, 1, 30, 0), True)
    for k in range(3):
        _ = sc.add(QuatBody6.at_rest(Vec3(2 + Real(k), 0.3, 0.5, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    return SimState(sc^, CharacterController(Vec3(0, 0.92, 0, 0)), SplitMix64.seeded(1234))


def _input(t: Int) -> InputFrame:
    var mv = Vec3(2, 0, 0, 0) if (t // 60) % 2 == 0 else Vec3(-1, 0, 1.5, 0)
    var jump = Real(4) if t % 90 == 45 else Real(0)
    var btn = UInt32(1) if t % 70 == 20 else UInt32(0)
    return InputFrame(t, mv, jump, btn)


def _same(a: SimState, b: SimState) -> Bool:
    return checksum(a) == checksum(b)


def main() raises:
    var s = Suite("replay")

    var live = _world()
    var rec = Recorder(50)
    var trail = List[Vec3]()
    for t in range(TICKS):
        rec.step(live, _input(t), DT, G)
        trail.append(live.ctl.position)

    var full = replay_from_start(rec, TICKS, DT, G)
    s.check(_same(full, live), "replay from the start == live run (final state, bit for bit)")
    s.eqi(first_divergence(rec, DT, G), -1, "every tick's checksum reproduces")

    var ok = True
    for target in [0, 49, 50, 51, 149, 150, 222, TICKS]:
        var a = seek(rec, target, DT, G)
        var b = replay_from_start(rec, target, DT, G)
        if not _same(a, b) or a.tick != target:
            ok = False
    s.check(ok, "seek (snapshot + short re-run) == full re-run at every target")

    var gh = ghost(rec, DT, G)
    var gok = len(gh) == len(trail)
    for i in range(min(len(gh), len(trail))):
        if gh[i][0] != trail[i][0] or gh[i][1] != trail[i][1] or gh[i][2] != trail[i][2]:
            gok = False
    s.check(gok, "ghost trajectory == live trajectory")
    var moved = abs(trail[TICKS - 1][0]) + abs(trail[TICKS - 1][2])
    s.check(moved > 1, "(the character actually went somewhere)")

    var edited = Recorder(50)
    var st2 = _world()
    for t in range(TICKS):
        edited.step(st2, _input(t), DT, G)
    edited.inputs[137].move = Vec3(0, 0, -3, 0)
    s.eqi(first_divergence(edited, DT, G), 137, "an edited input diverges at exactly its tick")

    var every = Recorder(1)
    var st3 = _world()
    for t in range(40):
        every.step(st3, _input(t), DT, G)
    s.check(_same(seek(every, 40, DT, G), st3), "interval 1: seek lands on the live state")
    s.eqi(len(every.snapshots), 40, "interval 1: a snapshot per tick")

    s.finish()
