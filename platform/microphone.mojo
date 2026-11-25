"""The Microphone seam (docs/platform.md, "Device seams"): mono f32 samples, nominally in [-1, 1], taken once per tick.
A device can exceed that range: Chrome's synthetic microphone peaks at 1.13. The seam does not clamp.

`open(id, sample_rate)` (8000 to 192000 Hz) queues a KIND_DEV_MIC result: STATUS_OK with the rate the device really runs
at, [rate u32 LE], or STATUS_ERROR with [availability u8] (denied, or no microphone). The first open shows the permission
prompt. DEV_BUSY, DEV_UNSUPPORTED and DEV_NOT_GRANTED are as for the camera (platform/camera.mojo).

`read(buf, max_samples)` copies up to `max_samples` f32 at `buf`, oldest first, and returns how many. The backend keeps the
last MIC_RING_SECONDS seconds; when the game falls behind, the oldest samples are discarded and counted in `overruns()`.

Web: `getUserMedia({audio})` into an AudioWorklet, whose blocks the host keeps in that ring. Routing the samples into the
mixer (docs/audio.md) is the game's job: this seam only delivers them.

MemoryMicrophone takes samples from `push`. Standard library only."""
from platform.device import (
    AVAIL_DENIED,
    AVAIL_UNSUPPORTED,
    DEV_BUSY,
    DEV_INVALID,
    DEV_MICROPHONE,
    DEV_NOT_GRANTED,
    DEV_UNSUPPORTED,
    KIND_DEV_MIC,
    PermissionGate,
    u32_bytes,
    write_f32,
)
from platform.packets import PacketQueue, REQ_QUEUED, STATUS_ERROR, STATUS_OK, packet

comptime MIC_MIN_RATE = 8000
comptime MIC_MAX_RATE = 192000
comptime MIC_RING_SECONDS = 1


trait Microphone(Movable):
    def availability(self) -> Int:
        ...

    def request_permission(mut self, id: Int) -> Int:
        ...

    def open(mut self, id: Int, sample_rate: Int) -> Int:
        ...

    def close(mut self):
        ...

    def is_open(self) -> Bool:
        ...

    def sample_rate(self) -> Int:
        ...

    def read(mut self, buf: UInt64, max_samples: Int) -> Int:
        ...

    def overruns(self) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryMicrophone(Microphone):
    var gate: PermissionGate
    var device_rate: Int
    """The rate the pretend device runs at, whatever was asked for (0: the asked rate)."""
    var _open: Bool
    var _rate: Int
    var _ring: List[Float32]
    var _overruns: Int
    var _q: PacketQueue

    def __init__(out self, state: Int = AVAIL_UNSUPPORTED, answer: Bool = True, device_rate: Int = 0):
        self.gate = PermissionGate(DEV_MICROPHONE, state, answer)
        self.device_rate = device_rate
        self._open = False
        self._rate = 0
        self._ring = List[Float32]()
        self._overruns = 0
        self._q = PacketQueue()

    def availability(self) -> Int:
        return self.gate.state

    def request_permission(mut self, id: Int) -> Int:
        return self.gate.request(id, self._q)

    def open(mut self, id: Int, sample_rate: Int) -> Int:
        if self.gate.state == AVAIL_UNSUPPORTED:
            return DEV_UNSUPPORTED
        if self.gate.state == AVAIL_DENIED:
            return DEV_NOT_GRANTED
        if sample_rate < MIC_MIN_RATE or sample_rate > MIC_MAX_RATE:
            return DEV_INVALID
        if self._open:
            return DEV_BUSY
        var ok = self.gate.resolve()
        var payload = List[UInt8]()
        if ok:
            self._open = True
            self._rate = self.device_rate if self.device_rate > 0 else sample_rate
            self._ring = List[Float32]()
            payload = u32_bytes(self._rate)
        else:
            payload.append(UInt8(self.gate.state))
        _ = self._q.push(packet(KIND_DEV_MIC, id, STATUS_OK if ok else STATUS_ERROR, payload^))
        return REQ_QUEUED

    def close(mut self):
        self._open = False
        self._ring = List[Float32]()

    def is_open(self) -> Bool:
        return self._open

    def sample_rate(self) -> Int:
        return self._rate if self._open else 0

    def push(mut self, samples: List[Float32]):
        """The device delivers samples (ignored while closed). Over MIC_RING_SECONDS of unread samples, the oldest go."""
        if not self._open:
            return
        for s in samples:
            self._ring.append(s)
        var limit = self._rate * MIC_RING_SECONDS
        var extra = len(self._ring) - limit
        if extra > 0:
            self._overruns += extra
            var kept = List[Float32]()
            for i in range(extra, len(self._ring)):
                kept.append(self._ring[i])
            self._ring = kept^

    def read(mut self, buf: UInt64, max_samples: Int) -> Int:
        if not self._open or max_samples <= 0:
            return 0
        var n = min(max_samples, len(self._ring))
        for i in range(n):
            write_f32(buf, i, self._ring[i])
        var rest = List[Float32]()
        for i in range(n, len(self._ring)):
            rest.append(self._ring[i])
        self._ring = rest^
        return n

    def overruns(self) -> Int:
        return self._overruns

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
