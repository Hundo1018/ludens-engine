"""Telemetry events (docs/telemetry.md, issue #147): opt-in, a bounded queue, batches sent over the Transport seam.

A game records events (level start and end, death, purchase, a setting changed, or its own kinds from EV_GAME_FIRST up)
into `Telemetry`. Nothing is queued until the player has opted in (`grant`); `withdraw` empties the queue, forgets the
install id and refuses every later event. An event is numbers only: kind, tick, milliseconds since the session began, a
key and up to MAX_VALUES integers. There is no string field, so a name, an e-mail or a chat line cannot be put in one.
The only identifier sent is the install id: 16 random bytes the caller supplies (`crypto.getRandomValues` on the web,
`/dev/urandom` natively), shaped as a version 4 UUID by `install_id_from`. A new grant after a withdrawal takes a new id.

When the queue holds `capacity` events, a new event is dropped and counted (`dropped()`), and the count goes out in the
next batch header. `flush(t)` encodes as many events as fit in one message (at most MAX_BATCH_BYTES and the transport's
`max_message()`), sends it, and removes those events only when `send` returned NET_OK; on NET_NO_PEER or NET_FULL they
stay queued for the next flush.

Batch format (all integers little-endian), checked by the reference reader `scripts/telemetry_read.py`:

    magic u32 "LTEL" | format u16 | flags u16 | install_id [16] | session_id u64 | seq u32 | dropped u32
    | build_id_len u8 | build_id | tag_count u8 | tags (key u32, value u32) * tag_count
    | event_count u32 | events | checksum u64

    event: kind u16 | value_count u8 | 0 u8 | tick i64 | time_ms u32 | key i64 | values i64 * value_count

`checksum` is FNV-1a 64 over every byte before it. `seq` counts the batches sent in this session from 0; `dropped` is the
number of events dropped since the previous batch. Tags are per-session key/value pairs sent in every header, for
example an A/B test's bucket (#149): `set_tag(experiment, bucket)`.

The consent record (`encode_consent`, the slot CONSENT_SLOT of the CloudSave seam) keeps the choice and the id:

    magic u32 "LTCN" | format u16 | state u8 | install_id [16] | checksum u64

Standard library only."""
from platform.save_store import FNV_BASIS, fnv1a64, get_uint, put_uint
from platform.transport import NET_INVALID, NET_OK, Transport, send_bytes

comptime TEL_MAGIC = 0x4C45544C  # "LTEL" read as bytes 4C 54 45 4C
comptime TEL_FORMAT: Int = 1
comptime CONSENT_MAGIC = 0x4E43544C  # "LTCN"
comptime CONSENT_FORMAT: Int = 1
comptime CONSENT_SLOT = "telemetry/consent"
comptime CONSENT_BYTES: Int = 4 + 2 + 1 + 16 + 8

comptime EV_LEVEL_START: Int = 1
"""key: the level; values: none."""
comptime EV_LEVEL_END: Int = 2
"""key: the level; values: [outcome (game-defined, e.g. 0 quit, 1 won, 2 lost), seconds in the level]."""
comptime EV_DEATH: Int = 3
"""key: the level; values: [cause, x, y, z] (position in the game's own fixed-point units)."""
comptime EV_PURCHASE: Int = 4
"""key: the item; values: [price in the smallest currency unit, currency (ISO 4217 numeric)]."""
comptime EV_SETTING_CHANGED: Int = 5
"""key: the setting; values: [old value, new value]."""
comptime EV_GAME_FIRST: Int = 256
"""Kinds from here to 65535 are the game's own."""

comptime MAX_VALUES: Int = 6
comptime MAX_BUILD_ID: Int = 64
comptime MAX_TAGS: Int = 16
comptime MAX_BATCH_BYTES: Int = 64 * 1024
comptime DEFAULT_CAPACITY: Int = 1024
comptime INSTALL_ID_BYTES: Int = 16

comptime CONSENT_UNSET: Int = 0
"""The player has not been asked: nothing is queued or sent."""
comptime CONSENT_GRANTED: Int = 1
comptime CONSENT_WITHDRAWN: Int = 2

