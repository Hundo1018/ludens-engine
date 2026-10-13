# tier: integration
"""Operations boundary: outbox, achievements, loc keys, black box (ROADMAP 17.73).

  1. Ordinary: records pushed during ticks come out of `drain` in order;
     an achievement for 10 rat kills unlocks exactly once, on the 10th, and
     its unlock reaches the outbox once; registered localisation keys
     absent from a string table are listed.
  2. Integration: a 40-box scene stepped 300 times with telemetry pushing
     every body's position each tick ends bit-identical to the same scene
     with telemetry off; a black box packed at a failing tick (log, all
     counters, a snapshot 50 ticks earlier, the inputs since) is unpacked in
     a clean scene, the snapshot restored and the inputs replayed: the state
     at the failing tick is bit-identical to the original run.
  3. Extreme: a full outbox drops the newest and counts it (capacity 0
     drops everything); sampling 1 in 4 keeps the same records on two runs
     and about a quarter of them; after a rollback the re-simulated ticks
     already delivered are refused and `rewind` drops undelivered ones; the
     achievement unlocked state survives a flags round trip; a corrupted,
     truncated or wrong-version black box raises.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from diag.outbox import Outbox
from diag.counters import Counters, COUNT
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_bytes, scene_from_bytes
from gameplay.flow import Flags
from gameplay.achievements import Achievements, OUT_ACHIEVEMENT
from gameplay.loc_keys import LocKeys, loc_id
from gameplay.blackbox import BlackBox, pack, unpack

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _pile() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k % 5) * 0.6 - 1.2, 0.3 + Real(k // 5) * 0.55, Real(k % 3) * 0.1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    return sc^


def _input(mut sc: ContactScene6[QuatBody6], tick: Int) raises:
    """The recorded input: a push on body 1 every 10 ticks."""
    if tick % 10 == 0:
        sc.apply_impulse(sc.bset.id_of(1), Vec3(0.3, 0, 0, 0), sc.pose(sc.bset.id_of(1)).pos)


def _same(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    for i in range(len(a.bset.bodies)):
        if a.bset.bodies[i].pos != b.bset.bodies[i].pos or a.bset.bodies[i].vel != b.bset.bodies[i].vel:
            return False
    return True


def main() raises:
    var s = Suite("ops")

    # ---- outbox -----------------------------------------------------------------------------------
    var ob = Outbox(8)
    for t in range(1, 6):
        _ = ob.push(7, t, t * 10, t)
    var got = ob.drain()
    s.check(len(got) == 5 and got[0].tick == 1 and got[4].key == 50, "records come out of drain in order")
    for t in range(6, 20):
        _ = ob.push(7, t, 0)
    s.check(len(ob.records) == 8 and ob.take_dropped() == 6, "full: newest dropped and counted")
    var zero = Outbox(0)
    _ = zero.push(1, 1, 1)
    s.check(len(zero.records) == 0 and zero.dropped == 1, "capacity 0 drops everything")
    var sa = Outbox(100000)
    var sb = Outbox(100000)
    sa.sample_every = 4
    sb.sample_every = 4
    for t in range(10000):
        _ = sa.push(3, t, t % 17)
        _ = sb.push(3, t, t % 17)
    var same_s = len(sa.records) == len(sb.records)
    for i in range(min(len(sa.records), len(sb.records))):
        if sa.records[i].tick != sb.records[i].tick:
            same_s = False
    print("  sampling 1 in 4 over 10000 records: kept", len(sa.records))
    s.check(same_s and abs(len(sa.records) - 2500) < 250, "sampling keeps the same records each run, about a quarter")
    var rb = Outbox(100)
    for t in range(1, 11):
        _ = rb.push(1, t, 0)
    _ = rb.drain()
    var acc = 0
    for t in range(6, 13):
        if rb.push(1, t, 0):
            acc += 1
    rb.rewind(11)
    s.check(acc == 2 and len(rb.records) == 1 and rb.records[0].tick == 11, "rollback: delivered ticks refused, rewind drops undelivered later ones")

    # ---- telemetry on / off parity -------------------------------------------------------------------
    var on = _pile()
    var off = _pile()
    var tele = Outbox(1 << 20)
    for t in range(300):
        on.step_soft(DT, G)
        off.step_soft(DT, G)
        for i in range(len(on.bset.bodies)):
            _ = tele.push(9, t, i, Int(on.bset.bodies[i].pos[0] * 1000), Int(on.bset.bodies[i].pos[1] * 1000))
    print("  telemetry on: records", len(tele.records), "  scene identical to telemetry off:", _same(on, off))
    s.check(_same(on, off) and len(tele.records) == 300 * 41, "telemetry on / off: simulation bit-identical")

    # ---- achievements --------------------------------------------------------------------------------
    var flags = Flags()
    var ach = Achievements()
    var rats = ach.define(flags, "rat_slayer", 5, 10)
    var box = Outbox(16)
    var unlocks = List[Int]()
    for t in range(15):
        unlocks.append(ach.on_event(flags, box, 5, 1, t))
    var first = -1
    var total = 0
    for i in range(15):
        total += unlocks[i]
        if unlocks[i] == 1 and first < 0:
            first = i
    var msgs = box.drain()
    s.check(total == 1 and first == 9 and len(msgs) == 1 and msgs[0].kind == OUT_ACHIEVEMENT and ach.unlocked(flags, rats), "unlocks exactly once, on the 10th kill, one outbox record")
    var f2 = Flags()
    var a2 = Achievements()
    _ = a2.define(f2, "rat_slayer", 5, 10)
    f2.load(flags.to_bytes())
    s.check(a2.unlocked(f2, rats) and a2.on_event(f2, box, 5, 1, 99) == 0, "unlocked state survives a flags round trip; no second unlock")

    # ---- localisation keys -----------------------------------------------------------------------------
    var lk = LocKeys()
    var k1 = lk.register("menu.start")
    var k2 = lk.register("menu.quit")
    var k3 = lk.register("hud.ammo")
    var table: List[Int] = [k1, k3]
    var miss = lk.missing(table)
    s.check(len(miss) == 1 and miss[0] == "menu.quit" and lk.register("menu.start") == k1 and loc_id("") == 0x811C9DC5, "missing keys listed; ids stable")
    _ = k2

    # ---- black box ---------------------------------------------------------------------------------------
    var run = _pile()
    var snap = List[UInt8]()
    var inputs = List[UInt8]()
    for t in range(150):
        if t == 100:
            snap = scene_to_bytes(run)
        if t >= 100:
            inputs.append(UInt8(1) if t % 10 == 0 else UInt8(0))
        _input(run, t)
        run.step_soft(DT, G)
    var c = Counters()
    var cv = List[Int]()
    for i in range(COUNT):
        cv.append(Int(c.get(i)))
    var blob = pack(BlackBox("[ERROR] invariant: box 3 left the world at tick 150", cv, snap, inputs, 150))
    var bb = unpack(blob)
    var clean = scene_from_bytes(bb.snapshot.copy())
    for k in range(len(bb.inputs)):
        var t = 100 + k
        if bb.inputs[k] == 1:
            clean.apply_impulse(clean.bset.id_of(1), Vec3(0.3, 0, 0, 0), clean.pose(clean.bset.id_of(1)).pos)
        clean.step_soft(DT, G)
        _ = t
    print("  black box:", len(blob), "bytes (snapshot", len(bb.snapshot), ", inputs", len(bb.inputs), ")  replay to tick", bb.tick, "identical:", _same(clean, run))
    s.check(_same(clean, run) and len(bb.counters) == COUNT and bb.log.startswith("[ERROR]"), "a clean process reproduces the failing tick bit for bit")
    var errs = 0
    var bad = blob.copy()
    bad[30] = bad[30] ^ 1
    try:
        _ = unpack(bad)
    except:
        errs += 1
    var cut = List[UInt8]()
    for i in range(len(blob) - 9):
        cut.append(blob[i])
    try:
        _ = unpack(cut)
    except:
        errs += 1
    var v2 = blob.copy()
    v2[8] = 2
    try:
        _ = unpack(v2)
    except:
        errs += 1
    s.check(errs == 3, "corrupted, truncated, wrong version: raise")
    s.finish()
