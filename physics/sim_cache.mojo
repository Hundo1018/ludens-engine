"""Point caches: lossy, seekable per-frame point arrays (ROADMAP 17.63).

A snapshot (`state_io`, 17.39 replay) restores a solver so it continues bit
for bit. A cache records what a solver produced, frame by frame, so it can
be played back without the solver: cloth, strand or particle positions. It
may be lossy (an error bound per coordinate) and does not resume the
simulation. The encoder produces bytes, like `gameplay.save`; files are the
host's business.

Encoding: coordinates are quantised to q = round(x / (2 err)), so the
decoded value q * 2 err is within `err` of the original. A KEYFRAME stores
each q as a zig-zag varint; a DELTA frame stores q - q_prev, which is small
when points move little per frame. Deltas are on the integers, so there is
no drift however long the run. A keyframe starts every `keyframe_every`
frames, and whenever the point count changes: reading frame i decodes at
most `keyframe_every - 1` deltas. A frame with a non-finite coordinate, or
any frame when err = 0, is stored RAW (f32 bits, lossless; NaN kept).
With `pack=True` a delta frame is stored PACKED instead: one byte of bit
width b (enough for the frame's largest zig-zag delta) and every delta in
b bits, so a coordinate can cost less than the varint's one-byte floor
(test_sim_cache_pack). Such a cache is version 2; without `pack` the bytes
are those of version 1 exactly, and the reader takes both.

Layout (little-endian): magic "LDPC" (u32), version (u32), frame count
(u32), keyframe_every (u32), err (f64 bits), frame offsets (u64 each),
payload, FNV-1a 64 checksum of everything before it. `PointCacheReader`
rejects a bad magic, unknown version, truncation, an offset out of range
and a checksum mismatch with `raise`, never by reading out of bounds.

`CachePlayer` plays a cache under the 17.55 `ContinuumSolver` contract, so
a baked effect can stand in for a live solver in the same loop.
"""

from std.math import isfinite
from geometry.vec import Real, Vec3
from .state_io import StateWriter, StateReader
from .continuum import ContinuumSolver, ContinuumHealth

comptime CACHE_MAGIC: UInt32 = 0x4350444C  # "LDPC"
comptime CACHE_VERSION: UInt32 = 1
comptime _KEY: UInt8 = 0
comptime _DELTA: UInt8 = 1
comptime _RAW: UInt8 = 2
comptime _PACKED: UInt8 = 3  # a delta frame at a fixed bit width (version 2)
comptime CACHE_VERSION_PACKED: UInt32 = 2


def _f32_bits(v: Float32) -> UInt32:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt32]()[]


def _bits_f32(u: UInt32) -> Float32:
    var x = u
    return Pointer(to=x).unsafe_bitcast[Float32]()[]


def _f64_bits(v: Float64) -> UInt64:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt64]()[]


def _bits_f64(u: UInt64) -> Float64:
    var x = u
    return Pointer(to=x).unsafe_bitcast[Float64]()[]


def _put_u(mut b: List[UInt8], v: UInt64, bytes: Int):
    for k in range(bytes):
        b.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _put_varint(mut b: List[UInt8], v: Int):
    var z = UInt64((v << 1) ^ (v >> 63))  # zig-zag
    while z >= 0x80:
        b.append(UInt8(z & 0x7F) | 0x80)
        z >>= 7
    b.append(UInt8(z))


def _rd(d: List[UInt8], at: Int, bytes: Int) -> UInt64:
    var v = UInt64(0)
    for k in range(bytes):
        v |= UInt64(d[at + k]) << UInt64(8 * k)
    return v


def fnv1a64(b: List[UInt8], n: Int) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(n):
        h ^= UInt64(b[i])
        h *= UInt64(0x100000001B3)
    return h