comptime TEL_QUEUED: Int = 0
comptime TEL_NO_CONSENT: Int = 1
"""Refused: the player has not opted in, or has withdrawn. Not counted as dropped."""
comptime TEL_DROPPED: Int = 2
"""The queue was full: this (the newest) event is dropped and counted."""
comptime TEL_INVALID: Int = 3
"""Refused: a kind outside 1..65535 or more than MAX_VALUES values."""

comptime NET_FULL_LATER = 1
"""flush: `max_batches` batches went out and events are still pending; call again on a later frame."""

comptime BATCH_HEADER_FIXED: Int = 4 + 2 + 2 + 16 + 8 + 4 + 4 + 1 + 1 + 4
comptime EVENT_FIXED: Int = 2 + 1 + 1 + 8 + 4 + 8


@fieldwise_init
struct TelEvent(Copyable, Movable):
    var kind: Int
    var tick: Int
    var time_ms: Int
    var key: Int
    var values: List[Int]

    def encoded_bytes(self) -> Int:
        return EVENT_FIXED + 8 * len(self.values)


def install_id_from(a: UInt64, b: UInt64) -> List[UInt8]:
    """16 bytes from 128 random bits, with the version 4 and variant bits of RFC 9562 set."""
    var out = List[UInt8](capacity=INSTALL_ID_BYTES)
    put_uint(out, a, 8)
    put_uint(out, b, 8)
    out[6] = (out[6] & 0x0F) | 0x40
    out[8] = (out[8] & 0x3F) | 0x80
    return out^


def install_id_text(id: List[UInt8]) -> String:
    """The id as a UUID string, 8-4-4-4-12 lowercase hex."""
    var out = List[UInt8]()
    for i in range(len(id)):
        if i == 4 or i == 6 or i == 8 or i == 10:
            out.append(45)
        out.append(_hex(Int(id[i] >> 4)))
        out.append(_hex(Int(id[i] & 0x0F)))
    return String(unsafe_from_utf8=out^)


def _hex(d: Int) -> UInt8:
    return UInt8(48 + d) if d < 10 else UInt8(87 + d)


