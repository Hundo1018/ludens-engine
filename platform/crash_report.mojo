"""Crash reports (docs/telemetry.md, issue #147): saved when the game crashes, sent on the next launch.

`CrashReporter` keeps what a report needs while the game runs: the last `log_lines` log lines, the latest black-box
recording (ludens-core `gameplay/blackbox` `pack`, or any bytes the game chooses), the build id, the tick and the time
since the session began. `context()` packs them into one block. A crash adds the reason and the stack:
`encode_crash(context, reason, frames)`. On the web the page catches the wasm trap, so the game hands the host the
context's address after each `arm` (the `os_crash_arm` import, app/os_crash.mojo) and shell/web/crash_host.mjs writes the
report from wasm memory without calling back into the module. Natively the caller of a frame that raised calls
`encode_crash` itself. Either way the report goes to the CloudSave slot CRASH_SLOT, and `CrashUpload` on the next launch
reads it, sends it over the Transport seam when the player has opted in, and clears the slot (an empty file) once it
was sent, or at once without consent.

The reporter holds nothing until the player has opted in (`set_install_id` with the telemetry install id); `clear()`
drops everything on a withdrawal. A report carries the same install id as the telemetry batches and no other
identifier; log lines are the game's own text, so a game that logs personal data must not hand those lines here.

File format (all integers little-endian), checked by the reference reader `scripts/telemetry_read.py`:

    magic u32 "LCRS" | format u16 | flags u16
    | context: ctx_len u32 (the bytes after this field) | install_id [16] | build_id_len u8 | build_id | tick i64
               | session_ms u32 | log_count u16 | (len u16, utf-8) * log_count | blackbox_len u32 | blackbox
    | reason_len u16 | reason (utf-8) | frame_count u16
    | frames: func_index u32 | offset u32 | line u32 | column u32 | file_len u16 | file | name_len u16 | name
    | checksum u64

`offset` is the byte offset in the module, as a browser's stack trace gives it (`wasm-function[12]:0x3f2`). `line` 0 is
a frame that was not mapped to a source line; then `column`, `file` and `name` are empty or 0 (the name can still be the
function name from the stack). `checksum` is FNV-1a 64 over every byte before it. Standard library only."""
from platform.cloud_save import CloudSave
from platform.packets import KIND_SAVE_READ, KIND_SAVE_WRITE, PACKET_HEADER, STATUS_NOT_FOUND, STATUS_OK, text_bytes
from platform.save_store import FNV_BASIS, fnv1a64, get_uint, put_uint
from platform.telemetry import INSTALL_ID_BYTES, MAX_BUILD_ID, clip_ascii
from platform.transport import NET_INVALID, NET_OK, Transport, send_bytes

comptime CRASH_MAGIC = 0x5352434C  # "LCRS" read as bytes 4C 43 52 53
comptime CRASH_FORMAT: Int = 1
comptime CRASH_SLOT = "crash/pending"
comptime DEFAULT_LOG_LINES: Int = 64
comptime MAX_LOG_LINE: Int = 512
comptime MAX_BLACKBOX: Int = 4 * 1024 * 1024
comptime MAX_REASON: Int = 1024
comptime MAX_FRAMES: Int = 64
comptime MAX_FRAME_TEXT: Int = 256
comptime MAX_REPORT_BYTES: Int = 8 * 1024 * 1024


def _put_text(mut out: List[UInt8], s: String, len_bytes: Int, limit: Int):
    var b = s.as_bytes()
    var n = min(len(b), limit)
    put_uint(out, UInt64(n), len_bytes)
    for i in range(n):
        out.append(b[i])


def _text(data: List[UInt8], mut at: Int, len_bytes: Int) raises -> String:
    var n = Int(_uint(data, at, len_bytes))
    if at + n > len(data):
        raise Error("crash report: truncated text")
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(data[at + i])
    at += n
    return String(unsafe_from_utf8=out^)


def _uint(data: List[UInt8], mut at: Int, n: Int) raises -> UInt64:
    if at + n > len(data):
        raise Error("crash report: truncated")
    var v = get_uint(data, at, n)
    at += n
    return v


