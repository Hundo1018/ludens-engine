"""Black-box blob for crash / invariant reports (ROADMAP 17.73).

When an invariant fails, the host wants one byte blob to upload: the last
log lines, every counter, the latest snapshot and the tail of the input
recording. Because the simulation is deterministic, a clean process can
restore the snapshot and re-run the inputs to the failing tick
(`test_ops` does exactly that).

Layout: magic "LDBB", version 1, then length-prefixed sections (log text,
counters as i64, snapshot bytes, input-tail bytes, the failing tick), then
an FNV-1a 64 checksum of everything before it. `unpack` raises on a bad
magic, unknown version, truncation or checksum mismatch.
"""

comptime BB_MAGIC = 0x42424C44  # "LDBB"
comptime BB_VERSION = 1


struct BlackBox(Copyable, Movable):
    var log: String
    var counters: List[Int]
    var snapshot: List[UInt8]
    var inputs: List[UInt8]
    var tick: Int

    def __init__(out self, log: String, counters: List[Int], snapshot: List[UInt8], inputs: List[UInt8], tick: Int):
        self.log = log
        self.counters = counters.copy()
        self.snapshot = snapshot.copy()
        self.inputs = inputs.copy()
        self.tick = tick


def _put(mut b: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(b: List[UInt8], mut at: Int, end: Int) raises -> Int:
    if at + 8 > end:
        raise Error("blackbox: truncated")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(b[at + k]) << UInt64(8 * k)
    at += 8
    return Int(u)


def _fnv(b: List[UInt8], n: Int) -> Int:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(n):
        h ^= UInt64(b[i])
        h *= UInt64(0x100000001B3)
    return Int(h)


def pack(bb: BlackBox) -> List[UInt8]:
    var b = List[UInt8]()
    _put(b, BB_MAGIC)
    _put(b, BB_VERSION)
    var lb = bb.log.as_bytes()
    _put(b, len(lb))
    for c in lb:
        b.append(c)
    _put(b, len(bb.counters))
    for c in bb.counters:
        _put(b, c)
    _put(b, len(bb.snapshot))
    for c in bb.snapshot:
        b.append(c)
    _put(b, len(bb.inputs))
    for c in bb.inputs:
        b.append(c)
    _put(b, bb.tick)
    _put(b, _fnv(b, len(b)))
    return b^


def _bytes(b: List[UInt8], mut at: Int, end: Int) raises -> List[UInt8]:
    var n = _get(b, at, end)
    if n < 0 or at + n > end:
        raise Error("blackbox: truncated section")
    var out = List[UInt8](capacity=n)
    for k in range(n):
        out.append(b[at + k])
    at += n
    return out^


def unpack(b: List[UInt8]) raises -> BlackBox:
    if len(b) < 24:
        raise Error("blackbox: truncated")
    var end = len(b) - 8
    var at = 0
    if _get(b, at, end) != BB_MAGIC:
        raise Error("blackbox: bad magic")
    var ver = _get(b, at, end)
    if ver != BB_VERSION:
        raise Error("blackbox: unknown version " + String(ver))
    var at2 = end
    if _fnv(b, end) != _get(b, at2, len(b)):
        raise Error("blackbox: checksum mismatch")
    var log = String(unsafe_from_utf8=_bytes(b, at, end))
    var nc = _get(b, at, end)
    if nc < 0 or nc > 1 << 20:
        raise Error("blackbox: corrupt counter count")
    var counters = List[Int]()
    for _ in range(nc):
        counters.append(_get(b, at, end))
    var snap = _bytes(b, at, end)
    var inputs = _bytes(b, at, end)
    var tick = _get(b, at, end)
    return BlackBox(log, counters, snap, inputs, tick)
