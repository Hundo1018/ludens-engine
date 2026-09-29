"""Replay seek (ROADMAP 17.39): landing on a late tick of a 600-tick
recording by re-running everything from tick 0 vs restoring the nearest
snapshot and re-running the rest, over snapshot interval -- and what the
snapshots cost to record. Both paths land on the same state bit for bit
(`test_replay`).
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from scheduler.rng import SplitMix64
from gameplay.character import CharacterController
from gameplay.replay import InputFrame, SimState, Recorder, replay_from_start, seek, checksum

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime TICKS = 600


def _world() raises -> SimState:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(30, 1, 30, 0), True)
    for k in range(8):
        _ = sc.add(QuatBody6.at_rest(Vec3(2 + Real(k % 4), 0.3 + Real(k // 4) * 0.61, 0.5, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    return SimState(sc^, CharacterController(Vec3(0, 0.92, 0, 0)), SplitMix64.seeded(7))


def _input(t: Int) -> InputFrame:
    var mv = Vec3(2, 0, 0, 0) if (t // 60) % 2 == 0 else Vec3(-1, 0, 1.5, 0)
    return InputFrame(t, mv, Real(4) if t % 90 == 45 else Real(0), UInt32(1) if t % 70 == 20 else UInt32(0))


def main() raises:
    var t = BenchTable("Replay: seek to tick 590 of 600 -- full re-run vs nearest snapshot")
    for interval in [600, 120, 30, 10]:
        var st = _world()
        var rec = Recorder(interval)
        var t0 = Int(perf_counter_ns())
        for k in range(TICKS):
            rec.step(st, _input(k), DT, G)
        t.add("record 600 ticks, snapshot every " + String(interval), TICKS, "tick", Int(perf_counter_ns()) - t0, TICKS)
        var t1 = Int(perf_counter_ns())
        var a = seek(rec, 590, DT, G)
        t.add("seek via snapshots (interval " + String(interval) + ")", TICKS, "seek", Int(perf_counter_ns()) - t1, 1)
        keep(checksum(a))
    var st = _world()
    var rec = Recorder(600)
    for k in range(TICKS):
        rec.step(st, _input(k), DT, G)
    var t2 = Int(perf_counter_ns())
    var b = replay_from_start(rec, 590, DT, G)
    t.add("full re-run from tick 0", TICKS, "seek", Int(perf_counter_ns()) - t2, 1)
    keep(checksum(b))
    t.print_report()