@fieldwise_init
struct CrashFrame(Copyable, Movable):
    var func_index: Int
    var offset: Int
    var line: Int  # 0: not mapped
    var column: Int
    var file: String
    var name: String


struct CrashReport(Movable):
    var install_id: List[UInt8]
    var build_id: String
    var tick: Int
    var session_ms: Int
    var log: List[String]
    var blackbox: List[UInt8]
    var reason: String
    var frames: List[CrashFrame]

    def __init__(out self):
        self.install_id = List[UInt8]()
        self.build_id = String()
        self.tick = 0
        self.session_ms = 0
        self.log = List[String]()
        self.blackbox = List[UInt8]()
        self.reason = String()
        self.frames = List[CrashFrame]()


struct CrashReporter(Movable):
    var _install_id: List[UInt8]
    var _build_id: String
    var _lines: List[String]  # a ring of `_cap` lines; _next is where the next one goes
    var _next: Int
    var _count: Int
    var _cap: Int
    var _blackbox: List[UInt8]
    var _armed_tick: Int
    var _session_ms: Int
    var _context: List[UInt8]

    def __init__(out self, build_id: String, log_lines: Int = DEFAULT_LOG_LINES):
        self._install_id = List[UInt8]()
        self._build_id = clip_ascii(build_id, MAX_BUILD_ID)
        self._cap = max(log_lines, 1)
        self._lines = List[String]()
        for _ in range(self._cap):
            self._lines.append(String())
        self._next = 0
        self._count = 0
        self._blackbox = List[UInt8]()
        self._armed_tick = 0
        self._session_ms = 0
        self._context = List[UInt8]()

    def enabled(self) -> Bool:
        return len(self._install_id) == INSTALL_ID_BYTES

    def set_install_id(mut self, id: List[UInt8]):
        """Start keeping a report (the player opted in). An id of any other length than INSTALL_ID_BYTES is `clear()`."""
        if len(id) != INSTALL_ID_BYTES:
            self.clear()
            return
        self._install_id = id.copy()

    def clear(mut self):
        """Forget the install id, the log lines, the black box and the packed context (the player withdrew)."""
        self._install_id = List[UInt8]()
        for i in range(self._cap):
            self._lines[i] = String()
        self._next = 0
        self._count = 0
        self._blackbox = List[UInt8]()
        self._context = List[UInt8]()

    def log(mut self, line: String):
        """Keep `line` (cut to MAX_LOG_LINE bytes) as the newest; the oldest goes when the ring is full."""
        if not self.enabled():
            return
        self._lines[self._next] = line if line.byte_length() <= MAX_LOG_LINE else _cut(line, MAX_LOG_LINE)
        self._next = (self._next + 1) % self._cap
        self._count = min(self._count + 1, self._cap)

    def lines(self) -> List[String]:
        """The kept lines, oldest first."""
        var out = List[String]()
        var start = (self._next - self._count + self._cap) % self._cap
        for i in range(self._count):
            out.append(self._lines[(start + i) % self._cap])
        return out^

    def set_blackbox(mut self, data: List[UInt8]) -> Bool:
        """The recording to send with a crash; False (and the old one kept) when it is over MAX_BLACKBOX bytes."""
        if len(data) > MAX_BLACKBOX:
            return False
        self._blackbox = data.copy()
        return True

    def arm(mut self, tick: Int, session_ms: Int) -> Int:
        """Pack the context now (call it each second or so, and after `set_blackbox`). Returns its length, 0 when the
        player has not opted in. `context_ptr()` is its address until the next `arm` or `clear`."""
        if not self.enabled():
            self._context = List[UInt8]()
            return 0
        self._armed_tick = tick
        self._session_ms = session_ms
        self._context = self.context()
        return len(self._context)

    def context_ptr(self) -> UInt64:
        return UInt64(Int(self._context.unsafe_ptr())) if len(self._context) > 0 else UInt64(0)

    def context_len(self) -> Int:
        return len(self._context)

    def context(self) -> List[UInt8]:
        var body = List[UInt8]()
        for b in self._install_id:
            body.append(b)
        _put_text(body, self._build_id, 1, MAX_BUILD_ID)
        put_uint(body, UInt64(self._armed_tick), 8)
        put_uint(body, UInt64(max(self._session_ms, 0)), 4)
        var ls = self.lines()
        put_uint(body, UInt64(len(ls)), 2)
        for l in ls:
            _put_text(body, l, 2, MAX_LOG_LINE)
        put_uint(body, UInt64(len(self._blackbox)), 4)
        body.extend(self._blackbox.copy())
        var out = List[UInt8](capacity=4 + len(body))
        put_uint(out, UInt64(len(body)), 4)
        out.extend(body^)
        return out^


