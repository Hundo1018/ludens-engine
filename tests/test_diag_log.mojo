# tier: unit
"""`LogRing`/`log[level]` contract: ordinary logging, drop-newest overflow
counting, and the compile-time level gate. `LUDENS_LOG_LEVEL` defaults to
`Level.INFO` (3), so this file needs no special `-D` flag to exercise both a
compiled-in level (INFO) and a compiled-out one (TRACE) in the same binary."""

from harness.runner import Suite
from diag.level import Level, LOG_LEVEL, level_name
from diag.log import LogRecord, LogRing, log


def main() raises:
    var s = Suite("diag_log")

    # --- ordinary case: log a few records at a compiled-in level, dump them ---
    var ring = LogRing[8]()
    log[Level.INFO](ring, 1, "physics", "step start", 0.0, 0.0)
    log[Level.WARN](ring, 2, "physics", "slow step", 12.5, 0.0)
    s.eqi(ring.count(), 2, "ordinary: two records logged")
    s.eqi(ring.dropped, 0, "ordinary: nothing dropped yet")
    var dump = ring.dump()
    s.check("physics" in dump, "ordinary: dump contains category")
    s.check("slow step" in dump, "ordinary: dump contains message")
    s.check("WARN" in dump, "ordinary: dump contains level name")

    # --- level filtered at compile time: TRACE (5) > default LOG_LEVEL (3) ---
    s.check(LOG_LEVEL == Level.INFO, "default LOG_LEVEL is INFO")
    var before = ring.count()
    log[Level.TRACE](ring, 3, "physics", "should not appear", 0.0, 0.0)
    s.eqi(ring.count(), before, "disabled level: record count unchanged")
    s.check(
        "should not appear" not in ring.dump(),
        "disabled level: message never entered the ring",
    )
    # DEBUG (4) is also above INFO (3) -- same proof, different level.
    log[Level.DEBUG](ring, 4, "physics", "also should not appear", 0.0, 0.0)
    s.eqi(ring.count(), before, "disabled DEBUG level: record count unchanged")

    # --- extreme: zero capacity -- every push drops, count stays 0 ---
    var zero_ring = LogRing[0]()
    log[Level.ERROR](zero_ring, 0, "test", "dropped immediately", 0.0, 0.0)
    log[Level.ERROR](zero_ring, 0, "test", "dropped immediately 2", 0.0, 0.0)
    s.eqi(zero_ring.count(), 0, "zero capacity: never stores anything")
    s.eqi(zero_ring.dropped, 2, "zero capacity: every push counted as dropped")

    # --- extreme: exactly full, then one more (drop-newest + count) ---
    var full_ring = LogRing[4]()
    for i in range(4):
        log[Level.ERROR](full_ring, i, "cat", "msg", 0.0, 0.0)
    s.eqi(full_ring.count(), 4, "exactly-full: all 4 stored")
    s.eqi(full_ring.dropped, 0, "exactly-full: nothing dropped yet")
    log[Level.ERROR](full_ring, 99, "cat", "overflow", 0.0, 0.0)
    s.eqi(full_ring.count(), 4, "overflow: count stays at capacity")
    s.eqi(full_ring.dropped, 1, "overflow: exactly one drop counted")
    # drop-newest: the retained records are the FIRST 4, not the last 4.
    s.check(
        "overflow" not in full_ring.dump(),
        "overflow: the dropped (newest) record never entered the ring",
    )

    # --- clear() resets both records and drop count ---
    full_ring.clear()
    s.eqi(full_ring.count(), 0, "clear: count reset")
    s.eqi(full_ring.dropped, 0, "clear: dropped reset")

    # --- level_name covers the whole range used above ---
    s.check(level_name(Level.ERROR) == "ERROR", "level_name ERROR")
    s.check(level_name(Level.WARN) == "WARN", "level_name WARN")
    s.check(level_name(Level.INFO) == "INFO", "level_name INFO")

    s.finish()
