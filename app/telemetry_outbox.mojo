"""The ludens-core operations outbox (`diag/outbox`, ROADMAP 17.73) into a telemetry queue (platform/telemetry.mojo, #147).

The simulation writes typed records (kind, tick, key, a, b) into an `Outbox` during a tick; after the tick the host drains
them here. A record becomes an event of the same kind, tick and key with the values [a, b]; `time_ms` is the session
time at the drain. An outbox record kind below 1 or above 65535 is not an event kind: it is counted in `skipped`. The
outbox's own drop count (records refused because it was full) is added to `outbox_dropped`, since telemetry counts only
what its own queue dropped."""
from diag.outbox import Outbox
from platform.telemetry import TEL_DROPPED, TEL_INVALID, TEL_QUEUED, Telemetry


struct OutboxForward(Movable):
    var queued: Int
    var dropped: Int  # refused by the telemetry queue (full)
    var skipped: Int  # not an event kind
    var refused: Int  # no consent
    var outbox_dropped: Int

    def __init__(out self):
        self.queued = 0
        self.dropped = 0
        self.skipped = 0
        self.refused = 0
        self.outbox_dropped = 0

    def forward(mut self, mut box: Outbox, mut tel: Telemetry, time_ms: Int) -> Int:
        """Drain `box` into `tel`; the number of events queued this call."""
        self.outbox_dropped += box.take_dropped()
        var n = 0
        for r in box.drain():
            var st = tel.record(r.kind, r.tick, time_ms, r.key, [r.a, r.b])
            if st == TEL_QUEUED:
                n += 1
            elif st == TEL_DROPPED:
                self.dropped += 1
            elif st == TEL_INVALID:
                self.skipped += 1
            else:
                self.refused += 1
        self.queued += n
        return n
