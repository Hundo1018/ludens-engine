"""The Motion seam: accelerometer, gyroscope and orientation, read once per tick (docs/platform.md, "Device seams").

`start()` begins sampling, `stop()` ends it. `read(ptr)` copies the latest sample into 9 f32 (36 bytes) at `ptr` and returns
its sequence number, or 0 when there is no sample newer than the last `read` (the buffer is not touched; keep the old
values). Layout, in f32 indices:

    0 1 2   acceleration including gravity, m/s^2, device axes (x right, y up the screen, z out of the screen)
    3 4 5   rotation rate, degrees per second, about x, y, z
    6 7 8   orientation, degrees: alpha (about z), beta (about x), gamma (about y)

A value the device does not report is 0; `capabilities()` says which groups exist (MOTION_ACCEL, MOTION_GYRO, MOTION_ORIENT).
Web: the DeviceMotion and DeviceOrientation events, secure contexts only (an insecure page is AVAIL_UNSUPPORTED). iOS Safari asks the
user: `availability()` is AVAIL_PROMPT until `request_permission(id)` is answered, and that call must be made from a tap.
`start()` never prompts: before the permission is granted it returns DEV_NOT_GRANTED.

MemoryMotion takes samples from `feed`, for tests. Standard library only."""
from platform.device import (
    AVAIL_GRANTED,
    AVAIL_UNSUPPORTED,
    DEV_MOTION,
    DEV_NOT_GRANTED,
    DEV_OK,
    DEV_UNSUPPORTED,
    PermissionGate,
    write_f32,
)
from platform.packets import PacketQueue

comptime MOTION_ACCEL = 1
comptime MOTION_GYRO = 2
comptime MOTION_ORIENT = 4
comptime MOTION_SAMPLE_F32 = 9


trait Motion(Movable):
    def availability(self) -> Int:
        ...

    def capabilities(self) -> Int:
        ...

    def request_permission(mut self, id: Int) -> Int:
        ...

    def start(mut self) -> Int:
        ...

    def stop(mut self):
        ...

    def read(mut self, ptr: UInt64) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryMotion(Motion):
    var gate: PermissionGate
    var caps: Int
    var running: Bool
    var _sample: List[Float32]
    var _seq: Int
    var _read_seq: Int
    var _q: PacketQueue

    def __init__(out self, caps: Int = MOTION_ACCEL | MOTION_GYRO | MOTION_ORIENT, state: Int = AVAIL_GRANTED, answer: Bool = True):
        self.gate = PermissionGate(DEV_MOTION, state if caps != 0 else AVAIL_UNSUPPORTED, answer)
        self.caps = caps
        self.running = False
        self._sample = List[Float32](length=MOTION_SAMPLE_F32, fill=0)
        self._seq = 0
        self._read_seq = 0
        self._q = PacketQueue()

    def availability(self) -> Int:
        return self.gate.state

    def capabilities(self) -> Int:
        return self.caps

    def request_permission(mut self, id: Int) -> Int:
        return self.gate.request(id, self._q)

    def start(mut self) -> Int:
        if self.gate.state == AVAIL_UNSUPPORTED:
            return DEV_UNSUPPORTED
        if self.gate.state != AVAIL_GRANTED:
            return DEV_NOT_GRANTED
        self.running = True
        self._read_seq = self._seq
        return DEV_OK

    def stop(mut self):
        self.running = False

    def feed(mut self, sample: List[Float32]):
        """A new sample from the (pretend) sensor. Ignored while stopped. Groups the device lacks read as 0."""
        if not self.running:
            return
        for i in range(MOTION_SAMPLE_F32):
            var group = MOTION_ACCEL if i < 3 else (MOTION_GYRO if i < 6 else MOTION_ORIENT)
            self._sample[i] = sample[i] if (self.caps & group) != 0 and i < len(sample) else Float32(0)
        self._seq += 1

    def read(mut self, ptr: UInt64) -> Int:
        if not self.running or self._seq == self._read_seq:
            return 0
        for i in range(MOTION_SAMPLE_F32):
            write_f32(ptr, i, self._sample[i])
        self._read_seq = self._seq
        return self._seq

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