def _cut(s: String, n: Int) -> String:
    """At most `n` bytes of `s`, cut before a UTF-8 continuation byte so the result stays valid UTF-8."""
    var b = s.as_bytes()
    var end = min(n, len(b))
    while end > 0 and end < len(b) and (b[end] & 0xC0) == 0x80:
        end -= 1
    var out = List[UInt8](capacity=end)
    for i in range(end):
        out.append(b[i])
    return String(unsafe_from_utf8=out^)


def encode_crash(context: List[UInt8], reason: String, frames: List[CrashFrame]) -> List[UInt8]:
    """A whole report: the header, `context` (from `CrashReporter.context()`) as it is, the reason, at most MAX_FRAMES
    frames, the checksum."""
    var out = List[UInt8]()
    put_uint(out, UInt64(CRASH_MAGIC), 4)
    put_uint(out, UInt64(CRASH_FORMAT), 2)
    put_uint(out, 0, 2)
    out.extend(context.copy())
    _put_text(out, _cut(reason, MAX_REASON), 2, MAX_REASON)
    var n = min(len(frames), MAX_FRAMES)
    put_uint(out, UInt64(n), 2)
    for i in range(n):
        ref f = frames[i]
        put_uint(out, UInt64(f.func_index), 4)
        put_uint(out, UInt64(f.offset), 4)
        put_uint(out, UInt64(f.line), 4)
        put_uint(out, UInt64(f.column), 4)
        _put_text(out, _cut(f.file, MAX_FRAME_TEXT), 2, MAX_FRAME_TEXT)
        _put_text(out, _cut(f.name, MAX_FRAME_TEXT), 2, MAX_FRAME_TEXT)
    put_uint(out, fnv1a64(out, 0, len(out), FNV_BASIS), 8)
    return out^


def decode_crash(data: List[UInt8]) raises -> CrashReport:
    """Read a report; raises on a bad magic, a newer format, a checksum mismatch or a length that does not add up."""
    if len(data) < 16:
        raise Error("crash report: truncated")
    if get_uint(data, 0, 4) != UInt64(CRASH_MAGIC):
        raise Error("crash report: bad magic")
    var end = len(data) - 8
    if fnv1a64(data, 0, end, FNV_BASIS) != get_uint(data, end, 8):
        raise Error("crash report: checksum mismatch")
    var fmt = Int(get_uint(data, 4, 2))
    if fmt > CRASH_FORMAT:
        raise Error("crash report: format " + String(fmt) + " is newer than this build reads")
    var body = data.copy()
    body.shrink(end)
    var at = 8
    var ctx_len = Int(_uint(body, at, 4))
    var ctx_end = at + ctx_len
    if ctx_end > end:
        raise Error("crash report: truncated context")
    var r = CrashReport()
    if at + INSTALL_ID_BYTES > ctx_end:
        raise Error("crash report: truncated context")
    for i in range(INSTALL_ID_BYTES):
        r.install_id.append(body[at + i])
    at += INSTALL_ID_BYTES
    r.build_id = _text(body, at, 1)
    r.tick = Int(_uint(body, at, 8))
    r.session_ms = Int(_uint(body, at, 4))
    var nl = Int(_uint(body, at, 2))
    for _ in range(nl):
        r.log.append(_text(body, at, 2))
    var nb = Int(_uint(body, at, 4))
    if at + nb > ctx_end:
        raise Error("crash report: truncated black box")
    for i in range(nb):
        r.blackbox.append(body[at + i])
    at += nb
    if at != ctx_end:
        raise Error("crash report: context length does not match its fields")
    r.reason = _text(body, at, 2)
    var nf = Int(_uint(body, at, 2))
    for _ in range(nf):
        var fi = Int(_uint(body, at, 4))
        var off = Int(_uint(body, at, 4))
        var line = Int(_uint(body, at, 4))
        var col = Int(_uint(body, at, 4))
        var file = _text(body, at, 2)
        var name = _text(body, at, 2)
        r.frames.append(CrashFrame(fi, off, line, col, file, name))
    if at != end:
        raise Error("crash report: " + String(end - at) + " bytes after the last frame")
    return r^


