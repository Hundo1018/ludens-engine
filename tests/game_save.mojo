# tier: integration
"""Saving and restoring the demo game (issue #122): a game saved part way and restored in a new process-like instance reaches
the same hash as the uninterrupted run, through the real SaveStore (slots, autosave, checksum). Prints the save size and
save / load time. Native only: `pixi run -e wasm test-game`."""
from game.demo_mode import DEMO_SAVE_VERSION, DemoMode
from game.intent import Intent
from game.mode import GameMode
from geometry.vec import Real
from platform.cloud_save import MemoryCloudSave
from platform.save_store import (
    AUTOSAVE_SLOT,
    HEADER_BYTES,
    SAVE_NOT_FOUND,
    SAVE_OK,
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


def main() raises:
    var c = Check()
    round_trip(c, 0, "", 90, 360)
    round_trip(c, 7, "arena", 150, 360)
    round_trip(c, 7, "arena", 205, 360)  # saved while paused
    round_trip(c, 3, "bare", 60, 300)

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