struct PointCacheWriter(Movable):
    var err: Float64
    var keyframe_every: Int
    var payload: List[UInt8]
    var offsets: List[Int]
    var prev_q: List[Int]
    var prev_n: Int
    var since_key: Int
    var pack: Bool

    def __init__(out self, err: Real, keyframe_every: Int = 16, pack: Bool = False) raises:
        if err < 0 or keyframe_every < 1:
            raise Error("PointCacheWriter: err >= 0 and keyframe_every >= 1")
        self.err = Float64(err)
        self.keyframe_every = keyframe_every
        self.payload = List[UInt8]()
        self.offsets = List[Int]()
        self.prev_q = List[Int]()
        self.prev_n = -1
        self.since_key = 0
        self.pack = pack

    def frames(self) -> Int:
        return len(self.offsets)

    def add_frame(mut self, pts: List[Vec3]):
        self.offsets.append(len(self.payload))
        var n = len(pts)
        var raw = self.err == 0
        for p in pts:
            if not (isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2])):
                raw = True
        if raw:
            self.payload.append(_RAW)
            _put_u(self.payload, UInt64(n), 4)
            for p in pts:
                for c in range(3):
                    _put_u(self.payload, UInt64(_f32_bits(Float32(p[c]))), 4)
            self.prev_n = -1  # the next quantised frame must be a keyframe
            return
        var step = 2 * self.err
        var q = List[Int](capacity=3 * n)
        for p in pts:
            for c in range(3):
                q.append(Int(round(Float64(p[c]) / step)))
        var key = n != self.prev_n or self.since_key + 1 >= self.keyframe_every
        if key:
            self.payload.append(_KEY)
            _put_u(self.payload, UInt64(n), 4)
            for v in q:
                _put_varint(self.payload, v)
            self.since_key = 0
        elif self.pack:
            self.payload.append(_PACKED)
            _put_u(self.payload, UInt64(n), 4)
            var zs = List[UInt64](capacity=len(q))
            var top = UInt64(0)
            for k in range(len(q)):
                var d = q[k] - self.prev_q[k]
                var z = UInt64((d << 1) ^ (d >> 63))
                zs.append(z)
                top = max(top, z)
            var bits = 0
            while bits < 64 and (top >> UInt64(bits)) != 0:
                bits += 1
            self.payload.append(UInt8(bits))
            var acc = UInt64(0)
            var fill = 0
            for z in zs:
                var rem = bits
                var v = z
                while rem > 0:
                    var take = min(rem, 64 - fill)
                    var part = v & ((UInt64(1) << UInt64(take)) - 1) if take < 64 else v
                    acc |= part << UInt64(fill)
                    fill += take
                    rem -= take
                    v = v >> UInt64(take) if take < 64 else UInt64(0)
                    if fill == 64:
                        _put_u(self.payload, acc, 8)
                        acc = 0
                        fill = 0
            var tail = (fill + 7) // 8
            if tail > 0:
                _put_u(self.payload, acc, tail)
            self.since_key += 1
        else:
            self.payload.append(_DELTA)
            _put_u(self.payload, UInt64(n), 4)
            for k in range(len(q)):
                _put_varint(self.payload, q[k] - self.prev_q[k])
            self.since_key += 1
        self.prev_q = q^
        self.prev_n = n

    def bytes(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put_u(out, UInt64(CACHE_MAGIC), 4)
        _put_u(out, UInt64(CACHE_VERSION_PACKED if self.pack else CACHE_VERSION), 4)
        _put_u(out, UInt64(len(self.offsets)), 4)
        _put_u(out, UInt64(self.keyframe_every), 4)
        _put_u(out, _f64_bits(self.err), 8)
        for o in self.offsets:
            _put_u(out, UInt64(o), 8)
        for b in self.payload:
            out.append(b)
        _put_u(out, fnv1a64(out, len(out)), 8)
        return out^


struct PointCacheReader(Movable):
    var data: List[UInt8]
    var nframes: Int
    var keyframe_every: Int
    var err: Float64
    var offsets: List[Int]
    var base: Int  # payload start
    var end: Int  # payload end (checksum start)

    def __init__(out self, var data: List[UInt8]) raises:
        if len(data) < 32:
            raise Error("PointCacheReader: truncated header")
        if UInt32(_rd(data, 0, 4)) != CACHE_MAGIC:
            raise Error("PointCacheReader: not a point cache (bad magic)")
        var ver = UInt32(_rd(data, 4, 4))
        if ver != CACHE_VERSION and ver != CACHE_VERSION_PACKED:
            raise Error("PointCacheReader: unknown version " + String(ver))
        var nframes = Int(_rd(data, 8, 4))
        var base = 24 + 8 * nframes
        var end = len(data) - 8
        if base > end:
            raise Error("PointCacheReader: truncated frame index")
        if fnv1a64(data, end) != _rd(data, end, 8):
            raise Error("PointCacheReader: checksum mismatch")
        var offsets = List[Int](capacity=nframes)
        for f in range(nframes):
            var o = Int(_rd(data, 24 + 8 * f, 8))
            if o < 0 or base + o >= end:
                raise Error("PointCacheReader: frame offset out of range")
            offsets.append(o)
        self.keyframe_every = Int(_rd(data, 12, 4))
        self.err = _bits_f64(_rd(data, 16, 8))
        self.nframes = nframes
        self.base = base
        self.end = end
        self.offsets = offsets^
        self.data = data^

    def _u(self, at: Int, bytes: Int) -> UInt64:
        return _rd(self.data, at, bytes)

    def frames(self) -> Int:
        return self.nframes

    def _kind(self, f: Int) -> UInt8:
        return self.data[self.base + self.offsets[f]]

    def _varint(self, mut at: Int) raises -> Int:
        var z = UInt64(0)
        var shift = 0
        while True:
            if at >= self.end or shift > 63:
                raise Error("PointCacheReader: truncated varint")
            var b = self.data[at]
            at += 1
            z |= UInt64(b & 0x7F) << UInt64(shift)
            if b < 0x80:
                break
            shift += 7
        return Int(z >> 1) ^ -Int(z & 1)

    def _decode_q(self, f: Int, mut q: List[Int]) raises -> Int:
        """Decode frame f (key or delta) on top of `q`; returns the count."""
        var at = self.base + self.offsets[f]
        var kind = self.data[at]
        if at + 5 > self.end:
            raise Error("PointCacheReader: truncated frame")
        var n = Int(self._u(at + 1, 4))
        at += 5
        match kind:
            case == _KEY:
                q = List[Int](length=3 * n, fill=0)
                for k in range(3 * n):
                    q[k] = self._varint(at)
            case == _DELTA:
                if len(q) != 3 * n:
                    raise Error("PointCacheReader: delta frame without its keyframe")
                for k in range(3 * n):
                    q[k] += self._varint(at)
            case == _PACKED:
                if len(q) != 3 * n:
                    raise Error("PointCacheReader: delta frame without its keyframe")
                if at >= self.end:
                    raise Error("PointCacheReader: truncated packed frame")
                var bits = Int(self.data[at])
                at += 1
                if bits > 64 or at + (3 * n * bits + 7) // 8 > self.end:
                    raise Error("PointCacheReader: truncated packed frame")
                var bitpos = 0
                for k in range(3 * n):
                    var z = UInt64(0)
                    for b in range(bits):
                        var p = bitpos + b
                        if (self.data[at + p // 8] >> UInt8(p % 8)) & 1 == 1:
                            z |= UInt64(1) << UInt64(b)
                    bitpos += bits
                    q[k] += Int(z >> 1) ^ -Int(z & 1)
            case _:
                raise Error("PointCacheReader: unknown frame kind")
        return n

    def frame(self, f: Int) raises -> List[Vec3]:
        if f < 0 or f >= self.nframes:
            raise Error("PointCacheReader.frame: index out of range")
        var out = List[Vec3]()
        if self._kind(f) == _RAW:
            var at = self.base + self.offsets[f]
            var n = Int(self._u(at + 1, 4))
            at += 5
            if at + 12 * n > self.end:
                raise Error("PointCacheReader: truncated raw frame")
            for k in range(n):
                var x = _bits_f32(UInt32(self._u(at + 12 * k, 4)))
                var y = _bits_f32(UInt32(self._u(at + 12 * k + 4, 4)))
                var z = _bits_f32(UInt32(self._u(at + 12 * k + 8, 4)))
                out.append(Vec3(Real(x), Real(y), Real(z), 0))
            return out^
        var k0 = f
        while self._kind(k0) == _DELTA or self._kind(k0) == _PACKED:
            k0 -= 1
            if k0 < 0:
                raise Error("PointCacheReader: delta frame without its keyframe")
        if self._kind(k0) != _KEY:
            raise Error("PointCacheReader: delta frame without its keyframe")
        var q = List[Int]()
        var n = 0
        for g in range(k0, f + 1):
            n = self._decode_q(g, q)
        var step = 2 * self.err
        for k in range(n):
            out.append(Vec3(Real(Float64(q[3 * k]) * step), Real(Float64(q[3 * k + 1]) * step), Real(Float64(q[3 * k + 2]) * step), 0))
        return out^


struct CachePlayer(ContinuumSolver):
    """Plays a point cache as a continuum: `advance(dt)` moves through the
    frames at `frame_dt` seconds per frame (holding the last one)."""

    var reader: PointCacheReader
    var frame_dt: Real
    var index: Int
    var carry: Real
    var points: List[Vec3]

    def __init__(out self, var reader: PointCacheReader, frame_dt: Real) raises:
        self.reader = reader^
        self.frame_dt = frame_dt
        self.index = 0
        self.carry = 0
        self.points = List[Vec3]()
        # decode every frame once now, so `advance` cannot meet a bad frame
        for f in range(self.reader.frames()):
            _ = self.reader.frame(f)
        if self.reader.frames() > 0:
            self.points = self.reader.frame(0)

    def advance(mut self, dt: Real, gravity: Vec3):
        self.carry += dt
        var moved = False
        while self.carry >= self.frame_dt * 0.999999 and self.index + 1 < self.reader.frames():
            self.carry -= self.frame_dt
            self.index += 1
            moved = True
        if moved:
            try:
                self.points = self.reader.frame(self.index)
            except:
                pass  # unreachable: every frame decoded in __init__

    def health(self) -> ContinuumHealth:
        var bad = 0
        for p in self.points:
            if not (isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2])):
                bad += 1
        return ContinuumHealth(bad, 0, 0)

    def quarantine(mut self) -> Int:
        return 0  # recorded data is played as recorded

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(self.index)
        w.wf(self.carry)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.index = r.ri()
        self.carry = r.rf()
        if self.index < 0 or self.index >= max(self.reader.frames(), 1):
            raise Error("CachePlayer.read_state: frame index out of range")
        if self.reader.frames() > 0:
            self.points = self.reader.frame(self.index)
