"""Save game vs deterministic snapshot (ROADMAP 17.40): bytes and time to
write and to read back N crates. The snapshot stores everything the solver
needs to continue bit-exactly (caches, islands, materials...) as text; the
save stores what a game chooses to keep (pose + velocity per dynamic body)
through the reflection schema, descriptors once per section.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from gameplay.save import SaveWriter, SaveReader, BodyRecord, save_bodies, load_bodies


def _level(n: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    for i in range(n):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(i % 32) * 0.7 - 11, 0.3, Real(i // 32) * 0.7 - 11, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    for _ in range(10):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0), broadphase=True)
    return sc^


def main() raises:
    var t = BenchTable("Save game (schema, bodies only) vs full snapshot: write + read")
    for n in [64, 1024]:
        var sc = _level(n)
        var t0 = Int(perf_counter_ns())
        var snap = scene_to_string(sc)
        var t1 = Int(perf_counter_ns())
        var back = scene_from_string(snap)
        var t2 = Int(perf_counter_ns())
        keep(back.bset.bodies[1].position()[0])
        t.add("snapshot write (" + String(snap.byte_length()) + " B)", n, "scene", t1 - t0, 1)
        t.add("snapshot read", n, "scene", t2 - t1, 1)
        var t3 = Int(perf_counter_ns())
        var w = SaveWriter()
        w.add("bodies", save_bodies(sc))
        var blob = w.bytes()
        var t4 = Int(perf_counter_ns())
        var rebuilt = _level(n)
        var t5 = Int(perf_counter_ns())
        var r = SaveReader(blob^)
        var recs = List[BodyRecord]()
        _ = r.read("bodies", BodyRecord(0, Vec3(0, 0, 0, 0), Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)), recs)
        _ = load_bodies(rebuilt, recs)
        var t6 = Int(perf_counter_ns())
        keep(rebuilt.bset.bodies[1].position()[0])
        t.add("save write (" + String(len(w.bytes())) + " B)", n, "scene", t4 - t3, 1)
        t.add("save read + apply (level rebuild excluded)", n, "scene", t6 - t5, 1)
    t.print_report()
