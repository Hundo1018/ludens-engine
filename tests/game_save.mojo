# tier: integration
"""Saving and restoring the demo game (issue #122): a game saved part way and restored in a new process-like instance reaches
the same hash as the uninterrupted run, through the real SaveStore (slots, autosave, checksum). Prints the save size and
save / load time. Native only: `pixi run -e wasm test-game`."""
from game.demo_mode import DEMO_SAVE_VERSION, DemoMigrator, DemoMode
from game.intent import Intent
from game.mode import GameMode
from geometry.vec import Real
from platform.cloud_save import MemoryCloudSave
from platform.save_store import (
    AUTOSAVE_SLOT,
    HEADER_BYTES,
    SAVE_NEEDS_MIGRATION,
    SAVE_NOT_FOUND,
    SAVE_OK,
    migrate_payload,
    put_uint,
    SaveEvent,
    SaveStore,
)
from std.time import perf_counter_ns


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
        print("  [" + ("PASS" if cond else "FAIL") + "]", label)


def script(t: Int) -> Intent:
    """Move for 120 frames, strafe for 60, one jump at frame 30, pause at 200 and resume at 210, then idle."""
    return Intent(Real(1) if t < 120 else Real(0), Real(1) if t < 60 else Real(0), Real(0), Real(0), t == 30, t == 200 or t == 210, False)


def play(mut m: DemoMode, from_frame: Int, to_frame: Int) raises:
    for t in range(from_frame, to_frame):
        m.step(script(t), 1.0 / 60.0)


