"""The PointerLock seam: mouse look (docs/platform.md, "Device seams").

`request(id, on)` asks to lock (`on` True) or release the pointer; its result is a KIND_DEV_POINTER packet with payload
[locked u8], STATUS_OK or, if the platform refused, STATUS_ERROR. The browser accepts a lock only inside a user gesture and
ends it by itself when the user presses Esc: that arrives as a KIND_DEV_POINTER packet with id 0, STATUS_OK and locked 0.
While locked, `take_delta(ptr)` writes the movement since the last call as 2 f32 (dx, dy in pixels, y down) at `ptr`, clears
it, and returns 1; unlocked it writes nothing and returns 0. Web: Pointer Lock API (`movementX`, `movementY`).

MemoryPointerLock follows those rules, with `grant_activation()` for a tap, `inject(dx, dy)` for movement and
`platform_release()` for Esc. Standard library only."""
from platform.device import (
    AVAIL_GRANTED,
    AVAIL_UNSUPPORTED,
    DEV_UNSUPPORTED,
    KIND_DEV_POINTER,
    write_f32,
)
from platform.packets import PacketQueue, REQ_QUEUED, STATUS_ERROR, STATUS_OK, packet


trait PointerLock(Movable):
    def availability(self) -> Int:
        ...

    def request(mut self, id: Int, on: Bool) -> Int:
        ...

    def locked(self) -> Bool:
        ...

    def take_delta(mut self, ptr: UInt64) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryPointerLock(PointerLock):
    var supported: Bool
    var _locked: Bool
    var _dx: Float32
    var _dy: Float32
    var _activation: Bool
    var _q: PacketQueue

    def __init__(out self, supported: Bool = True):
        self.supported = supported
        self._locked = False
        self._dx = 0
        self._dy = 0
        self._activation = False
        self._q = PacketQueue()

    def grant_activation(mut self):
        self._activation = True

    def inject(mut self, dx: Float32, dy: Float32):
        if self._locked:
            self._dx += dx
            self._dy += dy

    def platform_release(mut self):
        if self._locked:
            self._locked = False
            self._dx = 0
            self._dy = 0
            var payload = List[UInt8]()
            payload.append(0)
            _ = self._q.push(packet(KIND_DEV_POINTER, 0, STATUS_OK, payload^))

    def availability(self) -> Int:
        return AVAIL_GRANTED if self.supported else AVAIL_UNSUPPORTED

    def request(mut self, id: Int, on: Bool) -> Int:
        if not self.supported:
            return DEV_UNSUPPORTED
        var ok = True
        if on:
            ok = self._activation or self._locked
            self._activation = False
            if ok:
                self._locked = True
        else:
            self._locked = False
        if not self._locked:
            self._dx = 0
            self._dy = 0
        var payload = List[UInt8]()
        payload.append(UInt8(1) if self._locked else UInt8(0))
        _ = self._q.push(packet(KIND_DEV_POINTER, id, STATUS_OK if ok else STATUS_ERROR, payload^))
        return REQ_QUEUED

    def locked(self) -> Bool:
        return self._locked

    def take_delta(mut self, ptr: UInt64) -> Int:
        if not self._locked:
            return 0
        write_f32(ptr, 0, self._dx)
        write_f32(ptr, 1, self._dy)
        self._dx = 0
        self._dy = 0
        return 1

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
