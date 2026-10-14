"""Bounded outbox for operations data leaving the simulation (ROADMAP 17.73).

Telemetry, achievement unlocks and similar records are written into the
outbox during a tick and taken by the host after it; the simulation never
calls the host mid-step and never reads the outbox back, so turning
telemetry on or off cannot change simulation state (`test_ops` checks a
scene bit for bit both ways).

Records are typed numbers only - (kind, tick, key, a, b) - so personal
strings cannot leak through by construction.

  * full: the newest record is dropped and counted (`dropped`, forwarded to
    `OUTBOX_DROPPED` by the owner), like `LogRing` and `DrawQueue`;
  * sampling: `sample_every = k` keeps a record when a hash of
    (kind, tick, key) is 0 mod k - the same records on every run;
  * rollback: `drain` remembers the newest tick it delivered; a record for
    a tick at or before it is refused (a rollback re-simulation does not
    deliver an event twice), and `rewind(tick)` drops undelivered records
    after `tick` so the re-simulation can regenerate them.
"""


@fieldwise_init
struct OutRecord(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var tick: Int
    var key: Int
    var a: Int
    var b: Int


struct Outbox(Copyable, Movable):
    var capacity: Int
    var records: List[OutRecord]
    var dropped: Int
    var enabled: Bool
    var sample_every: Int
    var delivered_tick: Int

    def __init__(out self, capacity: Int):
        self.capacity = max(capacity, 0)
        self.records = List[OutRecord]()
        self.dropped = 0
        self.enabled = True
        self.sample_every = 1
        self.delivered_tick = -1

    def push(mut self, kind: Int, tick: Int, key: Int, a: Int = 0, b: Int = 0) -> Bool:
        if not self.enabled or tick <= self.delivered_tick:
            return False
        if self.sample_every > 1:
            var h = UInt64(kind) * 0x9E3779B97F4A7C15 ^ UInt64(tick) * 0xC2B2AE3D27D4EB4F ^ UInt64(key) * 0x165667B19E3779F9
            h ^= h >> 29
            if h % UInt64(self.sample_every) != 0:
                return False
        if len(self.records) >= self.capacity:
            self.dropped += 1
            return False
        self.records.append(OutRecord(kind, tick, key, a, b))
        return True

    def drain(mut self) -> List[OutRecord]:
        var out = self.records^
        # pre-size for the next tick like this one: regrowing from empty
        # every tick cost 2.8 us per record in `bench_ops` (16 % of a
        # 40-box step), the append itself 72 ns
        self.records = List[OutRecord](capacity=min(len(out), self.capacity))
        for r in out:
            self.delivered_tick = max(self.delivered_tick, r.tick)
        return out^

    def rewind(mut self, tick: Int):
        """Drop undelivered records after `tick` (before a re-simulation)."""
        var keep = List[OutRecord]()
        for r in self.records:
            if r.tick <= tick:
                keep.append(r)
        self.records = keep^

    def take_dropped(mut self) -> Int:
        var d = self.dropped
        self.dropped = 0
        return d