def save_crash[C: CloudSave](mut save: C, id: Int, report: List[UInt8]) -> Int:
    """Write `report` to CRASH_SLOT (a newer crash replaces one that was never sent). The CloudSave request result."""
    return save.write_request(id, CRASH_SLOT, UInt64(Int(report.unsafe_ptr())), len(report))


comptime UP_IDLE: Int = 0
comptime UP_WAITING: Int = 1
"""The read of CRASH_SLOT has not answered yet."""
comptime UP_NONE: Int = 2
"""No report was waiting (no file, or an empty one)."""
comptime UP_SENT: Int = 3
"""The report was sent and the slot cleared."""
comptime UP_DISCARDED: Int = 4
"""The player has not opted in: the report was deleted unsent."""
comptime UP_CORRUPT: Int = 5
"""The file was not a valid report: it was deleted."""
comptime UP_SEND_FAILED: Int = 6
"""The transport refused the report (no peer, full): it stays in the slot for the next launch."""


struct CrashUpload(Movable):
    """On launch: `start(save, id)`, then `step(save, t, granted)` each frame until it returns something other than
    UP_WAITING. The packets of the save seam that are not this upload's are dropped and counted in `foreign()`, so a
    game with other save traffic starts the upload before its own loads (or routes the packets itself)."""

    var _id: Int
    var state: Int
    var reason: String  # why a report was UP_CORRUPT
    var report_bytes: Int
    var _foreign: Int
    var _buf: List[UInt8]

    def __init__(out self):
        self._id = 0
        self.state = UP_IDLE
        self.reason = String()
        self.report_bytes = 0
        self._foreign = 0
        self._buf = List[UInt8]()

    def foreign(self) -> Int:
        return self._foreign

    def start[C: CloudSave](mut self, mut save: C, id: Int) -> Int:
        self._id = id
        self.state = UP_WAITING
        _ = save.read_request(id, CRASH_SLOT)
        return self.state

    def step[C: CloudSave, T: Transport](mut self, mut save: C, mut t: T, granted: Bool) -> Int:
        if self.state != UP_WAITING:
            return self.state
        if len(self._buf) == 0:
            self._buf = List[UInt8](length=PACKET_HEADER + MAX_REPORT_BYTES, fill=0)
        while True:
            var n = save.poll(UInt64(Int(self._buf.unsafe_ptr())), len(self._buf))
            if n <= 0:
                return self.state
            var kind = Int(self._buf[0])
            var id = Int(get_uint(self._buf, 1, 4))
            if kind != KIND_SAVE_READ or id != self._id:
                self._foreign += 1
                continue
            var st = Int(self._buf[5])
            if st != STATUS_OK or n == PACKET_HEADER:
                self.state = UP_NONE
                self._buf = List[UInt8]()
                return self.state
            var data = List[UInt8](capacity=n - PACKET_HEADER)
            for i in range(PACKET_HEADER, n):
                data.append(self._buf[i])
            self._buf = List[UInt8]()
            self.report_bytes = len(data)
            try:
                _ = decode_crash(data)
            except e:
                self.reason = String(e)
                self.state = UP_CORRUPT
                self._clear(save)
                return self.state
            if not granted:
                self.state = UP_DISCARDED
                self._clear(save)
                return self.state
            var r = send_bytes(t, data)
            if r == NET_OK:
                self.state = UP_SENT
                self._clear(save)
            elif r == NET_INVALID:
                self.reason = String("larger than the transport's max_message()")
                self.state = UP_CORRUPT
                self._clear(save)
            else:
                self.state = UP_SEND_FAILED
            return self.state

    def _clear[C: CloudSave](mut self, mut save: C):
        var empty = List[UInt8]()
        _ = save.write_request(self._id, CRASH_SLOT, UInt64(Int(empty.unsafe_ptr())), 0)