def clip_ascii(s: String, n: Int) -> String:
    """The first `n` bytes of `s`, with every byte outside printable ASCII (32..126) replaced by `?`."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        if len(out) >= n:
            break
        out.append(b if b >= 32 and b <= 126 else UInt8(63))
    return String(unsafe_from_utf8=out^)


def _zero_id() -> List[UInt8]:
    return List[UInt8](length=INSTALL_ID_BYTES, fill=0)


struct Telemetry(Movable):
    var _capacity: Int
    var _events: List[TelEvent]
    var _head: Int  # index of the oldest unsent event in _events
    var _dropped: Int  # since the last batch that was sent
    var _dropped_total: Int
    var _state: Int
    var _install_id: List[UInt8]
    var _session_id: UInt64
    var _seq: Int
    var _build_id: String
    var _tag_keys: List[Int]
    var _tag_values: List[Int]
    var _sent_events: Int
    var _sent_batches: Int

    def __init__(out self, build_id: String, session_id: UInt64, capacity: Int = DEFAULT_CAPACITY):
        """`build_id`: ASCII, at most MAX_BUILD_ID bytes (cut to that); `session_id`: random per launch."""
        self._capacity = max(capacity, 1)
        self._events = List[TelEvent]()
        self._head = 0
        self._dropped = 0
        self._dropped_total = 0
        self._state = CONSENT_UNSET
        self._install_id = _zero_id()
        self._session_id = session_id
        self._seq = 0
        self._build_id = clip_ascii(build_id, MAX_BUILD_ID)
        self._tag_keys = List[Int]()
        self._tag_values = List[Int]()
        self._sent_events = 0
        self._sent_batches = 0

    # consent

    def state(self) -> Int:
        return self._state

    def granted(self) -> Bool:
        return self._state == CONSENT_GRANTED

    def install_id(self) -> List[UInt8]:
        """All zero unless the player has opted in."""
        return self._install_id.copy()

    def grant(mut self, install_id: List[UInt8]) -> Bool:
        """Opt in with this install id (INSTALL_ID_BYTES, not all zero). False and no change for any other id."""
        if len(install_id) != INSTALL_ID_BYTES:
            return False
        var any = False
        for b in install_id:
            any = any or b != 0
        if not any:
            return False
        self._install_id = install_id.copy()
        self._state = CONSENT_GRANTED
        return True

    def withdraw(mut self):
        """Opt out: the queue is emptied, the install id forgotten, every later event refused."""
        self._state = CONSENT_WITHDRAWN
        self._install_id = _zero_id()
        self._events = List[TelEvent]()
        self._head = 0
        self._dropped = 0

    # tags (#149: A/B buckets)

    def set_tag(mut self, key: Int, value: Int) -> Bool:
        """Set a header tag (both u32). False when MAX_TAGS other keys are already set."""
        for i in range(len(self._tag_keys)):
            if self._tag_keys[i] == key:
                self._tag_values[i] = value
                return True
        if len(self._tag_keys) >= MAX_TAGS:
            return False
        self._tag_keys.append(key)
        self._tag_values.append(value)
        return True

    # events

    def pending(self) -> Int:
        return len(self._events) - self._head

    def dropped(self) -> Int:
        """Events dropped because the queue was full, since this Telemetry was made."""
        return self._dropped_total

    def sent_events(self) -> Int:
        return self._sent_events

    def sent_batches(self) -> Int:
        return self._sent_batches

    def record(mut self, kind: Int, tick: Int, time_ms: Int, key: Int, values: List[Int] = List[Int]()) -> Int:
        """TEL_QUEUED, TEL_NO_CONSENT, TEL_DROPPED (full: this event is dropped and counted) or TEL_INVALID."""
        if self._state != CONSENT_GRANTED:
            return TEL_NO_CONSENT
        if kind < 1 or kind > 0xFFFF or len(values) > MAX_VALUES:
            return TEL_INVALID
        if self.pending() >= self._capacity:
            self._dropped += 1
            self._dropped_total += 1
            return TEL_DROPPED
        if self._head > 0 and self._head == len(self._events):
            self._events.clear()
            self._head = 0
        self._events.append(TelEvent(kind, tick, max(time_ms, 0), key, values.copy()))
        return TEL_QUEUED

    def level_start(mut self, tick: Int, time_ms: Int, level: Int) -> Int:
        return self.record(EV_LEVEL_START, tick, time_ms, level)

    def level_end(mut self, tick: Int, time_ms: Int, level: Int, outcome: Int, seconds: Int) -> Int:
        return self.record(EV_LEVEL_END, tick, time_ms, level, [outcome, seconds])

    def death(mut self, tick: Int, time_ms: Int, level: Int, cause: Int, x: Int, y: Int, z: Int) -> Int:
        return self.record(EV_DEATH, tick, time_ms, level, [cause, x, y, z])

    def purchase(mut self, tick: Int, time_ms: Int, item: Int, price: Int, currency: Int) -> Int:
        return self.record(EV_PURCHASE, tick, time_ms, item, [price, currency])

    def setting_changed(mut self, tick: Int, time_ms: Int, setting: Int, old: Int, new: Int) -> Int:
        return self.record(EV_SETTING_CHANGED, tick, time_ms, setting, [old, new])

    # batches

    def _header_bytes(self) -> Int:
        return BATCH_HEADER_FIXED + self._build_id.byte_length() + 8 * len(self._tag_keys)

    def encode_batch(self, max_bytes: Int) -> Tuple[List[UInt8], Int]:
        """The next batch, holding the oldest pending events that fit in `max_bytes` (with the header and checksum), and
        how many events it holds. Zero events when none are pending or the first one does not fit."""
        var room = min(max_bytes, MAX_BATCH_BYTES) - self._header_bytes() - 8
        var n = 0
        var size = 0
        var i = self._head
        while i < len(self._events) and size + self._events[i].encoded_bytes() <= room:
            size += self._events[i].encoded_bytes()
            n += 1
            i += 1
        var out = List[UInt8](capacity=self._header_bytes() + size + 8)
        put_uint(out, UInt64(TEL_MAGIC), 4)
        put_uint(out, UInt64(TEL_FORMAT), 2)
        put_uint(out, 0, 2)
        for b in self._install_id:
            out.append(b)
        put_uint(out, self._session_id, 8)
        put_uint(out, UInt64(self._seq), 4)
        put_uint(out, UInt64(self._dropped), 4)
        put_uint(out, UInt64(self._build_id.byte_length()), 1)
        for b in self._build_id.as_bytes():
            out.append(b)
        put_uint(out, UInt64(len(self._tag_keys)), 1)
        for t in range(len(self._tag_keys)):
            put_uint(out, UInt64(self._tag_keys[t]), 4)
            put_uint(out, UInt64(self._tag_values[t]), 4)
        put_uint(out, UInt64(n), 4)
        for k in range(self._head, self._head + n):
            ref e = self._events[k]
            put_uint(out, UInt64(e.kind), 2)
            put_uint(out, UInt64(len(e.values)), 1)
            put_uint(out, 0, 1)
            put_uint(out, UInt64(e.tick), 8)
            put_uint(out, UInt64(e.time_ms), 4)
            put_uint(out, UInt64(e.key), 8)
            for v in e.values:
                put_uint(out, UInt64(v), 8)
        put_uint(out, fnv1a64(out, 0, len(out), FNV_BASIS), 8)
        return (out^, n)

    def flush[T: Transport](mut self, mut t: T, max_batches: Int = 8) -> Int:
        """Send up to `max_batches` batches. Returns NET_OK when the queue is empty afterwards (or nothing was pending, or
        the player has not opted in), else the first send result that was not NET_OK (the unsent events stay queued).
        NET_INVALID means one event does not fit in `t.max_message()`; that event is dropped and counted."""
        if self._state != CONSENT_GRANTED:
            return NET_OK
        for _ in range(max_batches):
            if self.pending() == 0 and self._dropped == 0:
                return NET_OK
            var batch = self.encode_batch(t.max_message())
            if batch[1] == 0 and self.pending() > 0:
                self._head += 1  # one event larger than a message: it can never be sent
                self._dropped += 1
                self._dropped_total += 1
                return NET_INVALID
            var r = send_bytes(t, batch[0])
            if r != NET_OK:
                return r
            self._head += batch[1]
            self._sent_events += batch[1]
            self._sent_batches += 1
            self._seq += 1
            self._dropped = 0
            if self._head == len(self._events):
                self._events.clear()
                self._head = 0
        return NET_OK if self.pending() == 0 else NET_FULL_LATER

    # the consent record

    def encode_consent(self) -> List[UInt8]:
        var out = List[UInt8](capacity=CONSENT_BYTES)
        put_uint(out, UInt64(CONSENT_MAGIC), 4)
        put_uint(out, UInt64(CONSENT_FORMAT), 2)
        put_uint(out, UInt64(self._state), 1)
        for b in self._install_id:
            out.append(b)
        put_uint(out, fnv1a64(out, 0, len(out), FNV_BASIS), 8)
        return out^

    def apply_consent(mut self, data: List[UInt8]) -> Bool:
        """Restore a record written by `encode_consent`. False, and the state left as it is, when the record is not
        valid (wrong length, magic, checksum, a newer format or an unknown state); the game then asks again."""
        if len(data) != CONSENT_BYTES or get_uint(data, 0, 4) != UInt64(CONSENT_MAGIC):
            return False
        if fnv1a64(data, 0, CONSENT_BYTES - 8, FNV_BASIS) != get_uint(data, CONSENT_BYTES - 8, 8):
            return False
        if Int(get_uint(data, 4, 2)) > CONSENT_FORMAT:
            return False
        var st = Int(data[6])
        var id = List[UInt8]()
        for i in range(7, 7 + INSTALL_ID_BYTES):
            id.append(data[i])
        if st == CONSENT_GRANTED:
            return self.grant(id)
        if st == CONSENT_WITHDRAWN:
            self.withdraw()
            return True
        if st == CONSENT_UNSET:
            self._state = CONSENT_UNSET
            self._install_id = _zero_id()
            return True
        return False

