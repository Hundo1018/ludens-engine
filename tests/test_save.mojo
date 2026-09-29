# tier: integration
"""Save games on reflection schemas (ROADMAP 17.40).

  ordinary     a player record and an inventory list round-trip through a
               save blob.
  seam parity  a level simulated for a second is saved two ways -- the 6.10
               deterministic snapshot and a save game of body poses and
               velocities; after loading each (the save onto a scene the
               level script rebuilt), every saved field is bit-identical
               between the two. Stepping on, they differ only by what the
               save deliberately leaves out (the warm-start cache): measured.
  integration  a save written by "build 1" (PlayerV1) loads into "build 2"
               (PlayerV2: a field added, one removed) by field name.
  extreme      a missing section reads as empty; bad magic, a truncated
               blob and a newer save format raise; an empty save loads.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string
from gameplay.save import SaveWriter, SaveReader, BodyRecord, save_bodies, load_bodies

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


@fieldwise_init
struct PlayerV1(Copyable, Movable):
    var hp: Float32
    var gold: Int
    var pos: Vec3
    var legacy_flag: Bool


@fieldwise_init
struct PlayerV2(Copyable, Movable):
    var hp: Float32
    var mana: Float32  # new in build 2
    var gold: Int
    var pos: Vec3


@fieldwise_init
struct Item(Copyable, Movable):
    var id: Int
    var count: Int


def _level() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    for k in range(6):
        var b = QuatBody6.at_rest(Vec3(Real(k % 3) * 0.7, 0.3 + Real(k // 3) * 0.9, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3))
        b.vel = Vec3(0.5, 0, 0.2, 0)
        _ = sc.add(b^, Vec3(0.3, 0.3, 0.3, 0), False)
    return sc^


def main() raises:
    var s = Suite("save")

    # ---- ordinary ------------------------------------------------------------
    var w = SaveWriter()
    var pl = List[PlayerV1]()
    pl.append(PlayerV1(87.5, 1200, Vec3(3, 1, -2, 0), True))
    w.add("player", pl, 1, "Player")
    var inv = List[Item]()
    for k in range(5):
        inv.append(Item(100 + k, k * 3))
    w.add("inventory", inv)
    var r = SaveReader(w.bytes())
    var back = List[Item]()
    _ = r.read("inventory", Item(0, 0), back)
    var inv_ok = len(back) == 5
    for k in range(min(5, len(back))):
        if back[k].id != 100 + k or back[k].count != k * 3:
            inv_ok = False
    s.check(inv_ok, "inventory round-trips")

    # ---- integration: build 1 save -> build 2 load ---------------------------
    var p2 = List[PlayerV2]()
    var rep = r.read("player", PlayerV2(100, 50, 0, Vec3(0, 0, 0, 0)), p2, 2, "Player")
    s.check(len(p2) == 1 and p2[0].hp == 87.5 and p2[0].gold == 1200, "V1 save loads into V2 by field name")
    s.check(p2[0].pos[0] == 3 and p2[0].pos[2] == -2, "... nested vector fields too")
    s.check(p2[0].mana == 50, "the field build 2 added keeps its default")
    s.check(rep.dropped == 1 and rep.defaulted == 1 and rep.stored_version == 1, "report: 1 dropped, 1 defaulted, stored version 1")

    # ---- seam parity: save game vs deterministic snapshot ---------------------
    var live = _level()
    for _ in range(60):
        live.step_soft(DT, G)
    var snap = scene_to_string(live)
    var sw = SaveWriter()
    sw.add("bodies", save_bodies(live))
    var from_snap = scene_from_string(snap)
    var rebuilt = _level()
    var sr = SaveReader(sw.bytes())
    var recs = List[BodyRecord]()
    _ = sr.read("bodies", BodyRecord(0, Vec3(0, 0, 0, 0), Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)), recs)
    s.eqi(load_bodies(rebuilt, recs), 6, "all 6 dynamic bodies restored")
    var same = True
    for i in range(len(rebuilt.bset.bodies)):
        ref a = rebuilt.bset.bodies[i]
        ref b = from_snap.bset.bodies[i]
        for k in range(3):
            if a.pos[k] != b.pos[k] or a.vel[k] != b.vel[k] or a.omega[k] != b.omega[k]:
                same = False
        if a.q.x != b.q.x or a.q.y != b.q.y or a.q.z != b.q.z or a.q.w != b.q.w:
            same = False
    s.check(same, "every saved field == the snapshot's, bit for bit")
    for _ in range(60):
        rebuilt.step_soft(DT, G)
        from_snap.step_soft(DT, G)
    var drift = Real(0)
    for i in range(len(rebuilt.bset.bodies)):
        var d = rebuilt.bset.bodies[i].position() - from_snap.bset.bodies[i].position()
        for k in range(3):
            drift = max(drift, abs(d[k]))
    print("  one second after loading: save vs snapshot max position difference", drift)
    s.check(drift < 0.05, "stepping on, the save (no warm-start cache) stays close to the snapshot")

    # ---- extremes ---------------------------------------------------------------
    var none = List[Item]()
    var miss = r.read("quests", Item(0, 0), none)
    s.check(len(none) == 0 and miss.stored_version == -1, "a missing section reads as empty")
    var bad = 0
    var junk = List[UInt8](length=64, fill=7)
    try:
        _ = SaveReader(junk^)
    except:
        bad += 1
    var cut = w.bytes()
    var short = List[UInt8]()
    for k in range(len(cut) - 5):
        short.append(cut[k])
    try:
        _ = SaveReader(short^)
    except:
        bad += 1
    var newer = w.bytes()
    newer[8] = 99  # format version
    try:
        _ = SaveReader(newer^)
    except:
        bad += 1
    s.eqi(bad, 3, "bad magic, truncation and a newer format raise")
    var empty = SaveReader(SaveWriter().bytes())
    s.check(not empty.has("player"), "an empty save loads")

    s.finish()
