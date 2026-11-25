"""The Camera seam (docs/platform.md, "Device seams"): RGBA8 video frames copied into a buffer the game owns.

`open(id, width, height)` asks for a size (1 to MAX_CAMERA_DIM a side) and queues the result, a KIND_DEV_CAMERA packet: the
size the camera really gave, [width u32 LE][height u32 LE], or STATUS_ERROR with [availability u8] when the user denied it or
there is no camera. The first open shows the browser's permission prompt. `open` on an open camera is DEV_BUSY, on a
platform without one DEV_UNSUPPORTED, after a denial DEV_NOT_GRANTED.

`read_frame(buf, cap)` copies the newest frame, `frame_width() * frame_height() * 4` bytes of RGBA, and returns that
length. It returns 0 when no frame is newer than the last one read, and -1 when `cap` is too small (the frame stays for the
next call). A frame the game did not read before the next one arrived is lost and counted in `skipped()`: the camera runs at
its own rate, the game reads once per tick.

Web: `getUserMedia({video})`, a `<video>` drawn into a canvas, `getImageData` copied into wasm memory by the host. Phase 2 of
issue #135 measures that copy.

MemoryCamera makes frames from `push_frame(seed)`: pixel (x, y) is (x + seed, y + 2 * seed, x + y, 255), each mod 256.
Standard library only."""
from platform.device import (
    AVAIL_DENIED,
    AVAIL_GRANTED,
    AVAIL_UNSUPPORTED,
    DEV_BUSY,
    DEV_CAMERA,
    DEV_INVALID,
    DEV_NOT_GRANTED,
    DEV_UNSUPPORTED,
    KIND_DEV_CAMERA,
    PermissionGate,
    u32_bytes,
)
from platform.packets import PacketQueue, REQ_QUEUED, STATUS_ERROR, STATUS_OK, packet

comptime MAX_CAMERA_DIM = 4096


trait Camera(Movable):
    def availability(self) -> Int:
        ...

    def request_permission(mut self, id: Int) -> Int:
        ...

    def open(mut self, id: Int, width: Int, height: Int) -> Int:
        ...

    def close(mut self):
        ...

    def is_open(self) -> Bool:
        ...

    def frame_width(self) -> Int:
        ...

    def frame_height(self) -> Int:
        ...

    def read_frame(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def skipped(self) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryCamera(Camera):
    var gate: PermissionGate
    var max_width: Int
    var max_height: Int
    var _open: Bool
    var _w: Int
    var _h: Int
    var _frame: List[UInt8]
    var _fresh: Bool
    var _skipped: Int
    var _q: PacketQueue

    def __init__(out self, state: Int = AVAIL_UNSUPPORTED, answer: Bool = True, max_width: Int = 1280, max_height: Int = 720):
        self.gate = PermissionGate(DEV_CAMERA, state, answer)
        self.max_width = max_width
        self.max_height = max_height
        self._open = False
        self._w = 0
        self._h = 0
        self._frame = List[UInt8]()
        self._fresh = False
        self._skipped = 0
        self._q = PacketQueue()

    def availability(self) -> Int:
        return self.gate.state

    def request_permission(mut self, id: Int) -> Int:
        return self.gate.request(id, self._q)

    def open(mut self, id: Int, width: Int, height: Int) -> Int:
        if self.gate.state == AVAIL_UNSUPPORTED:
            return DEV_UNSUPPORTED
        if self.gate.state == AVAIL_DENIED:
            return DEV_NOT_GRANTED
        if width < 1 or width > MAX_CAMERA_DIM or height < 1 or height > MAX_CAMERA_DIM:
            return DEV_INVALID
        if self._open:
            return DEV_BUSY
        var ok = self.gate.resolve()
        var payload = List[UInt8]()
        if ok:
            self._open = True
            self._w = min(width, self.max_width)
            self._h = min(height, self.max_height)
            self._fresh = False
            payload = u32_bytes(self._w)
            payload.extend(u32_bytes(self._h))
        else:
            payload.append(UInt8(self.gate.state))
        _ = self._q.push(packet(KIND_DEV_CAMERA, id, STATUS_OK if ok else STATUS_ERROR, payload^))
        return REQ_QUEUED

    def close(mut self):
        self._open = False
        self._fresh = False

    def is_open(self) -> Bool:
        return self._open

    def frame_width(self) -> Int:
        return self._w if self._open else 0

    def frame_height(self) -> Int:
        return self._h if self._open else 0

    def push_frame(mut self, seed: Int):
        """The camera delivers a frame (ignored while closed). An unread frame is replaced and counted."""
        if not self._open:
            return
        if self._fresh:
            self._skipped += 1
        self._frame = List[UInt8](length=self._w * self._h * 4, fill=0)
        for y in range(self._h):
            for x in range(self._w):
                var o = (y * self._w + x) * 4
                self._frame[o] = UInt8((x + seed) & 255)
                self._frame[o + 1] = UInt8((y + 2 * seed) & 255)
                self._frame[o + 2] = UInt8((x + y) & 255)
                self._frame[o + 3] = 255
        self._fresh = True

    def read_frame(mut self, buf: UInt64, cap: Int) -> Int:
        if not self._open or not self._fresh:
            return 0
        var n = len(self._frame)
        if n > cap:
            return -1
        var d = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(buf))
        for i in range(n):
            d[i] = self._frame[i]
        self._fresh = False
        return n

    def skipped(self) -> Int:
        return self._skipped

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