def one(var events: List[SaveEvent]) -> SaveEvent:
    if len(events) != 1:
        return SaveEvent(-1, True, String(""), 3)
    return events[0].copy()


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def round_trip(mut c: Check, seed: UInt64, scene: String, split: Int, total: Int) raises:
    var label = String("seed ") + String(seed) + String(", scene ") + scene + String(", saved at frame ") + String(split) + String(" of ") + String(total)
    var whole = DemoMode()
    _ = whole.reset(seed, scene)
    play(whole, 0, total)

    var first = DemoMode()
    _ = first.reset(seed, scene)
    play(first, 0, split)
    var hash_at_save = first.hash()
    var t0 = perf_counter_ns()
    var payload = first.save_state()
    var t_save = perf_counter_ns() - t0

    var store = SaveStore[MemoryCloudSave](MemoryCloudSave())
    _ = store.begin_load("one", DEMO_SAVE_VERSION)
    _ = store.poll()
    t0 = perf_counter_ns()
    _ = store.save("one", first.save_version(), payload)
    var saved = one(store.poll())
    var t_store_save = perf_counter_ns() - t0
    c.ok(saved.status == SAVE_OK, label + ": the save is written (" + String(len(payload)) + " payload bytes, " + String(len(payload) + HEADER_BYTES) + " in the file)")

    # a new store over the same storage: what a restart sees
    store.forget()
    var after = store^
    t0 = perf_counter_ns()
    _ = after.begin_load("one", DEMO_SAVE_VERSION)
    var e = one(after.poll())
    var t_store_load = perf_counter_ns() - t0
    c.ok(e.status == SAVE_OK and e.version == DEMO_SAVE_VERSION and same(e.payload, payload), label + ": the store returns the same payload")

    var second = DemoMode()
    t0 = perf_counter_ns()
    var loaded = second.load_state(e.payload)
    var t_load = perf_counter_ns() - t0
    c.ok(loaded and second.hash() == hash_at_save, label + ": the hash right after the load equals the hash at the save (" + String(hash_at_save) + ")")
    c.ok(second.state() == first.state(), label + ": state() JSON is identical after the load")
    play(second, split, total)
    c.ok(second.hash() == whole.hash(), label + ": after the remaining frames the hash equals the uninterrupted run's (" + String(whole.hash()) + ")")
    c.ok(second.state() == whole.state(), label + ": state() JSON is identical to the uninterrupted run's")
    print("  measured:", label, "| payload", len(payload), "bytes | save_state", t_save // 1000, "us | load_state", t_load // 1000, "us | store save+checksum", t_store_save // 1000, "us | store load+verify", t_store_load // 1000, "us")


def buffered(t: Int) -> Intent:
    """Forward for 20 frames, a jump at frame 30 and another at frame 87 with a 100 ms window: the ball is in the air at 87
    and lands at about frame 91, so the second press is still pending when it is saved and fires on the landing."""
    return Intent(Real(1) if t < 20 else Real(0), Real(0), Real(0), Real(0), t == 30 or t == 87, False, False, Real(100))


def play_buffered(mut m: DemoMode, from_frame: Int, to_frame: Int) raises:
    for t in range(from_frame, to_frame):
        m.step(buffered(t), 1.0 / 60.0)


def v1_payload(m: DemoMode) raises -> List[UInt8]:
    """What `save_state` wrote before the jump buffer existed (version 1), written out field by field."""
    var out = List[UInt8]()
    put_uint(out, m.seed, 8)
    var name = m.scene_name.as_bytes()
    put_uint(out, UInt64(len(name)), 1)
    for b in name:
        out.append(b)
    put_uint(out, UInt64(Float64(m.yaw).to_bits()), 8)
    put_uint(out, UInt64(m.tick), 8)
    put_uint(out, UInt64(m.jumps), 8)
    put_uint(out, UInt64(1 if m.paused else 0), 1)
    out.extend(m.world.save())
    return out^


def main() raises:
    var c = Check()
    round_trip(c, 0, "", 90, 360)
    round_trip(c, 7, "arena", 150, 360)
    round_trip(c, 7, "arena", 205, 360)  # saved while paused
    round_trip(c, 3, "bare", 60, 300)

    # a jump press that is still pending (the 100 ms window is open) is part of the save: saved, loaded, it fires on the landing
    var open_whole = DemoMode()
    play_buffered(open_whole, 0, 200)
    var open_first = DemoMode()
    play_buffered(open_first, 0, 88)  # frame 87 is the second press; the ball is still in the air
    var pending = open_first.jump_buffer.left_ms
    c.ok(pending > 0.0 and open_first.jumps == 1, "at frame 88 the second press is pending (" + String(pending) + " ms left) and only one jump has happened")
    var open_payload = open_first.save_state()
    var open_second = DemoMode()
    c.ok(open_second.load_state(open_payload) and open_second.jump_buffer.left_ms == pending and open_second.hash() == open_first.hash(), "the pending press and the hash survive the load")
    play_buffered(open_second, 88, 200)
    c.ok(open_second.jumps == 2 and open_whole.jumps == 2 and open_second.hash() == open_whole.hash(), "after the load the pending press fires on landing: 2 jumps, the hash equals the uninterrupted run's (" + String(open_whole.hash()) + ")")
    var lost = DemoMode()
    c.ok(lost.load_state(open_payload), "loading again")
    lost.jump_buffer.left_ms = 0.0  # what a save that dropped the press would give
    play_buffered(lost, 88, 200)
    c.ok(lost.jumps == 1 and lost.hash() != open_whole.hash(), "without the pending press the same run has 1 jump and a different hash")

    # a version 1 save (no pending press) migrates to version 2 and loads to the same game
    var old_game = DemoMode()
    play(old_game, 0, 150)
    var old_payload = v1_payload(old_game)
    var migrated = migrate_payload(DemoMigrator(), old_payload, 1, DEMO_SAVE_VERSION)
    c.ok(len(migrated) == len(old_payload) + 9 and same(migrated, old_game.save_state()), "the migration adds 9 zero bytes: the result equals what version 2 writes for the same game")
    var from_old = DemoMode()
    c.ok(from_old.load_state(migrated) and from_old.hash() == old_game.hash() and from_old.jump_buffer.left_ms == 0.0, "the migrated save loads to the same hash with no pending press")
    var whole_old = DemoMode()
    play(whole_old, 0, 360)
    play(from_old, 150, 360)
    c.ok(from_old.hash() == whole_old.hash(), "and the run goes on to the uninterrupted run's hash")
    var raised_v1 = False
    var unmigrated = DemoMode()
    try:
        _ = unmigrated.load_state(old_payload)  # a version 1 payload given to the version 2 loader, unmigrated
    except err:
        raised_v1 = True
    c.ok(raised_v1, "an unmigrated version 1 payload does not load as version 2")
    c.ok(not DemoMigrator().can_migrate(2) and DemoMigrator().can_migrate(1), "only the 1 -> 2 step exists")
    var cut_old = List[UInt8]()
    for i in range(12):
        cut_old.append(old_payload[i])
    var raised_cut = False
    try:
        _ = migrate_payload(DemoMigrator(), cut_old, 1, DEMO_SAVE_VERSION)
    except err:
        raised_cut = "truncated" in String(err)
    c.ok(raised_cut, "a truncated version 1 payload raises `truncated` in the migration")
    # through the store: a file written as version 1 reports SAVE_NEEDS_MIGRATION, the chain brings it to 2
    var old_store = SaveStore[MemoryCloudSave](MemoryCloudSave())
    _ = old_store.begin_load("old", 1)
    _ = old_store.poll()
    _ = old_store.save("old", 1, old_payload)
    _ = old_store.poll()
    old_store.forget()
    var reopened = old_store^
    _ = reopened.begin_load("old", DEMO_SAVE_VERSION)
    var oe = one(reopened.poll())
    c.ok(oe.status == SAVE_NEEDS_MIGRATION and oe.version == 1, "the store reports a version 1 file as SAVE_NEEDS_MIGRATION")
    var via_store = DemoMode()
    c.ok(via_store.load_state(migrate_payload(DemoMigrator(), oe.payload, oe.version, DEMO_SAVE_VERSION)) and via_store.hash() == old_game.hash(), "migrated from the store's payload, it loads to the same hash")

    # a payload that does not parse raises and leaves the game as it was
    var g = DemoMode()
    play(g, 0, 40)
    var before = g.hash()
    var good = g.save_state()
    var cut = List[UInt8]()
    for i in range(20):
        cut.append(good[i])
    var raised = False
    try:
        _ = g.load_state(cut)
    except err:
        raised = "truncated" in String(err)
    c.ok(raised and g.hash() == before, "a truncated payload raises `truncated` and the game keeps its state")
    var cut_blob = List[UInt8]()
    for i in range(len(good) - 60):  # the header fields are whole, the world blob ends 60 bytes early
        cut_blob.append(good[i])
    raised = False
    try:
        _ = g.load_state(cut_blob)
    except err:
        raised = True
    c.ok(raised and g.hash() == before and g.tick == 40, "a truncated world blob raises and the running game keeps its state (hash and tick 40)")
    var bad_scene = good.copy()
    bad_scene[9] = UInt8(ord("x"))  # first letter of the scene name
    raised = False
    try:
        _ = g.load_state(bad_scene)
    except err:
        raised = "unknown scene" in String(err)
    c.ok(raised and g.hash() == before, "an unknown scene raises and the game keeps its state")

    # autosave and a manual slot hold different runs
    var m = DemoMode()
    var store = SaveStore[MemoryCloudSave](MemoryCloudSave())
    _ = store.begin_load(AUTOSAVE_SLOT, DEMO_SAVE_VERSION)
    _ = store.begin_load("manual", DEMO_SAVE_VERSION)
    _ = store.poll()
    play(m, 0, 30)
    var h30 = m.hash()
    _ = store.autosave(m.save_version(), m.save_state())
    _ = store.poll()
    play(m, 30, 90)
    var h90 = m.hash()
    _ = store.save("manual", m.save_version(), m.save_state())
    _ = store.poll()
    _ = store.begin_load(AUTOSAVE_SLOT, DEMO_SAVE_VERSION)
    var ea = one(store.poll())
    _ = store.begin_load("manual", DEMO_SAVE_VERSION)
    var em = one(store.poll())
    var ra = DemoMode()
    var rm = DemoMode()
    c.ok(ra.load_state(ea.payload) and ra.hash() == h30, "the autosave slot restores the frame-30 state")
    c.ok(rm.load_state(em.payload) and rm.hash() == h90, "the manual slot restores the frame-90 state")
    _ = store.begin_load("empty", DEMO_SAVE_VERSION)
    c.ok(one(store.poll()).status == SAVE_NOT_FOUND, "a slot never written reports SAVE_NOT_FOUND")

    print("game_save: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed > 0:
        raise Error("game_save failed")
